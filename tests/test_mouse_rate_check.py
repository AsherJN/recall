import json
from pathlib import Path
import subprocess
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests/mouselook"))
import rate_check


class MouseRateCheckAnalysis(unittest.TestCase):
    """The analysis against generated samples with known rates, delays and units (see synthetic() in rate_check.m)."""

    @classmethod
    def setUpClass(cls):
        if not Path(rate_check.CLANG).exists():
            raise unittest.SkipTest("Command Line Tools clang is not installed")
        rate_check.build()

    def synthetic(self, *extra):
        result = subprocess.run([str(rate_check.EXECUTABLE), "--synthetic", *extra], capture_output=True, text=True,
                                check=True, timeout=60)
        return json.loads(result.stdout)

    def assert_pointer_and_game(self, summary):
        on, off, game = summary["pointer"]["merging_on"], summary["pointer"]["merging_off"], summary["game"]
        self.assertEqual((on["per_s"], on["seconds"]), (120, 15))
        self.assertEqual((off["per_s"], off["seconds"]), (1000, 15))
        self.assertEqual(game["per_s"], 1000)
        # Merged to a 120 Hz tick: a report waits half a tick on average, plus 0.3 ms.
        self.assertAlmostEqual(on["delay_ms"], 1000 / 120 / 2 + 0.3, delta=0.1)
        self.assertAlmostEqual(off["delay_ms"], 1.0, delta=0.01)
        self.assertAlmostEqual(game["delay_ms"], 0.5, delta=0.01)
        self.assertEqual(summary["pointer"]["stamps"], "hardware")
        self.assertEqual(summary["moving_seconds"], 30)
        pointer_per_game = summary["units"]["pointer_per_game"]
        self.assertAlmostEqual(pointer_per_game["x"], 0.5, delta=0.01)
        self.assertAlmostEqual(pointer_per_game["y"], -0.5, delta=0.01)
        self.assertGreater(min(pointer_per_game["fit_x"], pointer_per_game["fit_y"]), 0.99)
        self.assertIn("about 8 times as many updates", " ".join(summary["verdict"]))

    def test_measures_every_source_against_the_mouse_itself(self):
        summary = self.synthetic()
        self.assertEqual(summary["reference"], "mouse")
        self.assertIs(summary["mouse"]["available"], True)
        # The busiest device, not the barely used second one.
        self.assertEqual(summary["mouse"]["device"], "Synthetic Mouse (USB)")
        self.assertEqual(summary["mouse"]["per_s"], 1000)
        self.assertAlmostEqual(summary["mouse"]["delay_ms"], 0.2, delta=0.01)
        self.assert_pointer_and_game(summary)
        units = summary["units"]
        self.assertAlmostEqual(units["pointer_per_mouse"]["x"], 0.5, delta=0.01)
        self.assertAlmostEqual(units["pointer_per_mouse"]["y"], 0.5, delta=0.01)
        self.assertAlmostEqual(units["game_per_mouse"]["x"], 1.0, delta=0.01)
        self.assertAlmostEqual(units["game_per_mouse"]["y"], -1.0, delta=0.01)
        self.assertTrue(summary["verdict"][0].startswith("Your mouse sent about 1,000 updates a second."))

    def test_game_input_is_the_reference_without_permission_to_read_the_mouse(self):
        summary = self.synthetic("--no-mouse")
        self.assertEqual(summary["reference"], "game")
        self.assertIs(summary["mouse"]["available"], False)
        self.assertIsNone(summary["mouse"]["per_s"])
        self.assertNotIn("pointer_per_mouse", summary["units"])
        self.assert_pointer_and_game(summary)
        self.assertFalse(any(line.startswith("Your mouse") for line in summary["verdict"]))

    def test_window_lays_out_and_reports_too_little_movement(self):
        result = subprocess.run([str(rate_check.EXECUTABLE), "--smoke"], capture_output=True, text=True, check=True,
                                timeout=60)
        summary = json.loads(result.stdout)
        self.assertEqual(summary["moving_seconds"], 0)
        self.assertTrue(summary["verdict"][0].startswith("Not enough movement"))
        width, height = map(float, result.stderr.split()[1::2])
        self.assertGreater(width, 500)
        self.assertGreater(height, 300)


if __name__ == "__main__":
    unittest.main()
