import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]/'scripts'))
from analyze_resource_ops import intervals, join


class ResourceOperations(unittest.TestCase):
    def test_aggregate_anchors_separate_windows_clock(self):
        row = dict(snapshot_monotonic_ns='5000000000', snapshot_unix_us='100000000',
                   first_start_ns='4600000000', last_end_ns='4950000000',
                   calls='300', known_byte_calls='200', bytes='25600', units='300',
                   total_ns='110000000', max_ns='3000000', snapshot='8', shard='3',
                   operation='buffer_upload', thread_id='44', source_file='fixture')
        batch = intervals([row], True)[0]
        self.assertAlmostEqual(batch['start_utc_s'], 99.6)
        self.assertAlmostEqual(batch['end_utc_s'], 99.95)
        self.assertEqual(batch['calls'], 300)
        row['last_end_ns'] = '5000000001'
        with self.assertRaises(ValueError): intervals([row], True)

    def test_nested_spans_and_preceding_context_stay_separate(self):
        hitch = dict(start_utc_s=10, end_utc_s=10.1)
        span = dict(start_utc_s=9.99, end_utc_s=10.05, duration_ns=60000000)
        inner = dict(start_utc_s=10.01, end_utc_s=10.03, duration_ns=20000000)
        previous = dict(start_utc_s=9.94, end_utc_s=9.96, duration_ns=20000000)
        batch = dict(start_utc_s=9.8, end_utc_s=10.2, calls=900)
        out = join({'hitches': [hitch]}, [span, inner, previous], [batch])['hitches'][0]
        self.assertEqual(out['resource_spans_overlapping'], [span, inner])
        self.assertEqual(out['resource_spans_preceding_100ms'], [previous])
        self.assertEqual(out['resource_completion_batches'][0]['calls'], 900)


if __name__ == '__main__': unittest.main()
