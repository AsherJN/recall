#!/usr/bin/env python3
"""Summarize native Metal display callbacks without treating telemetry gaps as dropped frames."""
import argparse
from collections import Counter, defaultdict
import csv
from dataclasses import dataclass, field
import json
import math
from pathlib import Path
import statistics

from summarize_frames import percentile, csv_parts

EVENTS = {"request", "presented", "gpu_complete", "retired", "registration_failed", "summary"}
STATES = {"pending", "valid", "zero_or_unavailable", "unsupported"}
REQUIRED = {"schema_version", "event", "native_pid", "sequence", "layer_ptr", "request_host_s",
            "event_host_s", "minimum_duration_s", "presented_s", "presented_state", "gpu_start_s",
            "gpu_end_s", "gpu_state", "command_status", "error_code", "callbacks_seen",
            "dropped_events", "dropped_requests", "active_traces"}


def distribution(seconds):
    values = [value * 1000 for value in seconds]
    if not values:
        return {"count": 0, "median_ms": None, "p95_ms": None, "p99_ms": None, "max_ms": None}
    return dict(count=len(values), median_ms=round(statistics.median(values), 4),
                p95_ms=round(percentile(values, .95), 4),
                p99_ms=round(percentile(values, .99), 4), max_ms=round(max(values), 4))


@dataclass
class Trace:
    sequence: int
    events: Counter = field(default_factory=Counter)
    requests: set = field(default_factory=set)
    presented: set = field(default_factory=set)
    gpu_ranges: set = field(default_factory=set)
    states: set = field(default_factory=set)
    minimum_durations: set = field(default_factory=set)
    callbacks_seen: int = 0
    gpu_zero: bool = False
    command_error: bool = False

    def request_time(self):
        return next(iter(self.requests)) if len(self.requests) == 1 else None

    def presented_time(self):
        return next(iter(self.presented)) if len(self.presented) == 1 else None

    def add(self, row):
        event = row["event"]
        self.events[event] += 1
        self.callbacks_seen |= row["callbacks_seen"]
        if row["request_host_s"] > 0:
            self.requests.add(row["request_host_s"])
        self.minimum_durations.add(row["minimum_duration_s"])
        if event in {"request", "presented", "registration_failed"}:
            self.states.add(row["presented_state"])
        if event == "presented" and row["presented_state"] == "valid" and row["presented_s"] > 0:
            self.presented.add(row["presented_s"])
        if event == "gpu_complete":
            if row["gpu_state"] == "valid" and row["gpu_start_s"] > 0 and row["gpu_end_s"] >= row["gpu_start_s"]:
                self.gpu_ranges.add((row["gpu_start_s"], row["gpu_end_s"]))
            else:
                self.gpu_zero = True
            self.command_error |= row["command_status"] == 5 or row["error_code"] != 0


def parse_row(raw):
    row = {key: raw[key] for key in REQUIRED}
    if row["schema_version"] != "1" or row["event"] not in EVENTS:
        raise ValueError("Unsupported schema or event")
    if row["presented_state"] not in STATES or row["gpu_state"] not in STATES:
        raise ValueError("Unknown timestamp state")
    for key in ("native_pid", "sequence", "command_status", "callbacks_seen",
                "dropped_events", "dropped_requests", "active_traces"):
        row[key] = int(row[key])
        if row[key] < 0:
            raise ValueError("Negative unsigned counter")
    if not row["native_pid"] or (row["event"] != "summary" and not row["sequence"]):
        raise ValueError("Missing process/trace identity")
    row["layer_ptr"] = int(row["layer_ptr"], 16)
    if row["layer_ptr"] < 0:
        raise ValueError("Invalid layer identity")
    row["error_code"] = int(row["error_code"])
    for key in ("request_host_s", "event_host_s", "minimum_duration_s", "presented_s", "gpu_start_s", "gpu_end_s"):
        row[key] = float(row[key])
        if not math.isfinite(row[key]) or row[key] < 0:
            raise ValueError("Invalid timestamp/duration")
    if row["event"] == "presented" and row["presented_state"] == "valid" and row["presented_s"] <= 0:
        raise ValueError("Valid presentation requires a positive timestamp")
    if row["event"] == "gpu_complete" and row["gpu_state"] == "valid":
        if row["gpu_start_s"] <= 0 or row["gpu_end_s"] < row["gpu_start_s"]:
            raise ValueError("Invalid GPU range")
    return row


