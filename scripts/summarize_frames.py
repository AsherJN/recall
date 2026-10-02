#!/usr/bin/env python3
"""Summarize DXMT present-loop intervals, never physical-display frame timing."""
import argparse
import csv
import json
import math
from pathlib import Path
import statistics


def percentile(values, fraction):
    values = sorted(values)
    position = (len(values) - 1) * fraction
    lower, upper = math.floor(position), math.ceil(position)
    return values[lower] + (values[upper] - values[lower]) * (position - lower)


def csv_parts(path, include_rotated=False):
    """Exact sibling names only; never glob another PID or a diagnostic stream."""
    path = Path(path)
    if not include_rotated:
        return [path]
    if path.suffix != ".csv" or path.stem.endswith((".1", ".2")):
        raise ValueError("Pass the current .csv filename when including rotated segments.")
    parts = [path.with_suffix(".2.csv"), path.with_suffix(".1.csv"), path]
    existing = [part for part in parts if part.is_file()]
    if not existing:
        raise FileNotFoundError(path)
    return existing


def summarize(path, start=0.0, end=None, include_rotated=False):
    parts = csv_parts(path, include_rotated)
    version = None
    duplicate_rows = 0
    seen = set()
    elapsed = 0.0
    first_monotonic = None
    first_unix_us = last_unix_us = None
    max_dropped_events = 0
    selected, compile_starts = [], 0
    skipped = 0
    for part in parts:
        with part.open(newline="") as stream:
            reader = csv.DictReader(stream)
            part_version = 3 if "monotonic_us" in (reader.fieldnames or []) else 2 if "present_interval_us" in (reader.fieldnames or []) else 1
            if version is not None and part_version != version:
                raise ValueError("Rotated segments contain inconsistent frame schemas")
            version = part_version
            interval_key = "present_interval_us" if version >= 2 else "dt_us"
            counter_key = "shader_compile_starts" if version >= 2 else "compiles"
            if interval_key not in (reader.fieldnames or []):
                raise ValueError("Not a recognized DXMT frame log")
            for row in reader:
                try:
                    interval = int(row[interval_key]) / 1000
                    count = int(row[counter_key])
                    if interval < 0 or count < 0:
                        raise ValueError("negative counter")
                except (ValueError, TypeError, KeyError):
                    skipped += 1
                    continue
                if version == 3:
                    try:
                        monotonic = int(row["monotonic_us"])
                        unix_us = int(row["unix_us"])
                        max_dropped_events = max(max_dropped_events, int(row["dropped_events"]))
                    except (ValueError, TypeError, KeyError):
                        skipped += 1
                        continue
                    if include_rotated:
                        identity = (row.get("queue_id"), row.get("present_boundary"), row.get("event_id"), monotonic)
                        if identity in seen:
                            duplicate_rows += 1
                            continue
                        seen.add(identity)
                    if first_monotonic is None:
                        first_monotonic = monotonic - int(interval * 1000)
                        first_unix_us = unix_us - int(interval * 1000)
                    elapsed = (monotonic - first_monotonic) / 1_000_000
                    last_unix_us = unix_us
                else:
                    elapsed += interval / 1000
                if elapsed >= start and (end is None or elapsed <= end):
                    selected.append(interval)
                    compile_starts += count
    if not selected:
        raise ValueError("No valid intervals in the selected time window")
    return dict(
        file=str(path), files=[str(part) for part in parts], schema_version=version,
        include_rotated=include_rotated, duplicate_rows=duplicate_rows,
        capture_scope="Oldest retained segment through current segment; not the entire process lifetime." if include_rotated else "Single file only.",
        oldest_retained_monotonic_us=first_monotonic,
        interpretation="Present-loop intervals; not physical display timing or input latency. Unmarked data may include menus/loading.",
        legacy_warning="Ignore legacy asynchronous stage columns and per-row stage attribution." if version == 1 else None,
        selected_start_seconds=start, selected_end_seconds=end, intervals=len(selected),
        skipped_rows=skipped, total_logged_seconds=round(elapsed, 3),
        first_unix_us=first_unix_us, last_unix_us=last_unix_us,
        max_reported_dropped_events=max_dropped_events,
        segment_warning=("Only the retained rotation window is available; timestamps preserve gaps between recorded rows." if include_rotated else "Rotated segment only; use timestamps and sibling segments for full coverage.") if version == 3 else None,
        median_ms=round(statistics.median(selected), 3),
        p95_ms=round(percentile(selected, .95), 3), p99_ms=round(percentile(selected, .99), 3),
        over_33_3ms=sum(x > 1000 / 30 for x in selected),
        over_50ms=sum(x > 50 for x in selected), over_100ms=sum(x > 100 for x in selected),
        shader_compile_starts=compile_starts,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path)
    parser.add_argument("--start-seconds", type=float, default=0)
    parser.add_argument("--end-seconds", type=float)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--include-rotated", action="store_true", help="Read matching .2.csv, .1.csv and current .csv in order.")
    args = parser.parse_args()
    if args.start_seconds < 0 or (args.end_seconds is not None and args.end_seconds <= args.start_seconds):
        parser.error("Use a nonnegative start and an end later than the start.")
    report = json.dumps(summarize(args.path, args.start_seconds, args.end_seconds, include_rotated=args.include_rotated), indent=2) + "\n"
    if args.output:
        args.output.write_text(report)
    print(report, end="")


if __name__ == "__main__":
    main()
