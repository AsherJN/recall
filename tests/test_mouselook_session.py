import json
from pathlib import Path
import random
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import mouselook_session as session

SETTINGS = {"metal_hud": False, "metalfx": False, "game_mode": True, "korean_support": False}


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
            env = session.environment(Path(temp), SETTINGS)
        contract = session.candidate_contract.load()["environment"]
        for key, value in contract.items():
            self.assertEqual(env[key], value)
        self.assertEqual(env["WINEMAC_MOUSELOOK"], "Overwatch.exe")
        self.assertEqual(env["WINE_GAME_MODE"], "Overwatch.exe")
        self.assertEqual(env["WINELOADER"], str(session.ENGINE / "bin/wine"))
        # Battle.net at its Windows size in points, as the app launches it (battleNetSize).
        self.assertEqual(env["WINE_APP_DPI"], "192:Battle.net.exe;Battle.net Launcher.exe;BlizzardError.exe")
        self.assertTrue(env["DXMT_FRAME_LOG"].startswith("Z:\\"))
        self.assertTrue(env["WINEMAC_INPUT_STATS"].endswith("/input"))
        # Players get precise input from 1.5.0 (the launch settings), and so does a session without --variant.
        self.assertEqual(env["WINEMAC_INPUT_VARIANT"], "precise")
        self.assertEqual(session.players_variant(), "precise")
        for key in ("WINEMAC_MOUSELOOK_INTERVAL_US", "WINEMAC_MOUSELOOK_RAW", "WINEMAC_MOUSELOOK_RAW_INTERVAL_US",
                    "WINEMAC_INPUT_VARIANTS", "WINEMAC_MOUSELOOK_SWITCH",
                    "DXMT_ENABLE_NVEXT", "MTL_HUD_ENABLED", "WINEMAC_SCREEN_READBACK"):
            self.assertNotIn(key, env)

    def test_launch_environment_follows_the_app_settings(self):
        settings = dict(SETTINGS, metalfx=True, metal_hud=True, game_mode=False, korean_support=True)
        with tempfile.TemporaryDirectory() as temp:
            env = session.environment(Path(temp), settings)
        for key, value in session.candidate_contract.load()["metalfx_environment"].items():
            self.assertEqual(env[key], value)
        self.assertEqual(env["MTL_HUD_ENABLED"], "1")
        self.assertEqual(env["WINEMAC_SCREEN_READBACK"], "1")
        self.assertNotIn("WINE_GAME_MODE", env)

    def test_battlenet_closer_accepts_the_play_test_engine_and_environment(self):
        # The play-test runs the test engine against the installed app's environment. The closer
        # refused that prefix, so Battle.net stayed open behind the game during the first play-test.
        import battlenet_closer
        self.assertTrue(battlenet_closer.accepts(session.ENGINE, session.APP_ROOT / "environment"))
        self.assertFalse(battlenet_closer.accepts(Path("/Applications/CrossOver.app"), session.APP_ROOT / "environment"))
        self.assertFalse(battlenet_closer.accepts(session.ENGINE, Path.home() / "Library/Application Support/Other/environment"))

    def test_raw_input_can_be_switched_off_or_retimed_for_comparison(self):
        with tempfile.TemporaryDirectory() as temp:
            off = session.environment(Path(temp), SETTINGS, raw=False, switch="1")
            every = session.environment(Path(temp), SETTINGS, raw_interval_us=0)
            fixed = session.environment(Path(temp), SETTINGS, variant="fixed", switch="timing")
        self.assertEqual((off["WINEMAC_MOUSELOOK_RAW"], off["WINEMAC_MOUSELOOK_SWITCH"]), ("0", "1"))
        self.assertEqual(every["WINEMAC_MOUSELOOK_RAW_INTERVAL_US"], "0")
        self.assertNotIn("WINEMAC_MOUSELOOK_RAW", every)
        self.assertEqual((fixed["WINEMAC_INPUT_VARIANT"], fixed["WINEMAC_MOUSELOOK_SWITCH"]), ("fixed", "timing"))

    def test_raw_timings_are_reported_apart_with_event_age_and_unmatched_motion(self):
        lines, fps = [], {}
        for second in range(1, 21):
            timing = "legacy" if second <= 10 else "fixed"
            moving = second % 2 == 0
            # 1,000 counts and 1,500 pointer points a second; the legacy timing's event time is
            # hours old, the fixed one a millisecond; in a legacy second 30 points of pointer
            # motion arrived while GCMouse was silent.
            lines.append(stats_line(second * 1000, "raw", 120 if moving else 0, raw_timing=timing,
                                    mac_dx=1500 if moving else 0, raw_dx=1000 if moving else 0,
                                    raw_moves=1000 if moving else 0, raw_posted=500 if moving else 0,
                                    raw_posted_x=1000 if moving else 0, moved_x=1000 if moving else 0,
                                    moved_relative=200 if moving else 0, moved_abs=1000 if moving else 0,
                                    move_age_ms_avg=(222_000_000.0 if timing == "legacy" else 1.0) if moving else 0,
                                    move_age_ms_max=(222_000_100 if timing == "legacy" else 3) if moving else 0,
                                    pointer_unmatched=2 if moving and timing == "legacy" else 0,
                                    pointer_unmatched_dx=30.0 if moving and timing == "legacy" else 0))
            fps[second] = 100
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            self.write_session(folder, lines, fps)
            with patch("builtins.print"):
                session.report(type("Args", (), {"session": temp})())
            result = json.loads((folder / "report.json").read_text())
        legacy, fixed = result["modes"]["raw-legacy/moving"], result["modes"]["raw-fixed/moving"]
        self.assertEqual((legacy["event_age_ms"], fixed["event_age_ms"]), (222_000_000.0, 1.0))
        self.assertEqual((legacy["event_age_max_ms"], fixed["event_age_max_ms"]), (222_000_100, 3))
        self.assertEqual((legacy["unmatched_counts"], fixed["unmatched_counts"]), (100, 0))
        self.assertEqual((fixed["raw_counts"], fixed["delivered_counts"]), (5000, 5000))
        self.assertEqual(result["pipeline"], {"posted_x": 10000, "posted_y": 0, "delivered_x": 10000, "delivered_y": 0})
        self.assertTrue(result["game_behaviour"]["raw_input_engaged"])

    def test_blind_sequence_runs_every_variant_twice_balanced_and_never_twice_in_a_row(self):
        for seed in range(50):
            order = session.blind_sequence(session.VARIANTS, random.Random(seed))
            self.assertEqual(sorted(order), sorted(list(session.VARIANTS) * 2))
            self.assertTrue(all(a != b for a, b in zip(order, order[1:])))
            middle = (len(order) - 1) / 2
            for name in session.VARIANTS:
                places = [i for i, value in enumerate(order) if value == name]
                self.assertLessEqual(abs(sum(places) / 2 - middle), 0.5)

    def test_blind_environment_carries_the_sequence_and_the_mark_hotkey(self):
        blind = {"sequence": ["keys", "legacy"], "stretch_s": 75, "warmup_s": 40}
        with tempfile.TemporaryDirectory() as temp:
            env = session.environment(Path(temp), SETTINGS, blind=blind)
        self.assertEqual((env["WINEMAC_INPUT_VARIANTS"], env["WINEMAC_INPUT_STRETCH_S"], env["WINEMAC_INPUT_WARMUP_S"]),
                         ("keys,legacy", "75", "40"))
        self.assertEqual(env["WINEMAC_MOUSELOOK_SWITCH"], "mark")
        # The warm-up, and the time after the last stretch, run the players' variant.
        self.assertEqual(env["WINEMAC_INPUT_VARIANT"], session.players_variant())

    def test_rate_test(self):
        self.assertEqual(session.rate_test(0, 60, 0, 60), 1.0)
        self.assertAlmostEqual(session.rate_test(5, 60, 5, 60), 1.0)
        self.assertLess(session.rate_test(30, 60, 1, 60), 0.01)
        self.assertGreater(session.rate_test(6, 60, 4, 60), 0.05)

    def test_minimum_macos_field(self):
        self.assertEqual(session.minimum_field("15.0"), 15 << 16)
        self.assertEqual(session.minimum_field("26.5"), 26 << 16 | 5 << 8)



