"""Join bounded process counters with one game's actual display hitches.

Counter deltas are evidence of overlapping activity, never automatic cause labels.
Run after exit. Pass every retained process/display part for the same session.
"""
import argparse
import csv
import datetime
import json
from pathlib import Path
import statistics

COUNTERS = ['user_ns', 'system_ns', 'runnable_ns', 'faults_u32', 'cow_faults_u32',
            'context_switches_u32', 'mach_calls_u32', 'unix_calls_u32', 'pageins',
            'disk_read_bytes', 'disk_write_bytes', 'vm_compressions', 'vm_decompressions',
            'vm_swapins', 'vm_swapouts', 'cpu_user_ticks_u32', 'cpu_system_ticks_u32',
            'cpu_idle_ticks_u32', 'cpu_nice_ticks_u32']


def process_bins(rows, pid):
    rows = sorted((r for r in rows if int(r['pid']) == pid), key=lambda r: int(r['monotonic_ns']))
    bins, rejects = [], {}
    def reject(reason):
        rejects[reason] = rejects.get(reason, 0) + 1
    for left, right in zip(rows, rows[1:]):
        if int(left['error']) or int(right['error']):
            reject('query_error'); continue
        if left['start_abstime'] != right['start_abstime']:
            reject('changed_process_identity'); continue
        a, b = int(left['monotonic_ns']), int(right['monotonic_ns'])
        seconds = (b - a) / 1e9
        if not 0 < seconds <= .5:
            reject('duplicate_or_sampling_gap'); continue
        wall_a, wall_b = int(left['unix_us']) / 1e6, int(right['unix_us']) / 1e6
        if abs(wall_b - wall_a - seconds) > .02:
            reject('wall_clock_discontinuity'); continue
        if max(int(left['query_duration_ns']), int(right['query_duration_ns'])) > 20_000_000:
            reject('slow_counter_query'); continue
        if any(int(r[k]) for r in (left, right) for k in ('vm_error', 'cpu_error', 'task_counter_saturated')):
            reject('unavailable_or_saturated_counter'); continue
        deltas = {k: int(right[k]) - int(left[k]) for k in COUNTERS}
        # Negative counters are unknown, including wraps; never fabricate activity.
        if any(v < 0 for v in deltas.values()):
            reject('counter_decreased'); continue
        cpu_ns = deltas['user_ns'] + deltas['system_ns']
        host_ticks = sum(deltas[k] for k in COUNTERS if k.startswith('cpu_'))
        bins.append(dict(start_utc_s=wall_a, end_utc_s=wall_b, seconds=seconds,
                         game_cpu_percent=cpu_ns / (b - a) * 100,
                         runnable_minus_cpu_ms=(deltas['runnable_ns'] - cpu_ns) / 1e6,
                         host_busy_percent=(1 - deltas['cpu_idle_ticks_u32'] / host_ticks) * 100
                            if host_ticks else None,
                         footprint_mib=int(right['footprint_bytes']) / 2**20,
                         resident_mib=int(right['resident_bytes']) / 2**20,
                         vm_page_bytes=int(right['vm_page_bytes']), delta=deltas))
    return bins, rejects


