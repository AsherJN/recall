"""Join resource-operation traces with an existing process/display hitch report.

Supply only the matching Windows PID's resource-ops files. CPU call overlap is
evidence, not automatic causation. Aggregate batches are deliberately not
prorated: their calls can extend outside a hitch and can be nested.
"""
import argparse
import csv
import json
from pathlib import Path


def read_rows(paths):
    rows = []
    for path in paths:
        with path.open(newline='') as stream:
            for row in csv.DictReader(stream):
                if None in row or None in row.values() or row.get('schema_version') != '1':
                    raise ValueError(f'Incomplete or unsupported resource CSV: {path}')
                rows.append(dict(row, source_file=path.name))
    return rows


def intervals(rows, aggregate=False):
    result = []
    for row in rows:
        if aggregate:
            anchor_ns, anchor_us = int(row['snapshot_monotonic_ns']), int(row['snapshot_unix_us'])
            a, b = int(row['first_start_ns']), int(row['last_end_ns'])
            if not 0 < a <= b <= anchor_ns:
                raise ValueError('Invalid aggregate monotonic interval')
            end = anchor_us/1e6 - (anchor_ns-b)/1e9
            start = anchor_us/1e6 - (anchor_ns-a)/1e9
            detail = {k: int(row[k]) for k in ['calls', 'known_byte_calls', 'bytes', 'units', 'total_ns', 'max_ns']}
            detail['snapshot'] = int(row['snapshot'])
            detail['shard'] = int(row['shard'])
        else:
            if int(row['duration_ns']) < 0:
                raise ValueError('Negative resource duration')
            end = int(row['end_unix_us'])/1e6
            start = end-int(row['duration_ns'])/1e9
            detail = {k: int(row[k]) for k in ['sequence', 'resource_token', 'duration_ns', 'bytes_known', 'bytes', 'units', 'detail']}
        result.append(dict(start_utc_s=start, end_utc_s=end, operation=row['operation'],
                           thread_id=int(row['thread_id']), source_file=row['source_file'], **detail))
    return result


def overlap(a, b):
    return a['start_utc_s'] < b['end_utc_s'] and a['end_utc_s'] > b['start_utc_s']


def join(report, spans, batches):
    result = []
    for hitch in report['hitches']:
        direct = [s for s in spans if overlap(s, hitch)]
        # Presentation queues can delay visibility. Keep this context separate
        # from direct overlap; never widen intervals and call that proof.
        preceding = dict(start_utc_s=hitch['start_utc_s']-.1, end_utc_s=hitch['start_utc_s'])
        result.append(dict(**hitch,
            resource_spans_overlapping=sorted(direct, key=lambda s: s['duration_ns'], reverse=True),
            resource_spans_preceding_100ms=[s for s in spans if overlap(s, preceding) and not overlap(s, hitch)],
            resource_completion_batches=[b for b in batches if overlap(b, hitch)]))
    return dict(schema_version=1, native_pid=report.get('pid'),
        source_display=report.get('display'), hitches=result,
        retained_slow_spans=len(spans), retained_aggregate_batches=len(batches),
        interpretation='Temporal association, not automatic cause. Sparse spans are CPU call durations; '
        'nested spans and byte counts overlap. Aggregate completion batches include short calls and '
        'activity outside the hitch; never sum/prorate them as exclusive hitch time. No matching span '
        'does not exclude game/OS memory activity, missing telemetry, or an operation below 2 ms.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stalls', required=True, type=Path)
    parser.add_argument('--windows-pid', required=True, type=int)
    parser.add_argument('--folder', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    stem = f'resource-ops-{args.windows_pid}-'
    events = sorted(args.folder.glob(stem+'*.events*.csv'))
    totals = sorted(args.folder.glob(stem+'*.totals*.csv'))
    summaries = {p.name: json.loads(p.read_text()) for p in args.folder.glob(stem+'*.summary.json')}
    if not events or not totals:
        raise SystemExit('No matching resource trace; verify the Windows/native PID association first.')
    report = join(json.loads(args.stalls.read_text()), intervals(read_rows(events)), intervals(read_rows(totals), True))
    report.update(windows_pid=args.windows_pid, resource_summaries=summaries,
                  summary_available=bool(summaries), files=[p.name for p in events+totals])
    with args.output.open('x') as stream:
        json.dump(report, stream, indent=2, allow_nan=False); stream.write('\n')


if __name__ == '__main__':
    main()
