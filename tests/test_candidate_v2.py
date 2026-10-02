"""Candidate v2 (2026-09-12): drawable count, Battle.net exit watcher, collector fields, metrics."""
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import battlenet_closer as closer  # noqa: E402
import challenge_metrics as metrics  # noqa: E402
import launch_cx26 as launch  # noqa: E402
import measure_resources as resources  # noqa: E402

ENGINE = ROOT / "runtime/soju-engine-dxmt-local"
PREFIX = ROOT / "runtime/prefix-dxmt-local"

PS = """  200 Sat Sep 12 20:49:20 2026 C:\\Program Files (x86)\\Battle.net\\Battle.net.exe
  201 Sat Sep 12 20:49:21 2026 C:\\Program Files (x86)\\Battle.net\\Battle.net.exe
  202 Sat Sep 12 20:49:21 2026 C:\\ProgramData\\Battle.net\\Agent\\Agent.9775\\Agent.exe
  203 Sat Sep 12 20:50:00 2026 C:\\Program Files (x86)\\Overwatch\\Overwatch Launcher.exe
  204 Sat Sep 12 20:50:02 2026 C:\\Program Files (x86)\\Overwatch\\_retail_\\Overwatch.exe
  205 Sat Sep 12 20:50:03 2026 C:\\Program Files (x86)\\Overwatch\\_retail_\\Overwatch.exe
  300 Sat Sep 12 20:40:00 2026 C:\\Program Files (x86)\\Battle.net\\Battle.net.exe
  301 Sat Sep 12 20:49:19 2026 /fixture-user/runtime/soju-engine-dxmt-local/bin/wineserver
"""
OURS = str(ENGINE.resolve()) + "/lib/wine/x86_64-unix/ntdll.so\n" + str(PREFIX.resolve()) + "/drive_c/x.exe\n"
OTHER = str(ENGINE.resolve()) + "/lib/wine/x86_64-unix/ntdll.so\n" + str((ROOT / "runtime/prefix-dxmt-ow2-v0.2").resolve()) + "/drive_c/x.exe\n"


def fake_mapped(pid):
    return {200: OURS, 201: OURS, 204: OURS, 300: OTHER}.get(pid)


class CanvasDrawables(unittest.TestCase):
    def build(self, **kwargs):
        with patch.dict(os.environ, {"DXMT_CANVAS_DRAWABLES": "9"}):
            return launch.build_environment("dxmt", ENGINE, PREFIX, profile="smooth60", source_build=True, **kwargs)

    def test_default_is_three_and_two_is_selectable(self):
        self.assertEqual(self.build()["DXMT_CANVAS_DRAWABLES"], "3")
        self.assertEqual(self.build(drawables=2)["DXMT_CANVAS_DRAWABLES"], "2")
        with self.assertRaises(ValueError):
            self.build(drawables=4)

    def test_stock_and_d3dmetal_profiles_do_not_set_the_driver_variable(self):
        with patch.dict(os.environ, {"DXMT_CANVAS_DRAWABLES": "2"}):
            stock = launch.build_environment("dxmt", ROOT / "runtime/soju-engine-dxmt-ow2-v0.2",
                                             ROOT / "runtime/prefix-dxmt-ow2-v0.2", profile="smooth60")
            native = launch.build_environment("d3dmetal", launch.ENGINE, launch.PREFIX)
        self.assertNotIn("DXMT_CANVAS_DRAWABLES", stock)
        self.assertNotIn("DXMT_CANVAS_DRAWABLES", native)

    def test_source_profiles_request_eight_normal_priority_compiler_workers(self):
        for name in ("dxmt-source60.conf", "dxmt-source60-1200.conf"):
            text = (ROOT / "config" / name).read_text()
            self.assertIn("d3d11.shaderCompilerThreads = 8", text)
            self.assertIn("d3d11.shaderCompilerNormalPriority = True", text)
            self.assertIn("dxgi.maxFrameLatency = 1", text)
            self.assertIn("dxgi.sharpPresentation = True", text)

    def test_canvas_driver_source_reads_the_variable_with_a_default_of_three(self):
        source = (ROOT / "runtime/source/wine-v1/dlls/winemac.drv/cocoa_v1.m").read_text()
        self.assertIn('getenv("DXMT_CANVAS_DRAWABLES")', source)
        self.assertIn("layer.maximumDrawableCount = canvasDrawableCount();", source)
        self.assertNotIn("layer.maximumDrawableCount = 2;", source)


