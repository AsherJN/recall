"""Bounded stack snapshots triggered by admitted game counter bursts.

No injection, explicit pause/resume commands, argument/environment reads or settings
changes. Apple's sample tool may briefly perturb the workload; capture intervals
are recorded and must be reported separately from unprofiled performance.
"""
import csv
import json
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time


def trigger_reason(previous, current):
    if not previous or current.get('error') or previous.get('error'):
        return None
    if previous.get('start_abstime') != current.get('start_abstime'):
        return None
    if any(r.get(k,0) for r in [previous,current] for k in ['vm_error','cpu_error','task_counter_saturated']):
        return None
    elapsed = (current['monotonic_ns']-previous['monotonic_ns'])/1e9
    if not .02 <= elapsed <= .5:
        return None
    def delta(name):
        return current.get(name, 0)-previous.get(name, 0)
    if delta('vm_swapouts') >= 256 or delta('vm_swapins') >= 256:
        return 'system_paging'
    if delta('faults_u32') >= 15000 or delta('pageins') >= 512:
        return 'game_fault_or_read_burst'
    if delta('runnable_ns')-delta('user_ns')-delta('system_ns') > 400_000_000:
        return 'scheduling_contention'
    return None


def stack_section(text):
    # sample's process header is unnecessary and can contain launch details.
    # Retain the call graph and module symbolication only, capped at 2 MiB.
    start = text.find('Call graph:')
    if start < 0:
        return None
    lines = text[start:].splitlines()
    lines = [line for line in lines if not line.lstrip().lower().startswith(
        ('arguments:', 'command line:', 'environment:', 'command:', 'path:'))]
    return '\n'.join(lines)[:2*1024*1024]+'\n'


