#!/usr/bin/env python3
"""Bounded, read-only resource sampling; graphics frame times are logged separately."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
ENGINES = [ROOT / "runtime/soju-engine-v1.5", ROOT / "runtime/soju-engine-dxmt-ow2-v0.2",
           ROOT / "runtime/soju-engine-dxmt-local"]
SESSION_MAX_SECONDS = 6 * 60 * 60
RESOURCE_PART_BYTES = 4 * 1024 * 1024
RESOURCE_BACKUPS = 3


def command(*args):
    # Read executable names and start times only, never process arguments/env.
    env = os.environ.copy()
    env.update(LC_ALL="C", TZ="UTC")
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL, timeout=3, env=env)


def timestamp():
    return dict(time=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                monotonic_ns=time.monotonic_ns())


def process_identity(pid):
    """A PID alone can be reused. ps lstart is stable and emitted in UTC."""
    try:
        fields = command("ps", "-p", str(pid), "-o", "lstart=,comm=").strip().split(None, 5)
    except subprocess.CalledProcessError:
        return None
    if len(fields) != 6:
        return None
    return dict(pid=int(pid), start_token=" ".join(fields[:5]), executable=str(Path(fields[5]).resolve()))


def server_directory_name(prefix):
    stat = Path(prefix).resolve().stat()
    # The staged Wine servers use the prefix device/inode in their server cwd.
    return f"server-{stat.st_dev:x}-{stat.st_ino:x}"


def server_matches_prefix(pid, prefix):
    cwd = command("lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn")
    return any(line.startswith("n") and Path(line[1:]).name == server_directory_name(prefix)
               for line in cwd.splitlines())


def find_session_server(engine, prefix):
    """Match executable AND Wine's prefix identity; fail closed if ambiguous."""
    expected = str((Path(engine) / "bin/wineserver").resolve())
    found = []
    for line in command("ps", "-axo", "pid=,comm=").splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) != 2 or Path(fields[1]).name != "wineserver":
            continue
        if str(Path(fields[1]).resolve()) != expected:
            continue
        try:
            identity = process_identity(int(fields[0]))
            if identity and identity["executable"] == expected and server_matches_prefix(identity["pid"], prefix):
                found.append(identity)
        except subprocess.CalledProcessError:
            continue  # The process exited between the two reads.
    if len(found) > 1:
        raise RuntimeError("Multiple Wine servers matched the bottle identity")
    return found[0] if found else None


def session_alive(identity):
    return process_identity(identity["pid"]) == identity


class SessionAdmissionError(RuntimeError):
    def __init__(self, details):
        super().__init__(details["reason"])
        self.details = details


def admit_session(pid, start_token, executable, prefix, *, timeout=5, monotonic=None, sleep=None):
    """Retry unavailable startup queries; never accept a changed PID identity."""
    monotonic, sleep = monotonic or time.monotonic, sleep or time.sleep
    began = monotonic()
    deadline = began + timeout
    attempts = 0
    while True:
        attempts += 1
        details = dict(attempts=attempts, elapsed_ms=round((monotonic() - began) * 1000, 1),
                       process_exists=False, start_matches=None, executable_matches=None,
                       prefix_matches=None, reason="process_missing")
        try:
            identity = process_identity(pid)
            if identity:
                details.update(process_exists=True, start_matches=identity["start_token"] == start_token,
                               executable_matches=identity["executable"] == executable)
                if not details["start_matches"] or not details["executable_matches"]:
                    details["reason"] = "process_identity_changed"
                    raise SessionAdmissionError(details)
                details["prefix_matches"] = server_matches_prefix(pid, prefix)
                if details["prefix_matches"]:
                    details["reason"] = "matched"
                    return identity, details
                details["reason"] = "prefix_cwd_unavailable_or_mismatched"
        except (OSError, subprocess.SubprocessError) as exc:
            details.update(reason="identity_query_failed", query_error=type(exc).__name__)
        if monotonic() >= deadline:
            raise SessionAdmissionError(details)
        sleep(min(.2, max(0, deadline - monotonic())))


def atomic_json(path, value):
    fd, name = tempfile.mkstemp(prefix=path.name + ".tmp-", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, indent=2)
            stream.write("\n")
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