FRAME_HEADER = ("schema_version,present_boundary,present_interval_us,shader_compile_starts,unix_us,monotonic_us,"
                "queue_id,frame_latency_wait_us,event_id,dropped_events,pacing_sleep_us\n")


class BlindReport(unittest.TestCase):
    """A blind test: a warm-up, then stretches of legacy and fixed; fixed hitches every other second
    while the mouse moves. The player marked one hitch, and once when nothing had happened."""

    def session(self, folder):
        sequence = ["legacy", "fixed", "fixed", "legacy"]
        (folder / "session.json").write_text(json.dumps(
            {"blind": {"sequence": sequence, "stretch_s": 10, "warmup_s": 5}}))
        lines, frames = [], []
        second = 1
        for stretch, variant in [(0, "legacy")] * 5 + [(n + 1, v) for n, v in enumerate(sequence) for _ in range(10)]:
            start = second * 1000 - 1000
            hitch = stretch == 0 or (variant == "fixed" and second % 2 == 0)
            for frame in range(125):  # 8 ms frames; a hitching second has one 40 ms frame instead of five
                if hitch and frame < 5:
                    continue
                frames.append((start + 8 * (frame + 1), 8000))
            if hitch:
                frames.append((start + 40, 40000))
            lines.append(dict(stats_line(second * 1000, "raw", 120, raw_moves=1000, raw_posted=500,
                                         raw_dx=900, raw_dy=100, moved_relative=200, moved_abs=1000,
                                         move_age_ms_avg=3.0 if variant == "fixed" else 2.2e8,
                                         delivery_ms_avg=0.8, delivery_ms_max=2.0, key_checks=4,
                                         key_check_ms=0.8, key_check_max_ms=0.5, main_lag_probes=100,
                                         main_lag_ms_avg=0.2, main_lag_ms_max=1.0),
                              variant=variant, stretch=stretch, switches=1 if stretch and second in (6, 16, 26, 36) else 0,
                              marks_ms=[]))
            second += 1
        # A mark 500 ms after the hitch of second 18 (stretch 2, fixed), and one in quiet legacy second 9.
        lines[17]["marks_ms"] = [17_540.0]
        lines[8]["marks_ms"] = [8_500.0]
        # The hotkey's own hitch, 100 ms after the legacy mark, is left out.
        frames.append((8_600, 30000))
        with (folder / "input-7.jsonl").open("w") as stream:
            for line in lines:
                stream.write(json.dumps(line) + "\n")
        with (folder / "frames-12.csv").open("w") as stream:
            stream.write(FRAME_HEADER)
            for stamp, interval in sorted(frames):
                stream.write(f"5,1,{interval},0,{stamp * 1000},0,1,0,0,0,0\n")

    def test_variants_are_compared_with_hitches_marks_and_stretches(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            self.session(folder)
            with patch("builtins.print"):
                session.report(type("Args", (), {"session": temp})())
            result = json.loads((folder / "report.json").read_text())
            page = (folder / "report.html").read_text()
        blind = result["blind"]
        legacy, fixed = blind["variants"]["legacy"], blind["variants"]["fixed"]
        # 18 clean seconds each (the four seconds a stretch began in are left out, and so is the warm-up).
        self.assertEqual((legacy["moving_seconds"], fixed["moving_seconds"]), (18, 18))
        self.assertEqual(legacy["hitches"], 0)
        # Even seconds hitch; 16 and 26 began stretches and are left out.
        self.assertEqual(fixed["hitches"], 8)
        self.assertEqual(fixed["hitches_per_minute"], 26.7)
        self.assertEqual(fixed["hitches_marked_share"], 0.12)
        self.assertEqual(fixed["worst_frame_ms"], 40.0)
        self.assertEqual((legacy["marks"], legacy["marks_after_a_hitch"]), (1, 0))
        self.assertEqual((fixed["marks"], fixed["marks_after_a_hitch"]), (1, 1))
        self.assertEqual(fixed["event_times"], "real")
        self.assertEqual(legacy["event_times"], "stale")
        comparison = blind["compared_with_legacy"]["fixed"]
        self.assertEqual((comparison["direction"], comparison["verdict"]), ("more", "clear"))
        self.assertEqual(blind["smoothest_first"], ["legacy", "fixed"])
        self.assertEqual([row["variant"] for row in blind["stretches"]], ["legacy", "fixed", "fixed", "legacy"])
        # The modes table leaves the warm-up out too.
        self.assertEqual(result["modes"]["raw-legacy/moving"]["seconds"], 18)
        self.assertIn("Blind mouse test", page)
        self.assertIn("Both (the first fix)", page)


class KeepSegments(unittest.TestCase):
    def test_rotated_segments_are_kept_once_and_read_back(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            for name, stamp in (("frames-12-run2.1.csv", 1000), ("frames-12-run2.2.csv", 500)):
                (folder / name).write_text(FRAME_HEADER + f"5,1,8000,0,{stamp * 1000},0,1,0,0,0,0\n")
            (folder / "frames-12-run2.events.1.csv").write_text(
                "schema_version,event_id,event,owner_id,frame_id,chunk_id,unix_us,monotonic_us,duration_us,"
                "dropped_events\n1,1,encode,1,0,0,999000,0,0,0\n")
            (folder / "frames-12-run2.csv").write_text(FRAME_HEADER + "5,1,8000,0,1008000,0,1,0,0,0,0\n")
            self.assertEqual(session.keep_segments(folder), 3)
            self.assertEqual(session.keep_segments(folder), 0)
            kept = sorted(path.name for path in (folder / "kept").iterdir())
            self.assertEqual(kept, ["frames-12-run2.1000000.csv", "frames-12-run2.500000.csv",
                                    "frames-12-run2.events.999000.csv"])
            # DXMT drops the oldest segment; the kept copy still counts, once.
            (folder / "frames-12-run2.2.csv").unlink()
            self.assertEqual(session.frame_records(folder), [(500.0, 8.0), (1000.0, 8.0), (1008.0, 8.0)])


if __name__ == "__main__":
    unittest.main()
