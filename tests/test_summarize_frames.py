import importlib.util
from pathlib import Path
import tempfile
import subprocess
import sys
import json
import unittest

SPEC = importlib.util.spec_from_file_location("summarize_frames", Path(__file__).resolve().parents[1] / "scripts/summarize_frames.py")
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)

class FrameSummaryTests(unittest.TestCase):
    def check_text(self, text, **kwargs):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "frames.csv"
            path.write_text(text)
            return MOD.summarize(path, **kwargs)

    def test_schema_three_preserves_missing_time_and_loss(self):
        report = self.check_text(
            "schema_version,present_boundary,present_interval_us,shader_compile_starts,unix_us,monotonic_us,queue_id,frame_latency_wait_us,event_id,dropped_events\n"
            "3,2,16667,1,1000000,2000000,1,4000,1,0\n"
            "3,4,16667,0,2000000,3000000,1,5000,3,1\n", start=.5)
        self.assertEqual(report["schema_version"], 3)
        self.assertEqual(report["intervals"], 1)
        self.assertEqual(report["max_reported_dropped_events"], 1)
        self.assertAlmostEqual(report["total_logged_seconds"], 1.017)
        self.assertEqual(report["first_unix_us"], 983333)

    def test_rotations_preserve_timestamp_gaps_and_skip_missing_or_duplicate_rows(self):
        header='schema_version,present_boundary,present_interval_us,shader_compile_starts,unix_us,monotonic_us,queue_id,frame_latency_wait_us,event_id,dropped_events\n'
        first='3,100,16667,1,1000000,2000000,1,4000,100,0\n'
        missing='3,101,16667,0,,,1,4000,101,1\n'
        last='3,102,16667,0,2000000,3000000,1,5000,102,1\n'
        with tempfile.TemporaryDirectory() as folder:
            path=Path(folder)/'frames-123.csv';oldest=path.with_suffix('.2.csv');middle=path.with_suffix('.1.csv')
            oldest.write_text(header+first);middle.write_text(header+first+missing);path.write_text(header+last)
            path.with_suffix('.events.csv').write_text('unrelated event stream')
            (path.parent/'frames-456.2.csv').write_text('unrelated process')
            report=MOD.summarize(path,include_rotated=True,start=.5)
            self.assertEqual(report['files'],list(map(str,[oldest,middle,path])))
            self.assertEqual((report['intervals'],report['skipped_rows'],report['duplicate_rows']),(1,1,1))
            self.assertEqual(report['oldest_retained_monotonic_us'],1983333)
            self.assertEqual(report['first_unix_us'],983333)
            self.assertAlmostEqual(report['total_logged_seconds'],1.017)
            self.assertIn('not the entire process lifetime',report['capture_scope'])
            self.assertEqual(MOD.summarize(path)['intervals'],1)
            result=subprocess.run([sys.executable,str(Path(MOD.__file__)),str(path),'--include-rotated','--start-seconds','.5'],
                                  capture_output=True,text=True,check=True)
            self.assertEqual(json.loads(result.stdout),report)

    def test_sparse_event_stream_is_not_a_frame_csv(self):
        with self.assertRaises(ValueError):
            self.check_text('schema_version,event_id,event,owner_id,frame_id,chunk_id,unix_us,monotonic_us,duration_us,dropped_events\n')

    def test_schema_two_remains_supported(self):
        report = self.check_text("schema_version,present_boundary,present_interval_us,shader_compile_starts\n2,2,16667,1\n2,3,51000,0\n")
        self.assertEqual(report["schema_version"], 2)
        self.assertEqual(report["over_50ms"], 1)
        self.assertEqual(report["shader_compile_starts"], 1)

if __name__ == "__main__": unittest.main()