class SessionLease:
    """One session collector per prefix; never unlink a live lock inode."""
    def __init__(self, prefix):
        folder = ROOT / "logs/resource-collectors"
        folder.mkdir(parents=True, exist_ok=True)
        key = hashlib.sha256(str(Path(prefix).resolve()).encode()).hexdigest()
        self.path = folder / (key + ".lock")
        self.status_path = folder / (key + ".json")
        self.fd = None

    def acquire(self, timeout=0):
        self.fd = os.open(self.path, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        deadline = time.monotonic() + timeout
        while True:
            try:
                fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                return True
            except BlockingIOError:
                if time.monotonic() >= deadline:
                    self.close()
                    return False
                time.sleep(min(.2, max(0, deadline - time.monotonic())))

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None


class RotatingJSONL:
    """Newest stays at path; numbered parts are older. Never append old runs."""
    def __init__(self, path, max_bytes=RESOURCE_PART_BYTES, backups=RESOURCE_BACKUPS):
        self.path, self.max_bytes, self.backups = Path(path), max_bytes, backups
        self.bytes = self.rotations = self.records = 0
        if max_bytes < 1 or backups < 0:
            raise ValueError("Invalid rotation limits")
        if any(self.part(i).exists() or self.part(i).is_symlink() for i in range(backups + 1)):
            raise FileExistsError("Resource stream or rotated parts already exist")
        self.stream = self.path.open("xb")

    def part(self, number):
        return self.path if not number else self.path.with_name(f"{self.path.stem}.{number}{self.path.suffix}")

    def write(self, record):
        data = (json.dumps(record, separators=(",", ":"), allow_nan=False) + "\n").encode()
        if len(data) > self.max_bytes:
            raise ValueError("One resource record exceeds the part budget")
        if self.bytes and self.bytes + len(data) > self.max_bytes:
            self.stream.close()
            if self.backups:
                self.part(self.backups).unlink(missing_ok=True)
                for i in range(self.backups - 1, 0, -1):
                    if self.part(i).exists():
                        self.part(i).replace(self.part(i + 1))
                self.path.replace(self.part(1))
            else:
                self.path.unlink()
            self.stream = self.path.open("xb")
            self.bytes = 0
            self.rotations += 1
        self.stream.write(data)
        self.stream.flush()
        self.bytes += len(data)
        self.records += 1

    def close(self):
        self.stream.close()


def gpu_statistics():
    """Optional system-wide GPU counters; never save the complete I/O Registry dump."""
    fields = {"Device Utilization %": "device_utilization_percent",
              "Renderer Utilization %": "renderer_utilization_percent",
              "Tiler Utilization %": "tiler_utilization_percent",
              "In use system memory": "in_use_memory_bytes",
              "Alloc system memory": "allocated_memory_bytes"}
    try:
        output = command("ioreg", "-r", "-c", "AGXAccelerator", "-l", "-w", "0")
    except (subprocess.SubprocessError, OSError):
        return {}
    line = next((line for line in output.splitlines()
                 if re.search(r'"PerformanceStatistics"\s*=', line)), "")
    values = {}
    for raw, name in fields.items():
        match = re.search(r'"' + re.escape(raw) + r'"\s*=\s*(\d+)(?=[,}\s])', line)
        if match:
            values[name] = int(match[1])
    return values


def thermal_state():
    """Optional pmset thermal summary; absent keys mean no limit was reported."""
    try:
        output = command("pmset", "-g", "therm")
    except (subprocess.SubprocessError, OSError):
        return {}
    values = {}
    for key, name in (("CPU_Speed_Limit", "cpu_speed_limit_percent"),
                      ("CPU_Available_CPUs", "cpu_available_cpus"),
                      ("CPU_Scheduler_Limit", "cpu_scheduler_limit_percent")):
        match = re.search(re.escape(key) + r"\s*=\s*(\d+)", output)
        if match:
            values[name] = int(match[1])
    return values


def sample(engine_name=None, prefix=None, *, probe=None):
    started = timestamp()
    vm = command("vm_stat")
    page_size = int(re.search(r"page size of (\d+) bytes", vm)[1])
    counters = {name: int(value) for name, value in
                re.findall(r"^([^:\n]+):\s+(\d+)\.", vm, re.MULTILINE)}
    games = []
    scan_errors, candidates = 0, 0
    clients = []
    for line in command("ps", "-axo", "pid=,etime=,pcpu=,rss=,lstart=,comm=").splitlines():
        parts = line.strip().split(None, 9)
        if len(parts) != 10:
            continue
        # Bounded launcher/agent accounting: names, CPU and RSS only. These
        # rows quantify the client's cost behind the game; they are not scoped
        # to one prefix, so treat them as system-wide evidence.
        if len(clients) < 16 and (parts[9].endswith("\\Battle.net.exe") or parts[9].endswith("Agent.exe")):
            try:
                clients.append(dict(pid=int(parts[0]), name=parts[9].rsplit("\\", 1)[-1].rsplit("/", 1)[-1],
                                    cpu_percent=float(parts[2]), rss_mib=round(int(parts[3]) / 1024, 1)))
            except ValueError:
                scan_errors += 1
        if not parts[9].endswith("Overwatch.exe"):
            continue
        candidates += 1
        if candidates > 8:
            scan_errors += 1
            break
        pid, elapsed, cpu, rss = parts[:4]
        native_before, native_error = None, None
        if probe:
            try:
                native_before = probe.sample(int(pid))
            except OSError as exc:
                native_error = exc.errno
        try:
            mapped = command("lsof", "-a", "-p", pid, "-d", "txt", "-Fn")
        except (subprocess.SubprocessError, OSError):
            scan_errors += 1
            continue
        engine = next((e for e in ENGINES if str(e) in mapped), None)
        in_prefix = prefix is None or str(Path(prefix).resolve()) + "/" in mapped
        if engine and in_prefix and (engine_name is None or engine.name == engine_name):
            game = dict(pid=int(pid), elapsed=elapsed, cpu_percent=float(cpu),
                              rss_mib=round(int(rss) / 1024, 1), engine=engine.name,
                              start_token=" ".join(parts[4:9]))
            if native_before:
                try:
                    native = probe.sample(int(pid), native_before['start_abstime'])
                    # Bracket lsof/native admission with the original ps identity.
                    # Subsequent 100 ms reads also check the kernel start identity.
                    identity = process_identity(int(pid))
                    if not identity or identity['start_token'] != game['start_token']:
                        scan_errors += 1
                        continue
                    game['native_start_abstime'] = native['start_abstime']
                    game['physical_footprint_mib'] = round(native['footprint_bytes'] / 2**20, 1)
                except OSError as exc:
                    game['process_probe_error'] = exc.errno
            elif native_error:
                game['process_probe_error'] = native_error
            games.append(game)
    swap = command("sysctl", "-n", "vm.swapusage")
    used = re.search(r"used = ([\d.]+)M", swap)
    result = dict(**started, schema_version=2,
                free_gib=round(shutil.disk_usage(ROOT).free / 2**30, 3),
                games=games, process_scan_complete=scan_errors == 0, process_scan_errors=scan_errors,
                swap_used_mib=float(used[1]) if used else None,
                gpu_system_wide=gpu_statistics(),
                client_processes=clients,
                thermal=thermal_state(),
                vm_page_size=page_size,
                vm_counters={key: counters.get(key) for key in
                             ["Swapins", "Swapouts", "Pageouts", "Compressions", "Decompressions"]})
    result["sample_duration_ms"] = (time.monotonic_ns() - started["monotonic_ns"]) / 1e6
    return result


def collect(stream, *, engine=None, prefix=None, seconds=360, wait_for_game=0,
            session=None, session_seconds=SESSION_MAX_SECONDS, sample_fn=None,
            alive_fn=None, monotonic=None, sleep=None, on_status=None, on_sample=None, on_game_exit=None):
    """Legacy capture stops on the first game's exit; session capture rearms."""
    sample_fn, alive_fn = sample_fn or sample, alive_fn or session_alive
    monotonic, sleep = monotonic or time.monotonic, sleep or time.sleep
    waiting, games = bool(wait_for_game), {}
    started = monotonic()
    end = started + (session_seconds if session else (wait_for_game or seconds))
    samples, next_status = 0, started
    reason = "session_duration_reached" if session else "duration_reached"
    while monotonic() < end:
        due = monotonic() + 2
        if session:
            try:
                if not alive_fn(session):
                    reason = "wine_session_ended"
                    break
            except (subprocess.SubprocessError, OSError):
                # A failed process query is not evidence the bottle exited.
                record = dict(**timestamp(), schema_version=2, event="identity_query_failed", session=session)
                stream.write(record)
                sleep(min(2, max(0, end - monotonic())))
                continue
        try:
            record = sample_fn(engine, prefix) if session else sample_fn(engine)
        except (subprocess.SubprocessError, OSError, ValueError) as exc:
            record = dict(**timestamp(), schema_version=2, error=type(exc).__name__)
        if session:
            record["session"] = session
        if on_sample:
            on_sample(record)
        stream.write(record)
        samples += 1
        if "games" in record and record.get("process_scan_complete", True):
            current = {(g["pid"], g.get("start_token", "")): g for g in record["games"]}
            if session:
                for event, changes in (("game_exited", games.keys() - current.keys()),
                                       ("game_started", current.keys() - games.keys())):
                    for key in sorted(changes):
                        stream.write(dict(**timestamp(), schema_version=2, event=event, session=session,
                                          game=(current if event == "game_started" else games)[key]))
                        if event == 'game_exited' and on_game_exit:
                            on_game_exit(games[key])
                games = current
            elif wait_for_game:
                if waiting and current:
                    waiting, games, end = False, current, monotonic() + seconds
                elif not waiting and not current.keys() & games.keys():
                    reason = "captured_game_exited"
                    break
        if on_status and monotonic() >= next_status:
            on_status(dict(status="running", samples=samples, games=list(games.values())))
            next_status = monotonic() + 30
        sleep(max(0, min(due - monotonic(), end - monotonic())))
    if waiting and not session:
        reason = "game_wait_expired"
    if reason == 'wine_session_ended' and on_game_exit:
        for game in games.values():on_game_exit(game)
    result = dict(status="complete", reason=reason, samples=samples, games=list(games.values()))
    stream.write(dict(**timestamp(), schema_version=2, event="capture_complete", session=session, **result))
    if on_status:
        on_status(result)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=360)
    parser.add_argument("--wait-for-game", type=int, default=0,
                        help="Wait up to this many seconds for the game before starting the duration; stop on exit.")
    parser.add_argument("--engine", choices=tuple(engine.name for engine in ENGINES),
                        help="Capture only games using this experiment engine.")
    parser.add_argument("--output", type=Path,
                        help="Unique JSONL output path inside this experiment's logs directory.")
    parser.add_argument("--follow-session", action="store_true", help="Follow every game launch until the exact Wine server exits.")
    parser.add_argument("--hitch-stacks", action="store_true", help="Bounded stack sampling around admitted game counter bursts.")
    parser.add_argument("--session-pid", type=int)
    parser.add_argument("--session-start", help="Expected Wine server UTC lstart identity supplied by the launcher.")
    parser.add_argument("--prefix", type=Path, help="Exact experiment prefix for session attribution and duplicate protection.")
    parser.add_argument("--session-seconds", type=int, default=SESSION_MAX_SECONDS,
                        help="Session lifetime limit, 1–21600 seconds; independent of game restarts.")
    args = parser.parse_args()
    if not 1 <= args.seconds <= 900:
        parser.error("Duration must be between 1 and 900 seconds.")
    if not 0 <= args.wait_for_game <= 600:
        parser.error("Wait must be between 0 and 600 seconds.")
    if not 1 <= args.session_seconds <= SESSION_MAX_SECONDS:
        parser.error("Session duration must be between 1 and 21600 seconds.")
    if args.follow_session:
        if not all((args.engine, args.prefix, args.session_pid, args.session_start)) or args.wait_for_game:
            parser.error("Session mode requires --engine, --prefix, --session-pid, --session-start and no --wait-for-game.")
        args.prefix = args.prefix.resolve()
        if not args.prefix.is_relative_to((ROOT / "runtime").resolve()) or not args.prefix.is_dir():
            parser.error("Session prefix must be an existing experiment runtime directory.")
    elif any((args.prefix, args.session_pid, args.session_start)):
        parser.error("Session identity options require --follow-session.")
    folder = ROOT / "logs/performance-baseline"
    path = args.output or folder / (
        "resources-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f") + ".jsonl")
    path = path.resolve()
    if not path.is_relative_to((ROOT / "logs").resolve()):
        parser.error("Resource output must remain inside this experiment's logs directory.")
    path.parent.mkdir(parents=True, exist_ok=True)
    print(path, flush=True)
    lease, stream, session, fast, probe = None, None, None, None, None
    hitch = None
    probe_error = None
    try:
        if args.follow_session:
            lease = SessionLease(args.prefix)
            # Allow the previous bottle's collector a few seconds to observe
            # its server exit before this fresh session takes over the lease.
            if not lease.acquire(timeout=5):
                print("A collector already owns this Wine bottle; no duplicate started.", flush=True)
                return
            engine = next(e for e in ENGINES if e.name == args.engine)
            session, admission = admit_session(args.session_pid, args.session_start,
                                              str((engine / "bin/wineserver").resolve()), args.prefix)
            print(json.dumps(dict(event="session_admission", **admission)), flush=True)
        stream = RotatingJSONL(path)
        # The helper is built explicitly beforehand, never during a game launch.
        try:
            from process_probe import NativeProbe, ProcessRecorder
            probe = NativeProbe()
            if args.hitch_stacks:
                from hitch_capture import HitchCapture
                hitch = HitchCapture(path.parent, probe)
            fast = ProcessRecorder(path.with_suffix('.process.csv'), probe,
                                   on_sample=hitch.consider if hitch else None)
            fast.start()
        except (OSError, RuntimeError, ValueError) as exc:
            probe_error = type(exc).__name__
            probe = None
            print(f"Fine process counters unavailable: {probe_error}", flush=True)
        started = timestamp()
        collector_identity = process_identity(os.getpid()) if session else None
        def status(update):
            data = dict(**timestamp(), **update, collector_pid=os.getpid(), session=session,
                        collector_identity=collector_identity,
                        started=started, prefix=str(args.prefix), output=str(path),
                        process_probe=fast.status() if fast else dict(status='unavailable', reason=probe_error),
                        hitch_capture=hitch.status() if hitch else dict(enabled=False),
                        rotation=dict(part_bytes=RESOURCE_PART_BYTES, backups=RESOURCE_BACKUPS,
                                      rotations=stream.rotations, records=stream.records))
            atomic_json(path.parent / "session-status.json", data)
            atomic_json(lease.status_path, data)
        if session:
            status(dict(status="starting", samples=0, games=[]))
        report_workers=[]
        def game_exited(game):
            # One small post-exit report at a time; never parse bulk traces on
            # the sampling thread or while the same game is still running.
            if any(child.poll() is None for child in report_workers):return
            with (path.parent/'auto-report.log').open('a') as output:
                report_workers.append(subprocess.Popen([sys.executable,str(ROOT/'scripts/assess_session.py'),
                    '--session',str(path.parent),'--pid',str(game['pid']),'--after-exit'],
                    stdout=output,stderr=subprocess.STDOUT,start_new_session=True))
        result = collect(stream, engine=args.engine, prefix=args.prefix, seconds=args.seconds,
                         wait_for_game=args.wait_for_game, session=session, session_seconds=args.session_seconds,
                         sample_fn=lambda engine, prefix=None: sample(engine, prefix, probe=probe),
                         on_sample=lambda record: fast.set_targets(record['games'])
                             if fast and record.get('process_scan_complete') else None,
                         on_status=status if session else None,on_game_exit=game_exited if session else None)
        if fast:
            fast.close()
        if hitch:
            hitch.close()
        if session:
            status(result)
        print(result["reason"], flush=True)
    except (OSError, subprocess.SubprocessError, RuntimeError, ValueError) as exc:
        if isinstance(exc, SessionAdmissionError):
            print(json.dumps(dict(event="session_admission_failed", **exc.details)), flush=True)
        print(f"Resource collector stopped: {type(exc).__name__}", flush=True)
        raise SystemExit(1)
    finally:
        if fast:
            fast.close()
        if hitch:
            hitch.close()
        if stream:
            stream.close()
        if lease:
            lease.close()


if __name__ == "__main__":
    main()