class HitchCapture:
    MAX_PER_PROCESS = 4
    MAX_PER_REASON = 1
    MAX_SESSION = 8
    def __init__(self, folder, probe):
        self.folder, self.probe = Path(folder)/'hitch-stacks', probe
        self.folder.mkdir(exist_ok=False)
        self.pending = queue.Queue(maxsize=1)
        self.stop = threading.Event()
        self.previous, self.first_seen, self.last_capture, self.counts = {}, {}, {}, {}
        self.progress_checked = {}
        self.accepted = self.completed = self.failed = self.busy = 0
        self.unavailable = False
        self.worker = threading.Thread(target=self._run, name='hitch-stacks', daemon=True)
        self.worker.start()

    def consider(self, row):
        if self.unavailable or self.stop.is_set() or row.get('error'):
            return
        key = (row['pid'],row['start_abstime'])
        now = row['monotonic_ns']/1e9
        began = self.first_seen.setdefault(key, now)
        previous = self.previous.get(key)
        self.previous[key] = dict(row)
        reason = trigger_reason(previous,row)
        if not reason and now-began >= 60 and now-self.progress_checked.get(key,0) >= .5:
            self.progress_checked[key]=now
            if self.progress_stale(row['pid'],now): reason='presentation_progress_gap'
        # Leave the initial loader/prewarm minute out of the limited budget.
        if not reason or now-began < 60 or now-self.last_capture.get(key,0) < 20:
            return
        counts = self.counts.setdefault(key,{})
        if (sum(counts.values()) >= self.MAX_PER_PROCESS or counts.get(reason,0) >= self.MAX_PER_REASON
                or self.accepted >= self.MAX_SESSION):
            return
        request = dict(pid=row['pid'], start_abstime=row['start_abstime'], reason=reason,
                       trigger_unix_us=row['unix_us'], trigger_monotonic_ns=row['monotonic_ns'],
                       preceding_counter=previous, triggering_counter=dict(row), number=self.accepted+1)
        try:
            self.pending.put_nowait(request)
        except queue.Full:
            self.busy += 1
            return
        self.last_capture[key] = now
        counts[reason] = counts.get(reason,0)+1
        self.accepted += 1

    def progress_stale(self,pid,now):
        """Read at most 80 KiB twice per second, only for an admitted game PID."""
        try:
            canvas=self.folder.parent/f'canvas-{pid}.jsonl'
            with canvas.open('rb') as stream:
                stream.seek(max(0,canvas.stat().st_size-16384))
                lines=stream.read(16384).decode().splitlines()
            # Last complete state is explicit; never assume a hidden game is stuck.
            state=json.loads(next(line for line in reversed(lines) if line.startswith('{') and line.endswith('}')))
            if not state.get('focused'):return False
            path=self.folder.parent/f'display-{pid}.csv'
            with path.open('rb') as stream:
                header=stream.readline().decode().strip().split(',')
                stream.seek(max(stream.tell(),path.stat().st_size-65536))
                rows=list(csv.DictReader(stream.read(65536).decode().splitlines(),fieldnames=header))
            last=next(r for r in reversed(rows) if r.get('event')=='presented' and r.get('presented_state')=='valid')
            elapsed=now-float(last['presented_s'])
            return 1.25 < elapsed < 30
        except (OSError,ValueError,KeyError,StopIteration,UnicodeError):
            return False

    def _run(self):
        while not self.stop.is_set():
            try:
                request = self.pending.get(timeout=.25)
            except queue.Empty:
                continue
            target = self.folder/f"{request['number']:02d}-{request['pid']}"
            raw = target.with_suffix('.raw')
            record = dict(request, capture_start_unix_us=time.time_ns()//1000,
                          capture_start_monotonic_ns=time.monotonic_ns())
            active=self.folder/'active.json'
            try:
                active.write_text(json.dumps(dict(pid=request['pid'],number=request['number']))+'\n')
                # Kernel process-start identity is checked immediately before
                # and after profiling. Any reuse invalidates the snapshot.
                self.probe.sample(request['pid'], request['start_abstime'])
                process = subprocess.run([sys.executable,str(Path(__file__).with_name('sample_bounded.py')),
                                          str(request['pid']),str(raw)], stdout=subprocess.DEVNULL,
                                         stderr=subprocess.DEVNULL, timeout=45)
                self.probe.sample(request['pid'], request['start_abstime'])
                text = raw.read_text(errors='replace') if raw.exists() and raw.stat().st_size <= 16*1024*1024 else ''
                clean = stack_section(text)
                if process.returncode or not clean:
                    raise RuntimeError('stack_capture_unavailable')
                target.with_suffix('.txt').write_text(clean)
                record.update(status='captured', stack_file=target.with_suffix('.txt').name)
                self.completed += 1
            except (OSError, subprocess.SubprocessError, RuntimeError) as exc:
                record.update(status='unavailable', error=type(exc).__name__)
                self.failed += 1
                # Do not repeatedly ask the OS for unavailable profiling access.
                if isinstance(exc, RuntimeError): self.unavailable = True
            finally:
                raw.unlink(missing_ok=True)
                record.update(capture_end_unix_us=time.time_ns()//1000,
                              capture_end_monotonic_ns=time.monotonic_ns(),
                              observer_effect='Sampled interval may be perturbed; onset counters precede capture.')
                target.with_suffix('.json').write_text(json.dumps(record,indent=2)+'\n')
                active.unlink(missing_ok=True)
                self.pending.task_done()

    def status(self):
        return dict(enabled=True, unavailable=self.unavailable, accepted=self.accepted,
                    completed=self.completed, failed=self.failed, busy=self.busy,
                    session_limit=self.MAX_SESSION, per_process_limit=self.MAX_PER_PROCESS,
                    duration_seconds=1, interval_ms=10, worker_deadline_seconds=45,
                    translated_stack_limit='Native frames usable; Windows/Rosetta unwinding can be incomplete.',
                    output=str(self.folder))

    def close(self):
        self.stop.set()
        while True:
            try:self.pending.get_nowait();self.pending.task_done()
            except queue.Empty:break
        self.worker.join(timeout=48)
