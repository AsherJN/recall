from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests/mouselook"))
import timing_check


class MouseTimingCheckAnalysis(unittest.TestCase):
    """The analysis against generated events with known answers (see synthetic() in timing_check.py): a 2,000 Hz
    mouse swiping at 20,000 counts a second, clicks that reach AppKit 3 ms after GCMouse, a second interface that
    repeats every press, and GCMouse silent after the second of three returns from Command-Tab."""

    def test_synthetic(self):
        with tempfile.TemporaryDirectory() as folder:
            summary = timing_check.synthetic(folder)
        self.assertEqual(summary["gcmouse_clock"]["clock"], "mach_absolute")
        self.assertEqual(summary["rate"]["likely_setting_hz"], 2000)
        clicks = summary["clicks"]
        self.assertEqual((clicks["matched"], clicks["appkit_only"], clicks["gcmouse_only"]), (25, 0, 0))
        self.assertAlmostEqual(clicks["gap_ms"]["median"], 3.0, delta=0.01)
        self.assertAlmostEqual(clicks["appkit_age_ms"]["median"], 3.3, delta=0.01)
        self.assertAlmostEqual(clicks["swiping_counts_between"]["median"], 60, delta=5)
        # 60 counts at sensitivity 5: 60 x 0.0066 x 5 degrees.
        self.assertAlmostEqual(clicks["swiping_degrees_between"]["median"], 1.98, delta=0.2)
        self.assertEqual([r["resumed"] for r in summary["switching"]["returns"]], [True, False, True])


if __name__ == "__main__":
    unittest.main()
