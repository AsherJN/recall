import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import mark_measurement as markers


class MeasurementMarkers(unittest.TestCase):
    def test_discovery_includes_rotated_parts_and_summaries(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            names = ["resources.jsonl", "resources.3.jsonl", "frames-4.1.csv", "frames-4.events.csv",
                     "frames-4.summary.json", "display-7.2.csv", "display-7.hitches.csv",
                     "pipeline-cache-7.1.jsonl", "session-status.json"]
            for name in names + ["private.txt"]:
                (folder / name).touch()
            self.assertEqual(markers.discover_artifacts(folder), sorted(names))

    def test_marker_keeps_explicit_time_separate_from_last_sampled_games(self):
        with tempfile.TemporaryDirectory() as temp:
            status = dict(session={"pid": 1}, time="old", games=[{"pid": 2}])
            saved = markers.add_marker(Path(temp), status, "quickplay_entered")
            record = json.loads((Path(temp) / "session-markers.jsonl").read_text())
            self.assertEqual(record, saved)
            self.assertEqual(record["last_observed_games"], [{"pid": 2}])
            self.assertEqual(record["resource_status_time"], "old")
            self.assertNotEqual(record["time"], "old")
            self.assertGreater(record["monotonic_ns"], 0)

    def test_limit_and_symlink_refuse_without_overwriting(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp)
            path = folder / "session-markers.jsonl"
            path.write_text("keep")
            with patch.object(markers, "MARKER_MAX_BYTES", 5), self.assertRaises(ValueError):
                markers.add_marker(folder, {"session": {}}, "game_closed")
            self.assertEqual(path.read_text(), "keep")
            path.unlink()
            target = folder / "elsewhere"
            target.write_text("untouched")
            path.symlink_to(target)
            with self.assertRaises(OSError):
                markers.add_marker(folder, {"session": {}}, "game_closed")
            self.assertEqual(target.read_text(), "untouched")

    def test_automatic_selection_rejects_stale_collector(self):
        with tempfile.TemporaryDirectory() as temp, patch.object(markers, "ROOT", Path(temp)):
            folder = Path(temp) / "logs/dxmt/measured-test"
            folder.mkdir(parents=True)
            active = dict(resources=str(folder / "resources.jsonl"), startup_confirmed=True, session={"pid": 1})
            (folder.parent / "active-measurement.json").write_text(json.dumps(active))
            status = dict(status="running", collector_identity={"pid": 2}, session={"pid": 1})
            (folder / "session-status.json").write_text(json.dumps(status))
            with patch.object(markers.resources, "session_alive", return_value=False):
                with self.assertRaises(ValueError):
                    markers.selected_session()
                self.assertEqual(markers.selected_session(folder), (folder.resolve(), status))


if __name__ == "__main__":
    unittest.main()
