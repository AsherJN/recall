"""Exercise real kernel counters and bounded recorder failure/identity handling."""
import csv
import errno
import os
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from process_probe import NativeProbe, ProcessRecorder
from analyze_process_stalls import process_bins, correlate, COUNTERS


class NativeCounters(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.probe = NativeProbe()

    def test_cpu_units_and_clock_match_independent_python_measurement(self):
        a = self.probe.sample(os.getpid())
        cpu = time.process_time()
        end = time.monotonic() + .15
        while time.monotonic() < end:
            pass
        b = self.probe.sample(os.getpid(), a['start_abstime'])
        expected = time.process_time() - cpu
        actual = (b['user_ns'] + b['system_ns'] - a['user_ns'] - a['system_ns']) / 1e9
        self.assertAlmostEqual(actual, expected, delta=.015)
        self.assertLess(abs(b['monotonic_ns'] - time.monotonic_ns()), 10_000_000)
        self.assertLess(abs(b['unix_us'] - time.time_ns() // 1000), 10_000)

    def test_allocated_touched_pages_increase_faults_and_footprint(self):
        a = self.probe.sample(os.getpid())
        memory = bytearray(16 * 1024 * 1024)
        for offset in range(0, len(memory), 4096):
            memory[offset] = 1
        b = self.probe.sample(os.getpid(), a['start_abstime'])
        self.assertGreater(b['faults_u32'], a['faults_u32'])
        self.assertGreater(b['footprint_bytes'], a['footprint_bytes'] + 8 * 1024 * 1024)
        self.assertEqual(b['vm_page_bytes'], 16384)
        self.assertEqual(b['vm_error'], 0)
        self.assertEqual(b['cpu_error'], 0)

    def test_changed_start_identity_is_rejected(self):
        current = self.probe.sample(os.getpid())
        with self.assertRaises(OSError) as error:
            self.probe.sample(os.getpid(), current['start_abstime'] + 1)
        self.assertEqual(error.exception.errno, errno.ESTALE)

    def test_invalid_pid_and_incorrect_buffer_abi_are_rejected(self):
        with self.assertRaises(OSError):
            self.probe.sample(-1)
        values = self.probe.buffer()
        result = self.probe.library.ow_probe_sample(os.getpid(), 0, values, len(values) - 1)
        self.assertEqual(result, errno.EINVAL)


class Recorder(unittest.TestCase):
    def recorder(self, path, **kwargs):
        probe = Mock()
        probe.fields = ['unix_us', 'monotonic_ns', 'query_duration_ns', 'start_abstime']
        probe.sample.return_value = dict(unix_us=100, monotonic_ns=100, query_duration_ns=10, start_abstime=99)
        return ProcessRecorder(path, probe, **kwargs), probe

    def test_unattributed_pid_is_never_sampled_and_same_pid_new_start_rearms(self):
        with tempfile.TemporaryDirectory() as folder:
            recorder, probe = self.recorder(Path(folder) / 'counters.csv')
            try:
                recorder.set_targets([dict(pid=3)])
                recorder.tick()
                probe.sample.assert_not_called()
                recorder.set_targets([dict(pid=3, native_start_abstime=99)])
                recorder.tick()
                probe.sample.assert_called_with(3, 99)
                recorder.set_targets([dict(pid=3, native_start_abstime=100)])
                recorder.tick()
                probe.sample.assert_called_with(3, 100)
                recorder.set_targets([])
                recorder.tick()
                self.assertEqual(probe.sample.call_count, 2)
            finally:
                recorder.close()

    def test_query_failure_is_explicit_without_fabricated_zero_counters(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'counters.csv'
            recorder, probe = self.recorder(path)
            probe.sample.side_effect = OSError(errno.ESTALE, 'wrong process')
            recorder.set_targets([dict(pid=3, native_start_abstime=99)])
            recorder.tick()
            recorder.close()
            with path.open() as stream:
                row = next(csv.DictReader(stream))
            self.assertEqual(int(row['error']), errno.ESTALE)
            self.assertEqual(row['query_duration_ns'], '')
            self.assertEqual(recorder.errors, 1)

    def test_rotation_keeps_complete_recent_rows_with_bounded_files(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'counters.csv'
            recorder, probe = self.recorder(path, part_bytes=1400, backups=2)
            recorder.set_targets([dict(pid=3, native_start_abstime=99)])
            for i in range(200):
                probe.sample.return_value['unix_us'] = i
                recorder.tick()
            recorder.close()
            files = list(Path(folder).glob('*.csv'))
            self.assertEqual(len(files), 3)
            self.assertTrue(all(p.stat().st_size <= 1400 for p in files))
            with path.open() as stream:
                rows = list(csv.DictReader(stream))
            self.assertEqual(int(rows[-1]['unix_us']), 199)
            self.assertGreater(recorder.rotations, 2)

    def test_existing_output_never_overwritten(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'counters.csv'
            path.write_text('original')
            with self.assertRaises(FileExistsError):
                self.recorder(path)
            self.assertEqual(path.read_text(), 'original')

    def test_background_failure_reported_and_worker_stops(self):
        with tempfile.TemporaryDirectory() as folder:
            recorder, _ = self.recorder(Path(folder) / 'counters.csv')
            with patch.object(recorder, 'tick', side_effect=RuntimeError('redacted')):
                recorder.start()
                recorder.thread.join(timeout=2)
            recorder.close()
            self.assertFalse(recorder.thread.is_alive())
            self.assertEqual(recorder.status()['status'], 'failed')
            self.assertEqual(recorder.status()['failure'], 'RuntimeError')


class Correlation(unittest.TestCase):
    def rows(self):
        base = dict.fromkeys(COUNTERS, '0')
        base.update(pid='7', error='0', start_abstime='19', unix_us='1000000',
                    monotonic_ns='1000000000', query_duration_ns='1000', vm_error='0',
                    cpu_error='0', task_counter_saturated='0', footprint_bytes='1048576',
                    resident_bytes='1048576', vm_page_bytes='16384')
        later = base | dict(unix_us='1100000', monotonic_ns='1100000000',
                            user_ns='50000000', system_ns='25000000', runnable_ns='80000000',
                            faults_u32='42', vm_decompressions='100', cpu_idle_ticks_u32='20',
                            cpu_user_ticks_u32='80')
        return base, later

    def test_units_and_full_bin_deltas_are_preserved(self):
        bins, rejected = process_bins(self.rows(), 7)
        self.assertEqual(rejected, {})
        self.assertEqual(bins[0]['game_cpu_percent'], 75)
        self.assertEqual(bins[0]['delta']['faults_u32'], 42)
        self.assertAlmostEqual(bins[0]['host_busy_percent'], 80)
        self.assertEqual(bins[0]['runnable_minus_cpu_ms'], 5)

    def test_invalid_boundaries_are_unknown_not_zero_activity(self):
        changes = [dict(error='3'), dict(start_abstime='20'),
                   dict(monotonic_ns='1900000000'), dict(unix_us='1200000'),
                   dict(query_duration_ns='30000000'), dict(task_counter_saturated='1'),
                   dict(vm_error='1'), dict(cpu_error='1')]
        for change in changes:
            a, b = self.rows()
            bins, rejected = process_bins([a, b | change], 7)
            self.assertEqual(bins, [])
            self.assertEqual(sum(rejected.values()), 1)

    def test_missing_counter_coverage_and_pipeline_overlap_are_distinct(self):
        bins, _ = process_bins(self.rows(), 7)
        hitches = [dict(start_utc_s=1.05, end_utc_s=1.25, duration_ms=200, sequence=1)]
        runtime = [dict(event='runtime', result='created', key='known', start_unix_us=1200000,
                        end_unix_us=1300000, cost_us=100000, known_at_launch=True)]
        joined = correlate(bins, hitches, runtime)[0]
        self.assertAlmostEqual(joined['counter_coverage_fraction'], .25)
        self.assertEqual(joined['bins'][0]['delta']['faults_u32'], 42)
        self.assertEqual(joined['overlapping_pipeline_creates'][0]['key'], 'known')


if __name__ == '__main__':
    unittest.main()
