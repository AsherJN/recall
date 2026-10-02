import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import mouselook_session as session


def stats_line(unix_ms, mode, moves, **extra):
    line = dict(schema=1, unix_ms=unix_ms, pid=7, exe="Overwatch.exe", allowed=True, mode=mode,
                app_active=True, hidden=True, transparent=False,
                clipping=True, hidden_warp=False, clip_handler="confinement", retina=True,
                canvas_scale=1.575, interval_us=0, mac_moves=moves, mac_move_us=0, mac_dx=0, mac_dy=0,
                posted_absolute=moves if mode == "legacy" else 0, posted_relative=0, dropped_after_warp=0,
                warps=0, warp_us=0, mouselook_moves=0, mouselook_posted=0, mouselook_enters=0,
                mouselook_exits=0, clicks=0, switches=0, raw_started=True, raw_switched_off=mode != "raw",
                raw_interval_us=1000, raw_mice=2, raw_moves=0, raw_posted=0, raw_dx=0, raw_dy=0, raw_sources=0,
                pointer_ignored=0, pointer_fallback=0, moves_delivered=moves, deliver_us=0,
                setpos_calls=0, setpos_fast=0, setpos_us=0, setpos_max_us=0, getpos_calls=0,
                getpos_us=0, clip_calls=0, consumer_tid=1, setpos_tid=1)
    line.update(extra)
    return line


