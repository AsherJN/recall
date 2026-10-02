"""Candidate v4: overlay presentation window and memory pre-flight (no game, no GPU)."""
import os
from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import launch_cx26 as launch  # noqa: E402

ENGINE = ROOT / "runtime/soju-engine-dxmt-local"
PREFIX = ROOT / "runtime/prefix-dxmt-local"
DRIVER = ROOT / "runtime/source/wine-v1/dlls/winemac.drv"


class OverlayOption(unittest.TestCase):
    def build(self, **kwargs):
        return launch.build_environment("dxmt", ENGINE, PREFIX, profile="smooth60", source_build=True,
                                        resolution=1200, **kwargs)

    def test_overlay_is_opt_in(self):
        self.assertEqual(self.build()["DXMT_CANVAS_OVERLAY"], "0")
        self.assertEqual(self.build(overlay=True)["DXMT_CANVAS_OVERLAY"], "1")

    def test_stock_profile_never_sets_the_overlay(self):
        env = launch.build_environment("dxmt", ENGINE, PREFIX, profile="baseline")
        self.assertNotIn("DXMT_CANVAS_OVERLAY", env)

    def test_driver_hosts_the_view_in_a_non_key_mouse_transparent_child_window(self):
        source = (DRIVER / "cocoa_v1.m").read_text()
        for needle in ['getenv("DXMT_CANVAS_OVERLAY")', "canBecomeKeyWindow { return NO; }", "setIgnoresMouseEvents:YES",
                       "setLevel:NSMainMenuWindowLevel + 1", "NSWindowCollectionBehaviorCanJoinAllSpaces", "orderFrontRegardless", "overlayWarmUp(content)", "NSApplicationDidBecomeActiveNotification",
                       "macdrv_v1_canvas_owner", '"overlay_attached"', '"overlay_detached"']:
            self.assertIn(needle, source, needle)
        self.assertIn("macdrv_v1_canvas_owner", (DRIVER / "cocoa_v1.h").read_text())
        # Mouse moves looked up by window number must map the overlay back to its Wine owner.
        self.assertIn("macdrv_v1_canvas_owner([NSApp windowWithWindowNumber:windowUnderNumber])",
                      (DRIVER / "cocoa_app.m").read_text())

    def test_fixture_reports_overlay_layers(self):
        fixture = (ROOT / "tests/fullscreen/fixture.m").read_text()
        self.assertIn('@"OWOverlayWindow"', fixture)
        self.assertIn('@"overlays":overlays', fixture)
        runner = (ROOT / "tests/fullscreen/run.py").read_text()
        self.assertIn("overlay_expected=env.get('DXMT_CANVAS_OVERLAY')=='1'", runner)
        self.assertIn("pipeline_cache=False,overlay=args.overlay)", runner)

    def test_overlay_shortcut_exists(self):
        path = ROOT / "Measure Overwatch - 1200p (Overlay).command"
        self.assertTrue(path.is_file())
        self.assertIn("--measure --overlay", path.read_text())
        self.assertTrue(path.stat().st_mode & 0o111)


class MemoryPreflight(unittest.TestCase):
    def test_preflight_reports_numbers_and_top_processes(self):
        result = launch.memory_preflight()
        for key in ("available_mib", "free_mib", "compressor_mib", "swap_used_mib"):
            self.assertIsInstance(result[key], int, key)
        self.assertTrue(result["top_processes"])
        self.assertTrue(all(p["resident_mib"] >= 0 and p["name"] for p in result["top_processes"]))
        report = launch.memory_report(result)
        self.assertIn("Memory before launch", report)
        self.assertEqual(bool(result["warning"]), "MEMORY PRESSURE" in report)

    def test_warning_thresholds(self):
        quiet = dict(available_mib=9000, compressor_mib=1000, swap_used_mib=0, top_processes=[], warning=None)
        self.assertNotIn("MEMORY PRESSURE", launch.memory_report(quiet))
        pressed = dict(quiet, warning="only 2000 MiB available")
        self.assertIn("MEMORY PRESSURE", launch.memory_report(pressed))
        self.assertLess(launch.MEMORY_AVAILABLE_WARN_MIB, 8192)

    def test_launcher_exposes_the_flags(self):
        text = (ROOT / "scripts/launch_cx26.py").read_text()
        self.assertIn("'--overlay'", text)
        self.assertIn("'--ignore-memory'", text)
        self.assertIn("canvas_overlay=env.get(\"DXMT_CANVAS_OVERLAY\")", text)
        self.assertIn("memory_preflight=preflight", text)


if __name__ == "__main__":
    unittest.main()
