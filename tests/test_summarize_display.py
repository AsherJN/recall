import csv
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from summarize_display import summarize


HEADER = ("schema_version,event,unix_ms,native_pid,sequence,layer_ptr,drawable_id,command_ptr,"
          "request_host_s,event_host_s,minimum_duration_s,presented_s,presented_state,"
          "gpu_start_s,gpu_end_s,gpu_state,command_status,error_code,callbacks_seen,"
          "dropped_events,dropped_requests,active_traces").split(",")


def event(kind, sequence, request=100, pid=123, layer="abc", **overrides):
    row = dict.fromkeys(HEADER, 0)
    row.update(schema_version=1, event=kind, native_pid=pid, sequence=sequence,
               layer_ptr=layer, request_host_s=request, event_host_s=request,
               minimum_duration_s=1 / 60, presented_state="pending", gpu_state="pending")
    row.update(overrides)
    return row


def presented(sequence, request, shown, **overrides):
    return event("presented", sequence, request, presented_s=shown,
                 presented_state="valid", callbacks_seen=1, **overrides)


class DisplaySummary(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / "display.csv"

    def write(self, rows):
        with self.path.open("w", newline="") as stream:
            writer = csv.DictWriter(stream, HEADER)
            writer.writeheader()
            writer.writerows(rows)

    def test_rotations_join_split_callbacks_and_preserve_missing_id_gap(self):
        def write_part(path, rows):
            with path.open('w',newline='') as stream:
                writer=csv.DictWriter(stream,HEADER);writer.writeheader();writer.writerows(rows)
        oldest=self.path.with_suffix('.2.csv');middle=self.path.with_suffix('.1.csv')
        write_part(oldest,[event('request',41,100),presented(41,100,100.01),event('request',42,100.02)])
        write_part(middle,[presented(42,100.02,100.03),event('request',43,100.04)])
        write_part(self.path,[presented(43,100.04,100.05),presented(45,100.08,100.09)])
        self.path.with_suffix('.events.csv').write_text('unrelated event stream must not be read')
        (self.path.parent/'display-other.2.csv').write_text('another process must not be read')
        alone=summarize(self.path)
        together=summarize(self.path,include_rotated=True)
        self.assertEqual(together['files'],list(map(str,[oldest,middle,self.path])))
        self.assertEqual(together['first_valid_presented_host_s'],100.01)
        self.assertEqual(together['oldest_retained_event_host_s'],100)
        self.assertIn('not the entire process lifetime',together['capture_scope'])
        self.assertEqual(alone['groups'][0]['selected_coverage']['known_traces'],2)
        group=together['groups'][0]
        self.assertEqual(group['selected_coverage']['known_traces'],4)
        self.assertEqual(group['selected_coverage']['request_rows_present'],3)
        self.assertEqual(group['adjacent_known_request_presented_intervals']['count'],2)
        self.assertEqual(group['adjacent_known_request_presented_intervals']['median_ms'],20)
        self.assertEqual(group['adjacent_pairs_crossing_unobserved_sequence_ids'],1)
        self.assertEqual(together['processes'][0]['missing_initial_sequence_ids'],40)
        output=subprocess.run([sys.executable,str(ROOT/'scripts/summarize_display.py'),str(self.path),'--include-rotated'],
                              check=True,capture_output=True,text=True)
        self.assertEqual(json.loads(output.stdout),together)

    def test_compact_hitch_stream_is_not_a_display_csv(self):
        self.path.write_text('schema_version,native_pid,sequence,layer_ptr,unix_ms,presented_s,interval_ms,dropped_events,dropped_requests\n')
        with self.assertRaises(ValueError): summarize(self.path,include_rotated=True)

    def test_out_of_order_callbacks_join_and_deduplicate_per_process_and_layer(self):
        # Sequence 2 belongs to a different layer: it is known, so does not
        # make layer abc's sequence 1 -> 3 interval uncertain.
        second = presented(3, 100.015, 100.020)
        self.write([
            second,
            event("gpu_complete", 1, gpu_state="valid", gpu_start_s=100.001,
                  gpu_end_s=100.003, callbacks_seen=2, command_status=4),
            event("request", 2, layer="def"),
            event("request", 3, request=100.015),
            presented(1, 100, 100.010), second,
            event("retired", 1, callbacks_seen=3),
            presented(1, 200, 200.020, pid=456),
        ])
        report = summarize(self.path)
        self.assertEqual(report["invalid_rows"], 0)
        self.assertEqual(report["first_valid_presented_host_s"], 100.010)
        self.assertEqual(len(report["groups"]), 3)
        group = report["groups"][0]
        self.assertEqual(group["native_pid"], 123)
        self.assertEqual(group["layer_ptr"], "0xabc")
        self.assertEqual(group["observed_presented_time_gaps"]["median_ms"], 10)
        self.assertEqual(group["adjacent_known_request_presented_intervals"]["count"], 1)
        self.assertEqual(group["request_to_present_latency"]["median_ms"], 7.5)
        self.assertEqual(group["presenting_command_buffer_gpu_duration"]["median_ms"], 2)
        counts = group["whole_group_coverage"]
        self.assertEqual(counts["request_records_recovered_without_request_row"], 1)
        self.assertEqual(counts["duplicate_event_rows"], 1)
        self.assertEqual(counts["valid_presented_timestamps"], 2)

    def test_missing_zero_unsupported_and_dropped_telemetry_do_not_bridge_known_pairs(self):
        self.write([
            presented(1, 100, 100.010),
            event("request", 2, request=100.02),
            event("retired", 2, request=100.02, callbacks_seen=1),
            event("presented", 3, request=100.03, presented_state="zero_or_unavailable", callbacks_seen=1),
            event("gpu_complete", 3, request=100.03, gpu_state="zero_or_unavailable",
                  callbacks_seen=3, command_status=5, error_code=-1),
            event("request", 4, request=100.04, presented_state="unsupported"),
            event("registration_failed", 4, request=100.04, presented_state="unsupported"),
            event("retired", 4, request=100.04),
            presented(5, 100.05, 100.060),
            presented(7, 100.07, 100.080, dropped_events=8, dropped_requests=2),
            event("summary", 0, request=0, dropped_events=9, dropped_requests=2, active_traces=1),
        ])
        report = summarize(self.path)
        group = report["groups"][0]
        self.assertEqual(group["observed_presented_time_gaps"]["count"], 2)
        self.assertEqual(group["adjacent_known_request_presented_intervals"]["count"], 0)
        self.assertEqual(group["adjacent_pairs_crossing_unobserved_sequence_ids"], 1)
        counts = group["selected_coverage"]
        self.assertEqual(counts["known_traces"], 6)
        self.assertEqual(counts["presented_zero_or_unavailable"], 1)
        self.assertEqual(counts["unsupported_presented_requests"], 1)
        self.assertEqual(counts["registration_failed"], 1)
        self.assertEqual(counts["presented_callback_seen_but_row_missing"], 1)
        self.assertEqual(counts["retired_without_presented_callback"], 1)
        self.assertEqual(counts["command_errors"], 1)
        proc = report["processes"][0]
        self.assertEqual(proc["dropped_events_highwater"], 9)
        self.assertEqual(proc["dropped_requests_highwater"], 2)
        self.assertEqual(proc["unobserved_sequence_ids_between_records"], 1)
        self.assertEqual(proc["last_row_active_traces"], 1)
        self.assertEqual(proc["summary_rows"], 1)

    def test_cli_window_uses_first_valid_presentation_and_keeps_full_coverage(self):
        self.write([
            presented(1, 99, 100),
            event("request", 2, request=101.5),
            presented(3, 101.9, 102),
            presented(4, 102.9, 103),
            presented(5, 103.9, 104),
        ])
        output = Path(self.temp.name) / "report.json"
        result = subprocess.run([sys.executable, str(ROOT / "scripts/summarize_display.py"),
                                 str(self.path), "--start-seconds", "1", "--end-seconds", "3",
                                 "--output", str(output)], check=True, capture_output=True, text=True)
        report = json.loads(output.read_text())
        self.assertEqual(json.loads(result.stdout), report)
        self.assertEqual(report["first_valid_presented_host_s"], 100)
        group = report["groups"][0]
        self.assertEqual(group["whole_group_coverage"]["known_traces"], 5)
        self.assertEqual(group["selected_coverage"]["known_traces"], 3)
        self.assertEqual(group["observed_presented_time_gaps"]["count"], 1)
        self.assertEqual(group["adjacent_known_request_presented_intervals"]["count"], 1)

    def test_malformed_and_conflicting_data_cannot_produce_plausible_timing(self):
        self.write([
            presented(1, 100, 100.1), presented(1, 100, 100.2),
            presented(2, 100, float("nan")), presented(3, 100, 0),
            event("request", 4, schema_version=2),
        ])
        with self.path.open("a") as stream:
            stream.write("1,presented,0,123\n")
        report = summarize(self.path)
        self.assertEqual(report["invalid_rows"], 4)
        self.assertIsNone(report["first_valid_presented_host_s"])
        group = report["groups"][0]
        self.assertEqual(group["selected_coverage"]["conflicting_presented_timestamps"], 1)
        self.assertEqual(group["observed_presented_time_gaps"]["count"], 0)
        self.assertIsNone(group["request_to_present_latency"]["median_ms"])
        with self.assertRaises(ValueError):
            summarize(self.path, start=1)
        for start, end in ((-1, None), (float("nan"), None), (1, 1), (0, float("inf"))):
            with self.subTest(start=start, end=end), self.assertRaises(ValueError):
                summarize(self.path, start, end)

    def test_presentation_order_reversals_are_sorted_but_not_counted_as_forward_cadence(self):
        self.write([
            presented(1, 100.09, 100.10),
            presented(2, 100.10, 100.08),
            presented(3, 100.07, 100.08),
        ])
        group = summarize(self.path)["groups"][0]
        self.assertEqual(group["observed_presented_time_gaps"]["count"], 1)
        self.assertEqual(group["observed_presented_time_gaps"]["median_ms"], 20)
        self.assertEqual(group["adjacent_known_request_presented_intervals"]["count"], 0)
        self.assertEqual(group["nonincreasing_presented_times_in_request_order"], 2)
        self.assertEqual(group["repeated_presented_timestamps"], 1)
        self.assertEqual(group["negative_request_to_present_latencies"], 1)
        self.assertEqual(group["request_to_present_latency"]["count"], 2)


if __name__ == "__main__":
    unittest.main()