def display_hitches(rows, pid, minimum_ms=50):
    rows = [r for r in rows if int(r['native_pid']) == pid]
    offsets = [float(r['unix_ms']) / 1000 - float(r['event_host_s'])
               for r in rows if r['event'] == 'presented' and float(r['event_host_s']) > 0]
    if not offsets:
        return [], dict(reason='no_presentation_clock')
    clock = statistics.median(offsets)
    spread = max(offsets) - min(offsets)
    shown = {int(r['sequence']): r for r in rows if r['event'] == 'presented'
             and r['presented_state'] == 'valid' and float(r['presented_s']) > 0}
    hitches, pairs = [], 0
    for sequence, row in sorted(shown.items()):
        previous = shown.get(sequence - 1)
        if not previous or previous['layer_ptr'] != row['layer_ptr']:
            continue
        duration = float(row['presented_s']) - float(previous['presented_s'])
        if duration <= 0:
            continue
        # Pair each native presentation with its own UTC anchor. A wall-clock
        # adjustment must not fabricate a frame interval or shift later joins.
        end = float(row['unix_ms'])/1000 + float(row['presented_s'])-float(row['event_host_s'])
        start = end-duration
        step = abs((float(row['unix_ms'])-float(previous['unix_ms']))/1000
                   - (float(row['event_host_s'])-float(previous['event_host_s']))) > .02
        pairs += 1
        if duration * 1000 > minimum_ms:
            hitches.append(dict(sequence=sequence, start_utc_s=start, end_utc_s=end,
                                duration_ms=duration * 1000, clock_step_overlap=step))
    return hitches, dict(valid_presentations=len(shown), consecutive_pairs=pairs,
                         clock_offset_s=clock, offset_spread_ms=spread * 1000,
                         timestamp_method='per-presentation paired host/UTC anchor; durations use host deltas')


def correlate(bins, hitches, runtime):
    joined = []
    for hitch in hitches:
        start, end = hitch['start_utc_s'], hitch['end_utc_s']
        # A backwards clock adjustment can make UTC bins non-monotonic. Do not
        # bisect them, or attribute the ambiguous pair crossing the adjustment.
        stable = not hitch.get('clock_step_overlap', False)
        selected = [b for b in bins if stable and b['start_utc_s'] < end and b['end_utc_s'] > start]
        overlap = sum(max(0, min(b['end_utc_s'], end) - max(b['start_utc_s'], start)) for b in selected)
        pipelines = [r for r in runtime if stable and r.get('event') == 'runtime' and r.get('result') == 'created'
                     and r['start_unix_us'] / 1e6 < end and r['end_unix_us'] / 1e6 > start]
        joined.append(dict(**hitch, end_utc=datetime.datetime.fromtimestamp(end, datetime.timezone.utc).isoformat(),
                           counter_coverage_fraction=min(1, overlap / (end - start)), bins=selected,
                           overlapping_pipeline_creates=[{k: r.get(k) for k in
                               ('key', 'cost_us', 'known_at_launch', 'archive_result')} for r in pipelines]))
    return joined


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', required=True, type=int)
    parser.add_argument('--process', nargs='+', type=Path, required=True)
    parser.add_argument('--display', nargs='+', type=Path, required=True)
    parser.add_argument('--pipeline', nargs='*', type=Path, default=[])
    parser.add_argument('--start', help='Inclusive UTC ISO timestamp; omit for all retained data')
    parser.add_argument('--end', help='Exclusive UTC ISO timestamp')
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    def read(paths):
        rows = []
        for path in paths:
            with path.open(newline='') as stream:
                rows.extend(csv.DictReader(stream))
        return rows
    bins, rejects = process_bins(read(args.process), args.pid)
    hitches, display = display_hitches(read(args.display), args.pid)
    lower = datetime.datetime.fromisoformat(args.start).timestamp() if args.start else float('-inf')
    upper = datetime.datetime.fromisoformat(args.end).timestamp() if args.end else float('inf')
    hitches = [h for h in hitches if lower <= h['start_utc_s'] and h['end_utc_s'] < upper]
    runtime = []
    for path in args.pipeline:
        with path.open() as stream:
            runtime.extend(json.loads(line) for line in stream if line.strip())
    result = dict(schema_version=1, pid=args.pid, counter_bins=len(bins), rejected_intervals=rejects,
                  display=display, hitches=correlate(bins, hitches, runtime),
                  interpretation='Temporal association only. Each bin includes its full measured counter deltas, '
                  'including activity just outside the hitch. Faults are not disk reads; compressor counters are '
                  'system-wide and may revisit pages. Runnable-minus-CPU is an aggregate across threads, '
                  'not a measurement of the game main thread being blocked.')
    with args.output.open('x') as stream:
        json.dump(result, stream, indent=2, allow_nan=False)
        stream.write('\n')


if __name__ == '__main__':
    main()
