"""Latency pass v3 (2026-09-13): input-to-photon metric, pacing/frame-cap launcher options, probe summariser."""
import json
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import challenge_metrics as metrics  # noqa: E402
import display_path_probe as probe  # noqa: E402
import launch_cx26 as launch  # noqa: E402
import set_windowed_1080 as prefs  # noqa: E402

ENGINE = ROOT / "runtime/soju-engine-dxmt-local"
PREFIX = ROOT / "runtime/prefix-dxmt-local"
BASELINE = ROOT / "logs/dxmt/measured-20260912-172736-989144"
CANDIDATE = ROOT / "logs/dxmt/measured-20260912-221242-727685"

SETTINGS = '''[Render.13]\r\nDynamicRenderScale = "0"\r\nFrameRateCap = "600"\r\nFullScreenHeight = "1200"\r\nFullScreenRefresh = "120"\r\nFullScreenWidth = "1920"\r\nFullscreenWindow = "0"\r\nFullscreenWindowEnabled = "0"\r\nUseCustomFrameRates = "1"\r\nUseCustomWorldScale = "1"\r\nWindowedHeight = "1200"\r\nWindowedPosX = "100"\r\nWindowedPosY = "100"\r\nWindowedWidth = "1920"\r\nWindowMode = "0"\r\nWindowedFullscreen = "0"\r\n\r\n[Sound.3]\r\nVolume = "50"\r\n'''


class LauncherOptions(unittest.TestCase):
    def build(self, **kwargs):
        return launch.build_environment("dxmt", ENGINE, PREFIX, profile="smooth60", source_build=True,
                                        resolution=1200, **kwargs)

    def test_pacing_and_framebuffer_only_become_translator_config_lines(self):
        self.assertNotIn("DXMT_CONFIG", self.build())
        self.assertEqual(self.build(pacing=True)["DXMT_CONFIG"], "dxgi.presentPacing=True")
        self.assertEqual(self.build(pacing=True, framebuffer_only=True)["DXMT_CONFIG"],
                         "dxgi.presentPacing=True;dxgi.framebufferOnly=True")

    def test_stock_profile_never_gets_extra_config(self):
        env = launch.build_environment("dxmt", ENGINE, PREFIX, profile="baseline", pacing=True, framebuffer_only=True)
        self.assertNotIn("DXMT_CONFIG", env)

    def test_translator_reads_pacing_and_framebuffer_options(self):
        queue = (ROOT / "runtime/source/dxmt-ow2/src/dxmt/dxmt_command_queue.cpp").read_text()
        header = (ROOT / "runtime/source/dxmt-ow2/src/dxmt/dxmt_command_queue.hpp").read_text()
        presenter = (ROOT / "runtime/source/dxmt-ow2/src/dxmt/dxmt_presenter.cpp").read_text()
        self.assertIn('"dxgi.presentPacing"', queue)
        self.assertIn('"dxgi.presentPacingTargetUs"', queue)
        self.assertIn("pacing_sleep_us_", header)
        self.assertIn("FrameLogTick(latency_wait_us, pacing_us)", header)
        self.assertIn('"dxgi.framebufferOnly"', presenter)
        frame_log = (ROOT / "runtime/source/dxmt-ow2/src/dxmt/dxmt_frame_log.hpp").read_text()
        self.assertIn("pacing_sleep_us", frame_log)

    def test_measured_shortcuts_exist_with_expected_flags(self):
        cases = {
            "Measure Overwatch - 1200p (Pacing).command": ["--measure", "--pacing"],
            "Measure Overwatch - 1200p (Frame Cap 80).command": ["--measure", "--frame-cap 80"],
            "Measure Overwatch - 1200p (Baseline Drawables).command": ["--measure", "--drawables 2"],
        }
        for name, flags in cases.items():
            path = ROOT / name
            self.assertTrue(path.is_file(), name)
            text = path.read_text()
            for flag in flags:
                self.assertIn(flag, text, (name, flag))
            self.assertTrue(path.stat().st_mode & 0o111, name)