def coverage(traces):
    return dict(
        known_traces=len(traces), request_rows_present=sum(bool(t.events["request"]) for t in traces),
        request_records_recovered_without_request_row=sum(not t.events["request"] for t in traces),
        valid_presented_timestamps=sum(t.presented_time() is not None for t in traces),
        presented_zero_or_unavailable=sum("zero_or_unavailable" in t.states for t in traces),
        unsupported_presented_requests=sum("unsupported" in t.states for t in traces),
        missing_presented_rows=sum(not t.events["presented"] for t in traces),
        presented_callback_seen_but_row_missing=sum(bool(t.callbacks_seen & 1) and not t.events["presented"] for t in traces),
        registration_failed=sum(bool(t.events["registration_failed"]) for t in traces),
        retired=sum(bool(t.events["retired"]) for t in traces),
        missing_retired_rows=sum(not t.events["retired"] for t in traces),
        retired_without_presented_callback=sum(bool(t.events["retired"]) and not (t.callbacks_seen & 1) for t in traces),
        missing_gpu_complete_rows=sum(not t.events["gpu_complete"] for t in traces),
        valid_present_command_buffer_gpu_ranges=sum(len(t.gpu_ranges) == 1 for t in traces),
        gpu_zero_or_unavailable=sum(t.gpu_zero for t in traces),
        command_errors=sum(t.command_error for t in traces),
        duplicate_event_rows=sum(sum(max(0, n - 1) for n in t.events.values()) for t in traces),
        conflicting_presented_timestamps=sum(len(t.presented) > 1 for t in traces),
        conflicting_request_timestamps=sum(len(t.requests) > 1 for t in traces),
        conflicting_gpu_ranges=sum(len(t.gpu_ranges) > 1 for t in traces),
    )


