"""Production collector state machine, filesystem rotation and launch contract."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import measure_resources as resources
import launch_cx26 as launch


class Clock:
    def __init__(self):
        self.now = 0

    def monotonic(self):
        return self.now

    def sleep(self, duration):
        assert 0 <= duration <= 2
        self.now += duration


class Sink:
    def __init__(self):
        self.records = []

    def write(self, record):
        self.records.append(record)


SERVER = dict(pid=17, start_token="Fri Sep 11 20:00:00 2026", executable="/engine/bin/wineserver")


def game(pid, start="first"):
    return dict(pid=pid, start_token=start, engine="local", rss_mib=5)


def sample(games, complete=True):
    return dict(**resources.timestamp(), schema_version=2, games=games, process_scan_complete=complete)


class CollectorLifecycle(unittest.TestCase):
    def test_admission_retries_transient_prefix_visibility_without_changing_identity(self):
        clock = Clock()
        with patch.object(resources, "process_identity", return_value=SERVER), \
             patch.object(resources, "server_matches_prefix", side_effect=[False, subprocess.TimeoutExpired("lsof", 3), True]):
            identity, details = resources.admit_session(SERVER["pid"], SERVER["start_token"], SERVER["executable"],
                Path("/prefix"), monotonic=clock.monotonic, sleep=clock.sleep)
        self.assertEqual(identity, SERVER)
        self.assertEqual(details["attempts"], 3)
        self.assertEqual(details["reason"], "matched")
        self.assertTrue(details["prefix_matches"])

    def test_admission_identity_change_is_immediate_and_never_retried(self):
        for change in ({"start_token": "later"}, {"executable": "/different/wineserver"}):
            clock = Clock()
            with patch.object(resources, "process_identity", side_effect=[SERVER | change, SERVER]) as identity, \
                 patch.object(resources, "server_matches_prefix") as prefix:
                with self.assertRaises(resources.SessionAdmissionError) as error:
                    resources.admit_session(SERVER["pid"], SERVER["start_token"], SERVER["executable"], Path("/prefix"),
                                           monotonic=clock.monotonic, sleep=clock.sleep)
            self.assertEqual(identity.call_count, 1)
            prefix.assert_not_called()
            self.assertEqual(error.exception.details["reason"], "process_identity_changed")
            self.assertEqual(clock.now, 0)

    def test_admission_wrong_prefix_expires_and_discloses_exact_failed_check(self):
        clock = Clock()
        with patch.object(resources, "process_identity", return_value=SERVER), \
             patch.object(resources, "server_matches_prefix", return_value=False):
            with self.assertRaises(resources.SessionAdmissionError) as error:
                resources.admit_session(SERVER["pid"], SERVER["start_token"], SERVER["executable"], Path("/prefix"),
                                       monotonic=clock.monotonic, sleep=clock.sleep)
        self.assertEqual(clock.now, 5)
        self.assertTrue(error.exception.details["start_matches"])
        self.assertTrue(error.exception.details["executable_matches"])
        self.assertFalse(error.exception.details["prefix_matches"])

    def run_capture(self, states, **kwargs):
        clock, sink = Clock(), Sink()
        samples = iter(states)
        result = resources.collect(sink, sample_fn=lambda *args: next(samples),
                                   monotonic=clock.monotonic, sleep=clock.sleep, **kwargs)
        return sink.records, result, clock.now

    def test_session_rearms_and_stops_only_when_exact_server_exits(self):
        alive = iter([True] * 5 + [False])
        records, result, elapsed = self.run_capture(
            [sample([]), sample([game(31)]), sample([]), sample([game(42)]), sample([game(42)])],
            session=SERVER, alive_fn=lambda _: next(alive), session_seconds=100)
        self.assertEqual(result["reason"], "wine_session_ended")
        self.assertEqual(elapsed, 10)
        self.assertEqual([(r["event"], r["game"]["pid"]) for r in records if "game" in r],
                         [("game_started", 31), ("game_exited", 31), ("game_started", 42)])
        self.assertTrue(all(r["session"] == SERVER and "time" in r and "monotonic_ns" in r for r in records))

    def test_game_pid_reuse_is_a_new_lifecycle_and_incomplete_scan_is_not_exit(self):
        records, result, _ = self.run_capture(
            [sample([game(31)]), sample([], False), sample([game(31, "second")])],
            session=SERVER, alive_fn=lambda _: True, session_seconds=6)
        self.assertEqual([r["event"] for r in records if "game" in r],
                         ["game_started", "game_exited", "game_started"])
        self.assertEqual(result["reason"], "session_duration_reached")

    def test_legacy_wait_still_stops_first_game_exit(self):
        records, result, elapsed = self.run_capture(
            [sample([]), sample([game(31)]), sample([])], seconds=20, wait_for_game=10)
        self.assertEqual(result["reason"], "captured_game_exited")
        self.assertEqual(elapsed, 4)
        self.assertEqual(result["samples"], 3)

    def test_legacy_wait_timeout_and_direct_duration(self):
        for kwargs, reason in ((dict(seconds=20, wait_for_game=4), "game_wait_expired"),
                               (dict(seconds=4), "duration_reached")):
            _, result, elapsed = self.run_capture([sample([])] * 2, **kwargs)
            self.assertEqual((result["reason"], elapsed), (reason, 4))

    def test_failed_identity_reads_remain_bounded_without_false_exit(self):
        clock, sink = Clock(), Sink()
        alive = Mock(side_effect=subprocess.TimeoutExpired("ps", 3))
        get_sample = Mock()
        result = resources.collect(sink, session=SERVER, session_seconds=6, sample_fn=get_sample,
                                   alive_fn=alive, monotonic=clock.monotonic, sleep=clock.sleep)
        self.assertEqual(result["reason"], "session_duration_reached")
        self.assertEqual(clock.now, 6)
        self.assertEqual(alive.call_count, 3)
        get_sample.assert_not_called()

    def test_sampling_error_is_redacted_and_does_not_lose_follow_mode(self):
        clock, sink = Clock(), Sink()
        fetch = Mock(side_effect=[OSError("sensitive token"), sample([game(42)])])
        result = resources.collect(sink, session=SERVER, session_seconds=4, sample_fn=fetch,
                                   alive_fn=lambda _: True, monotonic=clock.monotonic, sleep=clock.sleep)
        self.assertEqual(result["samples"], 2)
        self.assertNotIn("sensitive", json.dumps(sink.records))
        self.assertEqual(sink.records[0]["error"], "OSError")

    def test_server_pid_reuse_is_not_same_session(self):
        with patch.object(resources, "process_identity", return_value=SERVER | {"start_token": "later"}):
            self.assertFalse(resources.session_alive(SERVER))


class CollectorFiles(unittest.TestCase):
    def test_follow_cli_writes_final_status_and_releases_lease(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(resources, "ROOT", Path(temp)):
            root = Path(temp)
            prefix, engine = root / "runtime/prefix", root / "runtime/engine"
            prefix.mkdir(parents=True)
            output = root / "logs/measured/resources.jsonl"
            server = SERVER | {"executable": str((engine / "bin/wineserver").resolve())}
            clock = Clock()
            original_collect = resources.collect
            def finite_collect(stream, **kwargs):
                kwargs['sample_fn'] = lambda *args: sample([])
                return original_collect(stream, **kwargs,
                                        alive_fn=lambda _: True, monotonic=clock.monotonic, sleep=clock.sleep)
            argv = ["measure_resources.py", "--follow-session", "--session-pid", "17",
                    "--session-start", server["start_token"], "--prefix", str(prefix),
                    "--engine", "engine", "--output", str(output), "--session-seconds", "4"]
            with patch.object(resources, "ENGINES", [engine]), patch.object(sys, "argv", argv), \
                 patch.object(resources, "process_identity", side_effect=lambda pid: server if pid == 17 else {"pid": pid}), \
                 patch.object(resources, "server_matches_prefix", return_value=True), \
                 patch.object(resources, "collect", side_effect=finite_collect):
                resources.main()
            status = json.loads((output.parent / "session-status.json").read_text())
            records = [json.loads(line) for line in output.read_text().splitlines()]
            self.assertEqual(status["status"], "complete")
            self.assertEqual(status["reason"], "session_duration_reached")
            self.assertEqual(status["samples"], 2)
            self.assertEqual(status["session"], server)
            self.assertEqual(records[-1]["event"], "capture_complete")
            lease = resources.SessionLease(prefix)
            try:
                self.assertTrue(lease.acquire())
            finally:
                lease.close()

    def test_rotation_keeps_only_bounded_complete_recent_records(self):
        with tempfile.TemporaryDirectory() as temp:
            stream = resources.RotatingJSONL(Path(temp) / "resources.jsonl", max_bytes=55, backups=3)
            for sequence in range(40):
                stream.write(dict(sequence=sequence))
            stream.close()
            parts = [stream.part(i) for i in range(3, -1, -1)]
            self.assertTrue(all(p.stat().st_size <= 55 for p in parts))
            values = [json.loads(line)["sequence"] for p in parts for line in p.read_text().splitlines()]
            self.assertEqual(values, list(range(values[0], 40)))
            self.assertGreater(values[0], 0)
            self.assertGreater(stream.rotations, 3)
            self.assertEqual(stream.records, 40)

    def test_existing_part_and_dangling_symlink_are_never_overwritten(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "resources.jsonl"
            old = Path(temp) / "resources.1.jsonl"
            old.write_text("keep")
            with self.assertRaises(FileExistsError):
                resources.RotatingJSONL(path)
            self.assertEqual(old.read_text(), "keep")
            old.unlink()
            old.symlink_to(Path(temp) / "missing")
            with self.assertRaises(FileExistsError):
                resources.RotatingJSONL(path)
            self.assertTrue(old.is_symlink())

    def test_oversized_record_is_rejected_before_partial_write(self):
        with tempfile.TemporaryDirectory() as temp:
            stream = resources.RotatingJSONL(Path(temp) / "resources.jsonl", max_bytes=15)
            with self.assertRaises(ValueError):
                stream.write(dict(data="x" * 50))
            stream.close()
            self.assertEqual(stream.path.read_bytes(), b"")

    def test_one_lease_per_bottle_releases_without_unlinking_inode(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(resources, "ROOT", Path(temp)):
            first, duplicate = resources.SessionLease(Path(temp) / "prefix"), resources.SessionLease(Path(temp) / "prefix")
            unrelated = resources.SessionLease(Path(temp) / "other")
            try:
                self.assertTrue(first.acquire())
                inode = first.path.stat().st_ino
                self.assertFalse(duplicate.acquire())
                self.assertTrue(unrelated.acquire())
                first.close()
                self.assertTrue(duplicate.acquire())
                self.assertEqual(duplicate.path.stat().st_ino, inode)
            finally:
                first.close()
                duplicate.close()
                unrelated.close()

    def test_status_is_complete_json_after_replacement(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "status.json"
            resources.atomic_json(path, dict(status="running"))
            resources.atomic_json(path, dict(status="complete"))
            self.assertEqual(json.loads(path.read_text()), dict(status="complete"))
            self.assertEqual(list(Path(temp).glob("*.tmp-*")), [])


class AttributionAndLauncher(unittest.TestCase):
    def test_same_engine_game_in_other_bottle_is_excluded_and_scan_is_bounded(self):
        prefix = ROOT / "runtime/prefix-dxmt-local"
        engine = ROOT / "runtime/soju-engine-dxmt-local"
        lsof_pids = []
        def command(*args):
            if args[0] == "vm_stat":
                return "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nSwapouts: 0.\n"
            if args[0] == "ps":
                return "".join(f"{pid} 00:05 20.0 2048 Fri Sep 11 20:00:00 2026 C:\\Overwatch.exe\n"
                               for pid in range(20, 30))
            if args[0] == "lsof":
                pid = int(args[args.index("-p") + 1])
                lsof_pids.append(pid)
                bottle = prefix if pid == 21 else ROOT / "runtime/other-prefix"
                return f"n{engine}/bin/wine\nn{bottle}/drive_c/Overwatch.exe\n"
            if args[0] == "sysctl":
                return "used = 0.00M"
            if args[:3] == ("pmset", "-g", "therm"):
                return "Note: No thermal warning level has been recorded\n"
            self.fail(args)
        with patch.object(resources, "command", side_effect=command), \
             patch.object(resources, "gpu_statistics", return_value={}):
            record = resources.sample(engine.name, prefix)
        self.assertEqual(record["thermal"], {})
        self.assertEqual([g["pid"] for g in record["games"]], [21])
        self.assertEqual(len(lsof_pids), 8)
        self.assertFalse(record["process_scan_complete"])
        self.assertEqual(record["process_scan_errors"], 1)

    def test_same_engine_other_bottle_does_not_match(self):
        with tempfile.TemporaryDirectory() as temp:
            engine = Path(temp) / "engine"
            prefix = Path(temp) / "prefix"
            prefix.mkdir()
            expected = str(engine / "bin/wineserver")
            wanted = resources.server_directory_name(prefix)
            def command(*args):
                if args == ("ps", "-axo", "pid=,comm="):
                    return f"17 {expected}\n18 {expected}\n"
                if args[0] == "ps":
                    return "Fri Sep 11 20:00:00 2026 " + expected
                if args[0] == "lsof":
                    return "n/private/tmp/.wine-501/" + (wanted if "18" in args else "server-other")
                self.fail(args)
            with patch.object(resources, "command", side_effect=command):
                identity = resources.find_session_server(engine, prefix)
            self.assertEqual(identity["pid"], 18)

    def test_session_launcher_passes_identity_and_confirms_status(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = dict(resources=Path(temp) / "resources.jsonl", collector_log=Path(temp) / "collector.log")
            (Path(temp) / "session-status.json").write_text(json.dumps(
                dict(collector_pid=12345, session=SERVER, status="starting")))
            with patch.object(resources, "find_session_server", return_value=SERVER), \
                 patch.object(resources, "atomic_json") as save, patch.object(launch.subprocess, "Popen") as popen:
                popen.return_value.pid = 12345
                popen.return_value.poll.return_value = None
                result = launch.start_resource_capture(Path("/engine"), paths, prefix=Path("/prefix"))
            args = popen.call_args.args[0]
            self.assertIn("--follow-session", args)
            self.assertNotIn("--wait-for-game", args)
            self.assertEqual(args[args.index("--session-pid") + 1], "17")
            self.assertEqual(args[args.index("--session-start") + 1], SERVER["start_token"])
            self.assertEqual(args[args.index("--session-seconds") + 1], "21600")
            self.assertTrue(result["startup_confirmed"])
            save.assert_called_once()

    def test_duplicate_or_failed_child_is_not_reported_ready(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = dict(resources=Path(temp) / "resources.jsonl", collector_log=Path(temp) / "collector.log")
            with patch.object(resources, "find_session_server", return_value=SERVER), \
                 patch.object(resources, "atomic_json"), patch.object(launch.subprocess, "Popen") as popen:
                popen.return_value.pid = 12345
                popen.return_value.poll.return_value = 0
                result = launch.start_resource_capture(Path("/engine"), paths, prefix=Path("/prefix"))
            self.assertFalse(result["startup_confirmed"])
            self.assertIn("warning", result)

    def test_exited_collector_cannot_confirm_stale_starting_status(self):
        with tempfile.TemporaryDirectory() as temp:
            paths = dict(resources=Path(temp) / "resources.jsonl", collector_log=Path(temp) / "collector.log")
            (Path(temp) / "session-status.json").write_text(json.dumps(
                dict(collector_pid=12345, session=SERVER, status="starting")))
            with patch.object(resources, "find_session_server", return_value=SERVER), \
                 patch.object(resources, "atomic_json"), patch.object(launch.subprocess, "Popen") as popen:
                popen.return_value.pid = 12345
                popen.return_value.poll.return_value = 1
                result = launch.start_resource_capture(Path("/engine"), paths, prefix=Path("/prefix"))
            self.assertFalse(result["startup_confirmed"])

    def test_transient_discovery_failure_retries_within_bounded_window(self):
        with tempfile.TemporaryDirectory() as temp:
            clock = Clock()
            paths = dict(resources=Path(temp) / "resources.jsonl", collector_log=Path(temp) / "collector.log")
            (Path(temp) / "session-status.json").write_text(json.dumps(
                dict(collector_pid=12345, session=SERVER, status="running")))
            observations = [subprocess.TimeoutExpired("ps", 3), OSError()]
            def discover(*args):
                if observations: raise observations.pop(0)
                return SERVER
            with patch.object(resources, "find_session_server", side_effect=discover) as find, \
                 patch.object(resources, "atomic_json"), patch.object(launch.subprocess, "Popen") as popen, \
                 patch.object(launch.time, "monotonic", clock.monotonic), patch.object(launch.time, "sleep", clock.sleep):
                popen.return_value.pid = 12345
                popen.return_value.poll.return_value = None
                result = launch.start_resource_capture(Path("/engine"), paths, prefix=Path("/prefix"))
            self.assertGreater(find.call_count, 3)
            self.assertGreaterEqual(clock.now, 2.4)
            self.assertLess(clock.now, 4)
            self.assertTrue(result["startup_confirmed"])

    def test_startup_parent_is_replaced_before_binding_collector(self):
        with tempfile.TemporaryDirectory() as temp:
            clock = Clock()
            paths = dict(resources=Path(temp) / "resources.jsonl", collector_log=Path(temp) / "collector.log")
            (Path(temp) / "session-status.json").write_text(json.dumps(
                dict(collector_pid=12345, session=SERVER, status="running")))
            parent = dict(SERVER, pid=SERVER['pid']+100)
            with patch.object(resources, 'find_session_server', side_effect=lambda *args: parent if clock.now < 1 else SERVER), \
                 patch.object(resources, 'atomic_json'), patch.object(launch.subprocess, 'Popen') as popen, \
                 patch.object(launch.time, 'monotonic', clock.monotonic), patch.object(launch.time, 'sleep', clock.sleep):
                popen.return_value.pid = 12345
                popen.return_value.poll.return_value = None
                result = launch.start_resource_capture(Path('/engine'), paths, prefix=Path('/prefix'))
            self.assertEqual(result['session'], SERVER)
            self.assertGreaterEqual(clock.now, 3)
            self.assertTrue(result['startup_confirmed'])

    def test_persistent_discovery_failure_expires_without_spawning_collector(self):
        with tempfile.TemporaryDirectory() as temp:
            clock = Clock()
            paths = dict(resources=Path(temp) / "resources.jsonl", collector_log=Path(temp) / "collector.log")
            with patch.object(resources, "find_session_server", side_effect=OSError()), \
                 patch.object(launch.subprocess, "Popen") as popen, \
                 patch.object(launch.time, "monotonic", clock.monotonic), patch.object(launch.time, "sleep", clock.sleep):
                with self.assertRaises(RuntimeError):
                    launch.start_resource_capture(Path("/engine"), paths, prefix=Path("/prefix"))
            self.assertEqual(clock.now, 10)
            popen.assert_not_called()

    def test_preparation_failure_contract(self):
        class Unsafe(Exception):
            pass
        module = types.ModuleType("prepare_dxmt_pipelines")
        module.PipelinePreparationUnsafeError = Unsafe
        module.prepare_before_launch = Mock(return_value=dict(status="prepared"))
        with patch.dict(sys.modules, prepare_dxmt_pipelines=module):
            self.assertEqual(launch.prepare_source_pipelines()["status"], "prepared")
            module.prepare_before_launch.side_effect = OSError("private command")
            self.assertEqual(launch.prepare_source_pipelines(), dict(status="failed", reason="OSError"))
            module.prepare_before_launch.side_effect = Unsafe()
            with self.assertRaises(SystemExit):
                launch.prepare_source_pipelines()

    def test_main_prepares_before_launch_and_existing_session_prevents_both(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(launch, "ROOT", Path(temp)):
            root = Path(temp)
            engine = root / "runtime/soju-engine-dxmt-local"
            prefix = root / "runtime/prefix-dxmt-local"
            for path, data in ((engine / "local-build-manifest.json", "{}"),
                               (engine / "bin/wine", ""),
                               (engine / "lib/wine/x86_64-windows/d3d11.dll", "dll"),
                               (engine / "lib/wine/x86_64-windows/dxgi.dll", "dll"),
                               (prefix / "drive_c/Program Files (x86)/Battle.net/Battle.net.exe", ""),
                               (prefix / "drive_c/users/Sikarugir/Documents/Overwatch/Settings/Settings_v0.ini", '[Render.13]\nWindowedHeight="1200"\n'),
                               (root / "config/dxmt-source60.conf", "config")):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(data)
            argv = ["launch_cx26.py", "--backend", "dxmt", "--source-build", "--profile", "smooth60"]
            env = dict(WINEMSYNC="1", DXMT_PIPELINE_CACHE_PATH="cache")
            for busy, skip, keep in ((True, False, False), (False, False, False), (False, True, False), (False, True, True)):
                ordering = []
                extra = (["--no-pipeline-prewarm"] if skip else []) + (["--keep-battlenet"] if keep else [])
                with patch.object(sys, "argv", argv + extra), \
                     patch.object(launch.shutil, "disk_usage", return_value=types.SimpleNamespace(free=6 * 2**30)), \
                     patch.object(launch, "build_environment", return_value=env), \
                     patch.object(launch, "running_experiment_servers", return_value=[17] if busy else []), \
                     patch.object(launch, "power_state", return_value={}), \
                     patch.object(launch, "background_snapshot", return_value=[]), \
                     patch.object(launch, "memory_preflight", return_value=dict(warning=None, top_processes=[])), \
                     patch.object(launch, "prepare_source_pipelines", side_effect=lambda: ordering.append("prepare") or {"status": "prepared"}), \
                     patch.object(launch, "start_battlenet_closer", side_effect=lambda engine, prefix, stamp: ordering.append(("closer", prefix.name)) or dict(enabled=True)), \
                     patch.object(launch.subprocess, "Popen", side_effect=lambda *a, **k: ordering.append("launch") or types.SimpleNamespace(pid=42)):
                    if busy:
                        with self.assertRaises(SystemExit):
                            launch.main()
                    else:
                        launch.main()
                expected = [] if busy else (["launch"] if skip else ["prepare", "launch"])
                if not busy and not keep:
                    expected.append(("closer", "prefix-dxmt-local"))  # The watcher receives this launch's engine and prefix.
                self.assertEqual(ordering, expected)
                if not busy:
                    manifest = json.loads(next((root / "logs").glob("cx26-dxmt-battlenet-*.json")).read_text())
                    self.assertEqual(manifest["battlenet_exit_on_launch"]["enabled"], not keep)
                    self.assertIn("session_conditions", manifest)
                    for path in (root / "logs").glob("cx26-dxmt-battlenet-*"):
                        path.unlink()


if __name__ == "__main__":
    unittest.main()
