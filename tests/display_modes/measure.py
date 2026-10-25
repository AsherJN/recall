#!/usr/bin/env python3
"""FPS and frame-to-screen time for the labelled windows of a live session (game.py).

  measure.py <session>   Reads <session>/windows.jsonl ({"label", "start_ms", "end_ms"}), DXMT's frame
                         log (frames-*.csv, unique by time) and display log (display-*.csv).
FPS is frames per second of wall time; frame-to-screen is presentedTime minus the request time
(winemetal's display log), the same proxy as summarize_display.py.
"""
import csv
import json
from pathlib import Path
import re
import sys


def pct(values, share):
    values = sorted(values)
    return values[min(len(values) - 1, int(share * (len(values) - 1)))] if values else 0.0


def load(session):
    frames = {}
    for path in list(session.glob('frames-*.csv')) + list(session.glob('kept/frames-*.csv')):
        if re.search(r'events|summary', path.name):
            continue
        for row in csv.DictReader(path.open()):
            try:
                frames[int(row['unix_us'])] = int(row['present_interval_us']) / 1000
            except (KeyError, ValueError):
                pass
    shown = {}
    for path in session.glob('display-*.csv'):
        if not re.fullmatch(r'display-\d+(\.\d+)?\.csv', path.name):
            continue
        for row in csv.DictReader(path.open()):
            shown.setdefault((row['native_pid'], row['sequence']), {})[row['event']] = row
    return frames, shown


def measure(session):
    frames, shown = load(session)
    results = []
    for line in (session / 'windows.jsonl').read_text().splitlines():
        window = json.loads(line)
        a, b = window['start_ms'], window['end_ms']
        intervals = [v for t, v in frames.items() if a <= t / 1000 <= b]
        latency = []
        for events in shown.values():
            p, q = events.get('presented'), events.get('request')
            if not p or not q or p['presented_state'] != 'valid' or not a <= float(p['unix_ms']) <= b:
                continue
            if float(p['presented_s']) > 0:
                latency.append((float(p['presented_s']) - float(q['request_host_s'])) * 1000)
        results.append(dict(label=window['label'], frames=len(intervals),
                            fps=round(len(intervals) / ((b - a) / 1000), 1),
                            frame_p50_ms=round(pct(intervals, .5), 2), frame_p99_ms=round(pct(intervals, .99), 2),
                            to_screen_p50_ms=round(pct(latency, .5), 2), to_screen_p90_ms=round(pct(latency, .9), 2),
                            shown=len(latency)))
    return results


if __name__ == '__main__':
    for row in measure(Path(sys.argv[1])):
        print(json.dumps(row))
