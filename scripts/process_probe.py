"""Bounded 10 Hz process counters alongside the bottle's slower resource capture."""
import argparse
import csv
import ctypes
import errno
import hashlib
import json
from pathlib import Path
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'scripts/process_probe.c'
BUILD = ROOT / 'runtime/build/process-probe'
PART_BYTES = 8 * 1024 * 1024
BACKUPS = 3


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def build():
    BUILD.mkdir(parents=True, exist_ok=True)
    library = BUILD / 'libprocess_probe.dylib'
    before = digest(SOURCE)
    subprocess.run(['/usr/bin/clang', '-O2', '-Wall', '-Wextra', '-Werror',
                    '-dynamiclib', str(SOURCE), '-o', str(library)], check=True)
    if digest(SOURCE) != before:
        raise RuntimeError('Probe source changed during build')
    (BUILD / 'manifest.json').write_text(json.dumps(
        dict(source_sha256=before, library_sha256=digest(library)), indent=2) + '\n')


class NativeProbe:
    def __init__(self):
        library = BUILD / 'libprocess_probe.dylib'
        manifest = json.loads((BUILD / 'manifest.json').read_text())
        if manifest != dict(source_sha256=digest(SOURCE), library_sha256=digest(library)):
            raise RuntimeError('Probe build is stale; build outside gameplay')
        self.library = ctypes.CDLL(str(library))
        self.library.ow_probe_fields.restype = ctypes.c_char_p
        self.fields = self.library.ow_probe_fields().decode('ascii').rstrip(',').split(',')
        if len(self.fields) != 34 or len(set(self.fields)) != len(self.fields):
            raise RuntimeError('Unrecognized native counter ABI')
        self.buffer = ctypes.c_uint64 * len(self.fields)
        self.library.ow_probe_sample.argtypes = [ctypes.c_int, ctypes.c_uint64,
                                                ctypes.POINTER(ctypes.c_uint64), ctypes.c_uint32]
        self.library.ow_probe_sample.restype = ctypes.c_int

    def sample(self, pid, expected_start=0):
        values = self.buffer()
        result = self.library.ow_probe_sample(pid, expected_start, values, len(values))
        if result:
            raise OSError(result, errno.errorcode.get(result, 'native_query_failed'))
        return dict(zip(self.fields, values))


class ProcessRecorder:
    """Only receives already-attributed targets; kernel start identity checked each read.

    A single utility thread owns all CSV writes. No subprocess at 10 Hz, no game
    injection, and no target-memory reads. Oldest samples rotate within 32 MiB.
    """
    def __init__(self, path, probe, *, part_bytes=PART_BYTES, backups=BACKUPS, on_sample=None):
        self.path, self.probe = Path(path), probe
        self.part_bytes, self.backups = part_bytes, backups
        self.targets = ()
        self.stop = threading.Event()
        self.thread = None
        self.stream = None
        self.fields = ['schema_version', 'pid', 'error'] + probe.fields
        self.samples = self.errors = self.rotations = self.late_wakes = 0
        self.max_query_ns = 0
        self.failure = None
        self.on_sample = on_sample
        self.callback_errors = 0
        self.state = 'starting'
        self.bytes = 0
        self._open()

    def _open(self):
        self.stream = self.path.open('x', newline='')
        self.writer = csv.DictWriter(self.stream, fieldnames=self.fields, lineterminator='\n')
        self.writer.writeheader()
        self.stream.flush()
        self.bytes = self.stream.tell()

    def set_targets(self, games):
        # The slow collector establishes engine/prefix/start identity first.
        self.targets = tuple((g['pid'], g['native_start_abstime']) for g in games
                             if g.get('native_start_abstime'))[:8]

    def tick(self):
        for pid, start in self.targets:
            try:
                values = self.probe.sample(pid, start)
                row = dict(schema_version=1, pid=pid, error=0, **values)
                self.max_query_ns = max(self.max_query_ns, values['query_duration_ns'])
            except OSError as exc:
                self.errors += 1
                row = dict(schema_version=1, pid=pid, error=exc.errno or errno.EIO,
                           unix_us=time.time_ns() // 1000, monotonic_ns=time.monotonic_ns(),
                           start_abstime=start)
            # Rows contain only bounded integers; reserve one KiB before each.
            if self.bytes + 1024 > self.part_bytes:
                self.stream.close()
                self.path.with_suffix(f'.{self.backups}.csv').unlink(missing_ok=True)
                for i in range(self.backups - 1, 0, -1):
                    old = self.path.with_suffix(f'.{i}.csv')
                    if old.exists():
                        old.replace(self.path.with_suffix(f'.{i + 1}.csv'))
                self.path.replace(self.path.with_suffix('.1.csv'))
                self.rotations += 1
                self._open()
            self.writer.writerow(row)
            self.bytes = self.stream.tell()
            self.samples += 1
            if self.on_sample:
                try:
                    self.on_sample(row)
                except Exception:
                    # Optional stack capture must not terminate counter logging.
                    self.callback_errors += 1

    def start(self):
        self.thread = threading.Thread(target=self._run, name='process-counters', daemon=True)
        self.thread.start()

    def _run(self):
        self.state = 'running'
        try:
            # Lower-priority diagnostic work; does not change game scheduling.
            system = ctypes.CDLL('/usr/lib/libSystem.B.dylib')
            self.qos_result = system.pthread_set_qos_class_self_np(0x11, 0)  # QOS_CLASS_UTILITY, local SDK
            due, flush_due = time.monotonic(), time.monotonic() + 1
            while not self.stop.is_set():
                now = time.monotonic()
                self.late_wakes += now - due > .15
                self.tick()
                if now >= flush_due:
                    self.stream.flush()
                    flush_due = now + 1
                # Never catch up in a burst after suspension or a slow query.
                due = max(due + .1, time.monotonic())
                self.stop.wait(max(0, due - time.monotonic()))
            self.state = 'complete'
        except Exception as exc:
            self.failure = type(exc).__name__
            self.state = 'failed'
        finally:
            self.stream.close()

    def status(self):
        return dict(status=self.state, output=str(self.path), interval_ms=100,
                    samples=self.samples, errors=self.errors, rotations=self.rotations,
                    late_wakes=self.late_wakes, max_query_ms=self.max_query_ns / 1e6,
                    target_pids=[p for p, _ in self.targets], failure=self.failure,
                    callback_errors=self.callback_errors,
                    retention_bytes=self.part_bytes * (self.backups + 1))

    def close(self):
        self.stop.set()
        if self.thread:
            self.thread.join(timeout=3)
        elif self.stream:
            self.stream.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', action='store_true')
    args = parser.parse_args()
    if args.build:
        build()
    else:
        parser.error('Use --build to compile the small native reader outside gameplay.')