def summarize(path, start=0.0, end=None, include_rotated=False):
    if not math.isfinite(start) or start < 0 or (end is not None and (not math.isfinite(end) or end <= start)):
        raise ValueError("Use a finite nonnegative start and a finite end later than the start.")
    parts = csv_parts(path, include_rotated)
    oldest_event_host_s = None
    groups = defaultdict(dict)
    processes = {}
    invalid_rows = 0
    for part in parts:
        with part.open(newline="") as stream:
            reader = csv.DictReader(stream)
            if not REQUIRED.issubset(reader.fieldnames or []):
                raise ValueError("Not a native DXMT display log schema 1")
            for raw in reader:
                try:
                    row = parse_row(raw)
                except (KeyError, ValueError, TypeError):
                    invalid_rows += 1
                    continue
                if row["event_host_s"] > 0:
                    oldest_event_host_s = row["event_host_s"] if oldest_event_host_s is None else min(oldest_event_host_s, row["event_host_s"])
                pid = row["native_pid"]
                proc = processes.setdefault(pid, dict(native_pid=pid, dropped_events_highwater=0,
                                                       dropped_requests_highwater=0, summary_rows=0,
                                                       last_row_active_traces=0, sequences=set()))
                proc["dropped_events_highwater"] = max(proc["dropped_events_highwater"], row["dropped_events"])
                proc["dropped_requests_highwater"] = max(proc["dropped_requests_highwater"], row["dropped_requests"])
                proc["last_row_active_traces"] = row["active_traces"]
                if row["event"] == "summary":
                    proc["summary_rows"] += 1
                    continue
                proc["sequences"].add(row["sequence"])
                traces = groups[(pid, row["layer_ptr"])]
                trace = traces.setdefault(row["sequence"], Trace(row["sequence"]))
                trace.add(row)

    times = [t.presented_time() for traces in groups.values() for t in traces.values()
             if t.presented_time() is not None]
    origin = min(times) if times else None
    filtered = start != 0 or end is not None
    if filtered and origin is None:
        raise ValueError("Cannot select time offsets without a valid presented timestamp.")

    def selected(trace):
        if not filtered:
            return True
        timestamp = trace.presented_time()
        if timestamp is None:
            timestamp = trace.request_time()
        if timestamp is None:
            return False
        offset = timestamp - origin
        return offset >= start and (end is None or offset <= end)

    results = []
    for (pid, layer), traces in sorted(groups.items()):
        ordered = [traces[key] for key in sorted(traces)]
        chosen = [t for t in ordered if selected(t)]
        presented = sorted(t.presented_time() for t in chosen if t.presented_time() is not None)
        gaps = [b - a for a, b in zip(presented, presented[1:]) if b > a]
        adjacent, reversed_pairs, missing_pairs = [], 0, 0
        process_sequences = sorted(processes[pid]["sequences"])
        positions = {seq: i for i, seq in enumerate(process_sequences)}
        for left, right in zip(ordered, ordered[1:]):
            if not selected(left) or not selected(right):
                continue
            a, b = left.presented_time(), right.presented_time()
            if a is None or b is None or left.request_time() is None or right.request_time() is None:
                continue
            # Sequence IDs are process-wide; other known layers may interleave.
            # Exclude pairs crossing an entirely unobserved sequence identity.
            if right.sequence - left.sequence != positions[right.sequence] - positions[left.sequence]:
                missing_pairs += 1
            elif b > a:
                adjacent.append(b - a)
            else:
                reversed_pairs += 1
        latencies, negative_latency = [], 0
        for trace in chosen:
            requested, shown = trace.request_time(), trace.presented_time()
            if requested is not None and shown is not None:
                if shown >= requested:
                    latencies.append(shown - requested)
                else:
                    negative_latency += 1
        gpu = [end_s - start_s for t in chosen if len(t.gpu_ranges) == 1
               for start_s, end_s in t.gpu_ranges]
        results.append(dict(
            native_pid=pid, layer_ptr=hex(layer), layer_identity_known=layer != 0,
            whole_group_coverage=coverage(ordered), selected_coverage=coverage(chosen),
            selected_first_presented_host_s=presented[0] if presented else None,
            selected_last_presented_host_s=presented[-1] if presented else None,
            observed_presented_time_gaps=distribution(gaps),
            adjacent_known_request_presented_intervals=distribution(adjacent),
            adjacent_pairs_crossing_unobserved_sequence_ids=missing_pairs,
            nonincreasing_presented_times_in_request_order=reversed_pairs,
            repeated_presented_timestamps=len(presented) - len(set(presented)),
            request_to_present_latency=distribution(latencies), negative_request_to_present_latencies=negative_latency,
            presenting_command_buffer_gpu_duration=distribution(gpu),
            requested_minimum_durations_ms=sorted({round(v * 1000, 6) for t in chosen for v in t.minimum_durations}),
        ))
    process_results = []
    for pid, proc in sorted(processes.items()):
        proc = dict(proc)
        sequences = sorted(proc.pop("sequences"))
        proc["missing_initial_sequence_ids"] = sequences[0] - 1 if sequences else 0
        proc["unobserved_sequence_ids_between_records"] = sum(b - a - 1 for a, b in zip(sequences, sequences[1:]))
        process_results.append(proc)
    return dict(
        file=str(path), files=[str(part) for part in parts], schema_version=1, invalid_rows=invalid_rows,
        include_rotated=include_rotated, oldest_retained_event_host_s=oldest_event_host_s,
        capture_scope="Oldest retained segment through current segment; not the entire process lifetime." if include_rotated else "Single file only.",
        first_valid_presented_host_s=origin, selected_start_seconds=start, selected_end_seconds=end,
        selection="Offsets use the retained inputs' first valid presented timestamp; traces lacking one use request time. Coverage outside the selection remains separate.",
        interpretation=[
            "Presented-time gaps describe observed positive Metal presentation timestamps, not input latency or physical pixel response.",
            "Missing callbacks, zero/unavailable times, sequence gaps and dropped telemetry are not classified as skipped frames or stutter.",
            "Adjacent-known-request intervals require valid timings and no missing sequence IDs between them; dropped unnumbered requests can still hide intervening presentations.",
            "Drop counters are process-wide high-water marks, not per-layer or per-selected-window counts. A missing summary or live traces can mean an incomplete capture.",
            "Retirement coverage counts records, not proven object lifetime. Logger caps or process exit can truncate capture even when recorded drop counters are zero.",
            "Request-to-present latency starts at DXMT's Metal presentation request, after earlier game/encoding work; it is not input-to-screen latency.",
            "GPU duration covers only the command buffer presenting this drawable, not all work in the game's frame.",
        ], processes=process_results, groups=results,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    parser.add_argument("--start-seconds", type=float, default=0)
    parser.add_argument("--end-seconds", type=float)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--include-rotated", action="store_true", help="Join matching .2.csv, .1.csv and current .csv before tracing callbacks.")
    args = parser.parse_args()
    try:
        report = summarize(args.path, args.start_seconds, args.end_seconds, include_rotated=args.include_rotated)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    output = json.dumps(report, indent=2, allow_nan=False) + "\n"
    if args.output:
        args.output.write_text(output)
    print(output, end="")


if __name__ == "__main__":
    main()