class FrameCapPreference(unittest.TestCase):
    def test_cap_sets_frame_rate_and_custom_rates(self):
        after, changes = prefs.update_preferences(SETTINGS, 1200, 80)
        self.assertEqual(changes["FrameRateCap"], dict(before="600", after="80"))
        self.assertEqual(prefs.current_frame_cap(after), 80)
        self.assertIn('UseCustomFrameRates = "1"', after)

    def test_no_cap_leaves_frame_rate_alone(self):
        after, changes = prefs.update_preferences(SETTINGS, 1200)
        self.assertNotIn("FrameRateCap", changes)
        self.assertEqual(prefs.current_frame_cap(after), 600)

    def test_cap_range_is_validated(self):
        with self.assertRaises(ValueError):
            prefs.update_preferences(SETTINGS, 1200, 10)
        with self.assertRaises(ValueError):
            prefs.update_preferences(SETTINGS, 1200, 601)

    def test_apply_reports_current_cap(self):
        import tempfile
        with tempfile.TemporaryDirectory() as folder:
            settings = Path(folder) / "Settings_v0.ini"
            settings.write_text(SETTINGS, newline="")
            result = prefs.apply_preferences(settings, Path(folder) / "backup", 1200, 80)
            self.assertEqual(result["frame_rate_cap"], 80)
            again = prefs.apply_preferences(settings, Path(folder) / "backup", 1200)
            self.assertEqual(again["frame_rate_cap"], 80)
            self.assertEqual(again["changes"], {})


@unittest.skipUnless((BASELINE / "display-23572.csv").exists() and (CANDIDATE / "display-70000.csv").exists(),
                     "local measured sessions are not part of the repository")
class InputToPhoton(unittest.TestCase):
    def test_candidate_and_baseline_latency_chain(self):
        base = metrics.compute(BASELINE, 23572, 1789249740.0, 1789250160.0)
        cand = metrics.compute(CANDIDATE, 70000, None, None)
        self.assertEqual(base["median_input_to_photon_ms"], 28.78)
        self.assertEqual(base["p90_input_to_photon_ms"], 43.13)
        self.assertEqual(base["display_path_over_16ms_percent"], 38.9)
        self.assertEqual(cand["median_input_to_photon_ms"], 26.19)
        self.assertEqual(cand["p90_input_to_photon_ms"], 41.53)
        self.assertEqual(cand["display_path_over_16ms_percent"], 30.4)
        self.assertFalse(cand["latency"]["input_sampling_instrumented"])
        self.assertFalse(cand["latency"]["physical_pixels_measured"])
        check = cand["latency"]["alignment_check_ms"]
        self.assertTrue(-3 < check["p50"] < 8, check)
        table = metrics.table(base, cand)
        self.assertIn("| Median Present-return to next display proxy (ms) | 28.78 | 26.19 | yes |", table)
        self.assertIn("| Median presentation-request-to-display delay (ms) | 14.461 | 17.246 | no |", table)


class ProbeSummary(unittest.TestCase):
    def rows(self, spec, display_ms):
        out = []
        t = 1000.0
        for i, d in enumerate(display_ms):
            gpu_end = t + i * 0.0116
            out.append(dict(spec_index="0", spec=spec, frame=str(i), cpu_start=f"{gpu_end - 0.02:.6f}",
                            main_commit=f"{gpu_end - 0.012:.6f}", drawable_wait_ms="0.010", present_commit=f"{gpu_end - 0.011:.6f}",
                            main_gpu_start=f"{gpu_end - 0.0116:.6f}", main_gpu_end=f"{gpu_end - 0.002:.6f}",
                            gpu_start=f"{gpu_end - 0.0018:.6f}", gpu_end=f"{gpu_end:.6f}", presented=f"{gpu_end + d / 1000:.6f}",
                            main_seen="1", completed_seen="1", presented_seen="1"))
        return out

    def test_summary_reports_long_mode_share_and_label(self):
        rows = self.rows("label=x,size=canvas", [0.1] * 14 + [17.0] * 6)
        summary = probe.summarise(rows)
        self.assertEqual(summary[0]["label"], "x")
        self.assertEqual(summary[0]["display_over_16ms_percent"], 30.0)
        self.assertEqual(summary[0]["valid"], 20)
        self.assertIn("| x |", probe.table(summary))

    def test_too_few_frames_is_reported_not_crashed(self):
        summary = probe.summarise(self.rows("label=y", [0.1] * 3))
        self.assertIn("note", summary[0])


if __name__ == "__main__":
    unittest.main()