class MouselookReport(unittest.TestCase):
    def write_session(self, folder, lines, fps_by_second):
        with (folder / "input-7.jsonl").open("w") as stream:
            for line in lines:
                stream.write(json.dumps(line) + "\n")
        with (folder / "frames-12.csv").open("w") as stream:
            stream.write("schema_version,present_boundary,present_interval_us,shader_compile_starts,unix_us,"
                         "monotonic_us,queue_id,frame_latency_wait_us,event_id,dropped_events,pacing_sleep_us\n")
            for second, fps in fps_by_second.items():
                for frame in range(fps):
                    unix_us = second * 1_000_000 - 999_000 + frame * (999_000 // fps)
                    stream.write(f"4,1,{1_000_000 // fps},0,{unix_us},0,0,0,0,0,0\n")
        # DXMT's event logs sit beside the frame log with the same prefix and are not frames.
        for name in ("frames-12.events.csv", "frames-12.events.1.csv"):
            with (folder / name).open("w") as stream:
                stream.write("schema_version,event_id,event,owner_id,frame_id,chunk_id,unix_us,monotonic_us,"
                             "duration_us,dropped_events\n")
                for second in fps_by_second:
                    for event in range(200):
                        stream.write(f"1,{event},completion_wait,1,0,0,{second * 1_000_000 - 990_000 + event * 4000},0,0,0\n")

    def test_fps_is_split_by_mode_and_mouse_motion(self):
        lines, fps = [], {}
        for second in range(1, 21):
            mode = "legacy" if second <= 10 else "mouselook"
            moving = second % 2 == 0
            lines.append(stats_line(second * 1000, mode, 1000 if moving else 0,
                                    warps=100 if mode == "legacy" and moving else 0,
                                    setpos_calls=100 if moving else 0,
                                    setpos_fast=100 if mode == "mouselook" and moving else 0,
                                    setpos_us=400_000 if mode == "legacy" and moving else 0))
            fps[second] = 70 if mode == "legacy" and moving else 100
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            self.write_session(folder, lines, fps)
            with patch("builtins.print"):
                session.report(type("Args", (), {"session": temp})())
            result = json.loads((folder / "report.json").read_text())
        self.assertEqual(result["modes"]["legacy/moving"]["median_fps"], 70)
        self.assertEqual(result["modes"]["legacy/still"]["median_fps"], 100)
        self.assertEqual(result["modes"]["mouselook/moving"]["median_fps"], 100)
        self.assertEqual(result["legacy_fps_drop_while_moving_percent"], 30.0)
        self.assertEqual(result["mouselook_fps_drop_while_moving_percent"], 0.0)
        self.assertEqual(result["modes"]["legacy/moving"]["recentre_wait_us"], 4000.0)
        self.assertEqual(result["modes"]["mouselook/moving"]["recentre_wait_us"], 0)
        self.assertTrue(result["game_behaviour"]["mouselook_engaged"])

    def test_raw_input_reports_its_rate_units_and_delivery_cost(self):
        lines, fps = [], {}
        for second in range(1, 21):
            mode = "mouselook" if second <= 10 else "raw"
            moving = second % 2 == 0
            raw = mode == "raw" and moving
            # 120 pointer events a second either way; raw input adds 2,000 reports in whole counts,
            # 1.5 points each, delivered at most 1,000 times a second at 80 us each.
            lines.append(stats_line(second * 1000, mode, 120 if moving else 0,
                                    mac_dx=900 if moving else 0, mac_dy=600 if moving else 0,
                                    raw_moves=2000 if raw else 0, raw_posted=1000 if raw else 0,
                                    raw_dx=600 if raw else 0, raw_dy=400 if raw else 0,
                                    pointer_ignored=120 if raw else 0,
                                    moves_delivered=(1000 if raw else 120) if moving else 0,
                                    deliver_us=(80_000 if raw else 9_600) if moving else 0))
            fps[second] = 95 if raw else 100
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            self.write_session(folder, lines, fps)
            with patch("builtins.print"):
                session.report(type("Args", (), {"session": temp})())
            result = json.loads((folder / "report.json").read_text())
        raw, pointer = result["modes"]["raw/moving"], result["modes"]["mouselook/moving"]
        self.assertEqual((raw["raw_reports_per_second"], raw["raw_deliveries_per_second"]), (2000, 1000))
        self.assertAlmostEqual(raw["counts_per_point"], 1 / 1.5, places=3)
        self.assertEqual((raw["delivery_ms_per_second"], raw["delivery_us_each"]), (80.0, 80.0))
        self.assertEqual((pointer["delivery_ms_per_second"], pointer["delivery_us_each"]), (9.6, 80.0))
        self.assertIsNone(pointer["counts_per_point"])
        self.assertEqual(result["raw_fps_drop_while_moving_percent"], 5.0)
        self.assertTrue(result["game_behaviour"]["raw_input_engaged"])
        self.assertTrue(result["game_behaviour"]["mouselook_engaged"])
        self.assertEqual(result["raw_mice"], 2)

    def test_menus_transitions_and_background_seconds_are_excluded(self):
        lines = [stats_line(1000, "legacy", 1000, hidden=False),
                 stats_line(2000, "mouselook", 1000, mouselook_enters=1),
                 stats_line(3000, "legacy", 1000, app_active=False),
                 stats_line(4000, "legacy", 50)]
        self.assertEqual([session.classify(line) for line in lines], [None, None, None, None])
        self.assertEqual(session.classify(stats_line(5000, "mouselook", 0)), ("mouselook", "still"))

    def test_launch_environment_matches_the_app_plus_diagnostics(self):
        with tempfile.TemporaryDirectory() as temp:
            env = session.environment(Path(temp), True, 0)
        contract = session.candidate_contract.load()["environment"]
        for key, value in contract.items():
            self.assertEqual(env[key], value)
        self.assertEqual(env["WINEMAC_MOUSELOOK"], "Overwatch.exe")
        self.assertEqual(env["WINELOADER"], str(session.ENGINE / "bin/wine"))
        self.assertTrue(env["DXMT_FRAME_LOG"].startswith("Z:\\"))
        self.assertNotIn("WINEMAC_MOUSELOOK_INTERVAL_US", env)
        # Raw input is on by default, with the driver's own delivery interval.
        self.assertNotIn("WINEMAC_MOUSELOOK_RAW", env)
        self.assertNotIn("WINEMAC_MOUSELOOK_RAW_INTERVAL_US", env)

    def test_battlenet_closer_accepts_the_play_test_engine_and_environment(self):
        # The play-test runs the test engine against the installed app's environment. The closer
        # refused that prefix, so Battle.net stayed open behind the game during the first play-test.
        import battlenet_closer
        self.assertTrue(battlenet_closer.accepts(session.ENGINE, session.APP_ROOT / "environment"))
        self.assertFalse(battlenet_closer.accepts(Path("/Applications/CrossOver.app"), session.APP_ROOT / "environment"))
        self.assertFalse(battlenet_closer.accepts(session.ENGINE, Path.home() / "Library/Application Support/Other/environment"))

    def test_raw_input_can_be_switched_off_or_retimed_for_comparison(self):
        with tempfile.TemporaryDirectory() as temp:
            off = session.environment(Path(temp), True, 0, raw=False)
            every = session.environment(Path(temp), True, 0, raw_interval_us=0)
        self.assertEqual(off["WINEMAC_MOUSELOOK_RAW"], "0")
        self.assertEqual(every["WINEMAC_MOUSELOOK_RAW_INTERVAL_US"], "0")
        self.assertNotIn("WINEMAC_MOUSELOOK_RAW", every)


if __name__ == "__main__":
    unittest.main()