class BattlenetCloser(unittest.TestCase):
    def session(self):
        return closer.Session(ENGINE, PREFIX, mapped_fn=fake_mapped)

    def test_only_this_prefix_clients_and_game_are_selected_never_agent_or_other_prefix(self):
        table = closer.process_table(PS)
        self.assertNotIn(202, table)  # Agent.exe is not even a candidate.
        self.assertNotIn(203, table)  # Neither is the Overwatch launcher stub.
        self.assertNotIn(301, table)
        clients, games, unknown = self.session().classify(table)
        self.assertEqual(clients, [200, 201])
        self.assertEqual(games, [204])
        self.assertEqual(unknown, 1)  # 205 has no membership answer and is ignored, never assumed ours.

    def test_plan_waits_for_game_then_grace_then_closes(self):
        self.assertEqual(closer.plan([200], [], None, None, 10.0, 25.0)[0], "wait")
        action, reason, seen, _ = closer.plan([200], [204], None, 10.0, 10.0, 25.0)
        self.assertEqual((action, reason, seen), ("wait", "grace_period", 10.0))
        self.assertEqual(closer.plan([200], [204], 10.0, 30.0, 30.0, 25.0)[0], "wait")
        self.assertEqual(closer.plan([200], [204], 10.0, 36.0, 36.0, 25.0)[0], "close")
        self.assertEqual(closer.plan([], [204], 10.0, 36.0, 36.0, 25.0)[1], "no_client_left")
        # No client for longer than the client timeout and no game: give up.
        self.assertEqual(closer.plan([], [], None, 0.0, 130.0, 25.0)[1], "client_exited_before_game")
        # Before any client was ever seen, keep waiting (Wine re-spawns the client after launch).
        self.assertEqual(closer.plan([], [], None, None, 130.0, 25.0)[0], "wait")

    def test_run_signals_exactly_this_prefix_clients_and_records_a_log(self):
        table = closer.process_table(PS)
        killed = []
        after = {pid: row for pid, row in table.items() if pid not in (200, 201)}
        states = iter([table, table, table, after])
        clock = iter([0.0, 0.0, 0.0, 40.0, 40.0, 41.0, 44.0, 44.0, 45.0])
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "closer.json"
            record = closer.run(self.session(), grace_seconds=25.0, timeout_seconds=600, poll_seconds=0,
                                table_fn=lambda: next(states, after),
                                kill=lambda pid, sig: killed.append((pid, sig)),
                                monotonic=lambda: next(clock, 100.0), sleep=lambda s: None, log=log)
            self.assertEqual(record["status"], "closed")
            self.assertEqual(killed, [(200, signal.SIGTERM), (201, signal.SIGTERM)])
            self.assertEqual(record["games"], [204])
            self.assertEqual(json.loads(log.read_text())["signalled"], [200, 201])

    def test_dry_run_never_signals(self):
        table = closer.process_table(PS)
        killed = []
        record = closer.run(self.session(), table_fn=lambda: table, kill=lambda *a: killed.append(a),
                            monotonic=iter([0.0, 1.0, 100.0]).__next__, sleep=lambda s: None, dry_run=True)
        self.assertEqual(record["status"], "dry_run_wait")
        self.assertEqual(record["last_clients"], [200, 201])
        self.assertEqual(killed, [])

    def test_launcher_passes_engine_and_prefix_and_records_conditions(self):
        with patch.object(launch.subprocess, "Popen") as popen:
            popen.return_value.pid = 4242
            result = launch.start_battlenet_closer(ENGINE, PREFIX, "stamp-test")
        self.assertTrue(result["enabled"])
        self.assertEqual(result["closer_pid"], 4242)
        arguments = popen.call_args[0][0]
        self.assertEqual(arguments[arguments.index("--engine") + 1], str(ENGINE))
        self.assertEqual(arguments[arguments.index("--prefix") + 1], str(PREFIX))
        self.assertTrue(popen.call_args[1]["start_new_session"])
        snapshot = launch.background_snapshot(limit=3)
        self.assertLessEqual(len(snapshot), 3)
        self.assertTrue(all(set(row) == {"rss_mib", "cpu_percent", "name"} for row in snapshot))
        self.assertTrue(all("/" not in row["name"] and "\\" not in row["name"] for row in snapshot))


class CollectorFields(unittest.TestCase):
    def test_sample_reports_client_rows_and_thermal_without_arguments(self):
        row = resources.sample()
        self.assertIn("client_processes", row)
        self.assertIsInstance(row["thermal"], dict)
        for client in row["client_processes"]:
            self.assertEqual(set(client), {"pid", "name", "cpu_percent", "rss_mib"})
            self.assertIn(client["name"], ("Battle.net.exe", "Agent.exe"))


class ChallengeMetrics(unittest.TestCase):
    def test_baseline_window_reproduces_the_recorded_table(self):
        session = ROOT / "logs/dxmt/measured-20260912-172736-989144"
        if not session.is_dir():
            self.skipTest("baseline session logs are not present on this machine")
        start = metrics.parse_time("2026-09-12T17:49:00")
        result = metrics.compute(session, 23572, start, start + 420)
        self.assertEqual(result["gaps_over_50ms"], 98)
        self.assertEqual(result["gaps_over_100ms"], 52)
        self.assertAlmostEqual(result["average_displayed_fps"], 71.88, places=1)
        self.assertAlmostEqual(result["median_presentation_delay_ms"], 14.46, places=1)
        self.assertAlmostEqual(result["worst_gap_ms"], 360.7, places=0)
        self.assertEqual(result["context"]["battlenet_client_processes"], "not recorded by this session's collector")

    def test_table_marks_direction_correctly(self):
        base = dict(average_displayed_fps=70, p95_interval_ms=25, p99_interval_ms=33, gaps_over_50ms=98,
                    gaps_over_100ms=52, worst_gap_ms=360, median_presentation_delay_ms=14.5,
                    requested_seconds=420, coverage_percent=99.7)
        cand = dict(base, average_displayed_fps=75, gaps_over_50ms=98, worst_gap_ms=400)
        text = metrics.table(base, cand)
        self.assertIn("| Average displayed FPS | 70 | 75 | yes |", text)
        self.assertIn("| Gaps over 50 ms | 98 | 98 | equal |", text)
        self.assertIn("| Worst displayed-frame gap (ms) | 360 | 400 | no |", text)


if __name__ == "__main__":
    unittest.main()
