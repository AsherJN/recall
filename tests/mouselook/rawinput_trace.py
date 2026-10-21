#!/usr/bin/env python3
"""Summarise Wine's raw input trace from a play-test session started with --trace-rawinput.

How the game asked for the mouse (RegisterRawInputDevices: usage, flags, target window), how it reads it
(GetRawInputData, one message at a time, or GetRawInputBuffer, in batches), on which thread and how often,
and whether that thread is the one that receives Recall's mouse deliveries. The trace holds call parameters
only (handles, pointers, sizes), never what a key or button was.

  python3 tests/mouselook/rawinput_trace.py [session]   (default: the latest session)
"""
import argparse
import collections
import csv
import json
from pathlib import Path
import re
import statistics

ROOT = Path(__file__).resolve().parents[2]
LOGS = ROOT / 'logs/mouselook'
LINE = re.compile(r'^\s*(\d+)\.(\d{3}):([0-9a-f]+):([0-9a-f]+):(trace|warn|fixme|err):rawinput:(\w+) (.*)$')
DEVICE = re.compile(r'device (\d+): page (\S+), usage (\S+), flags (\S+), target (\S+)\.')
NULLS = {'0x0', '(nil)', '0', '0000000000000000', '00000000', 'NULL'}
RIDEV = [(0x1, 'REMOVE'), (0x10, 'EXCLUDE'), (0x20, 'PAGEONLY'), (0x100, 'INPUTSINK'), (0x200, 'CAPTUREMOUSE'),
         (0x400, 'APPKEYS'), (0x1000, 'EXINPUTSINK'), (0x2000, 'DEVNOTIFY')]
USAGES = {(1, 2): 'mouse', (1, 6): 'keyboard', (1, 4): 'joystick', (1, 5): 'gamepad'}


def number(text):
    return 0 if text in NULLS else int(text, 16) if text.lower().startswith('0x') else int(text, 16)


def flag_names(flags):
    names = []
    if flags & 0x30 == 0x30:
        names.append('NOLEGACY')
        flags &= ~0x30
    names += [name for bit, name in RIDEV if flags & bit]
    return names


def parse(log):
    """Raw input calls from a Wine log: (tick ms, pid, tid, class, function, message)."""
    calls = []
    with open(log, errors='replace') as f:
        for line in f:
            m = LINE.match(line)
            if m:
                sec, ms, pid, tid, cls, function, message = m.groups()
                calls.append((int(sec) * 1000 + int(ms), int(pid, 16), int(tid, 16), cls, function, message.strip()))
    return calls


def input_threads(session):
    """Windows thread IDs the driver's statistics name for Overwatch: the one that takes mouse deliveries
    (consumer_tid) and the one that re-centres the cursor (setpos_tid)."""
    found = {}
    for path in session.glob('input-*.jsonl'):
        with open(path) as f:
            for line in f:
                row = json.loads(line)
                if row.get('exe') != 'Overwatch.exe':
                    break
                for key in ('consumer_tid', 'setpos_tid'):
                    if row.get(key):
                        found.setdefault(key, collections.Counter())[row[key]] += 1
    return {key: counter.most_common(1)[0][0] for key, counter in found.items()}


def frames_per_second(session):
    """Presented frames a second, by Unix second, and the presenting thread."""
    counts, threads = collections.Counter(), collections.Counter()
    for path in session.glob('frames-*.csv'):
        if '.events' in path.name:
            continue
        with open(path, newline='') as f:
            for row in csv.DictReader(f):
                if 'unix_us' in row and row.get('present_tid'):
                    counts[int(row['unix_us']) // 1_000_000] += 1
                    threads[int(row['present_tid'])] += 1
    return counts, (threads.most_common(1)[0][0] if threads else None)


def summarise(session):
    session = Path(session)
    calls = parse(session / 'battlenet.log')
    threads = input_threads(session)
    fps, present_tid = frames_per_second(session)

    registrations, fixmes = [], []
    reads = collections.defaultdict(lambda: collections.Counter())
    seconds = collections.defaultdict(lambda: collections.Counter())
    for tick, pid, tid, cls, function, message in calls:
        if cls == 'fixme':
            fixmes.append({'pid': pid, 'tid': tid, 'message': message})
        if function == 'NtUserRegisterRawInputDevices':
            m = DEVICE.match(message)
            if m:
                index, page, usage, flags, target = m.groups()
                page, usage, flags = number(page), number(usage), number(flags)
                registrations.append({'tick_ms': tick, 'pid': pid, 'tid': tid, 'device': int(index),
                                      'usage': USAGES.get((page, usage), f'page {page:#x} usage {usage:#x}'),
                                      'flags': flags, 'flag_names': flag_names(flags),
                                      'target': None if target in NULLS else target})
        elif function in ('NtUserGetRawInputData', 'NtUserGetRawInputBuffer'):
            data = re.search(r'data (\S+?),', message)
            kind = 'size' if data and data.group(1) in NULLS else 'read'
            key = (function.replace('NtUser', ''), kind)
            reads[(pid, tid)][key] += 1
            if kind == 'read':
                seconds[(pid, tid)][tick // 1000] += 1

    consumer = threads.get('consumer_tid')
    game_pid = next((pid for pid, tid in reads if tid == consumer), None)
    if game_pid is None and reads:
        game_pid = max(reads, key=lambda k: sum(reads[k].values()))[0]

    def label(tid):
        names = []
        if tid == consumer:
            names.append('window thread: takes Recall\'s mouse deliveries')
        if tid == threads.get('setpos_tid') and tid != consumer:
            names.append('re-centres the cursor')
        if tid == present_tid:
            names.append('render thread: presents frames')
        return '; '.join(names) or 'another thread'

    readers = []
    for (pid, tid), counter in sorted(reads.items(), key=lambda item: -sum(item[1].values())):
        per_second = list(seconds[(pid, tid)].values())
        readers.append({'pid': pid, 'tid': tid, 'game': pid == game_pid, 'role': label(tid) if pid == game_pid else '',
                        'calls': {f'{function} {kind}': n for (function, kind), n in sorted(counter.items())},
                        'active_seconds': len(per_second),
                        'reads_per_second_median': statistics.median(per_second) if per_second else 0})
    median_fps = statistics.median(fps.values()) if fps else None
    summary = {'schema': 1, 'session': session.name, 'trace_lines': len(calls), 'threads': threads,
               'present_tid': present_tid, 'median_fps': median_fps,
               'registrations': [r for r in registrations if game_pid is None or r['pid'] == game_pid],
               'other_registrations': [r for r in registrations if game_pid is not None and r['pid'] != game_pid],
               'fixmes': fixmes[:20], 'readers': readers}
    summary['verdict'] = verdict(summary)
    (session / 'rawinput-trace.json').write_text(json.dumps(summary, indent=2, sort_keys=True))
    return summary


def verdict(s):
    lines = []
    if not s['trace_lines']:
        return ['No raw input trace in battlenet.log: start the session with --trace-rawinput.']
    for r in s['registrations']:
        if r['usage'] in ('mouse', 'keyboard'):
            lines.append(f"Overwatch registered the {r['usage']} for raw input (flags {r['flags']:#x}"
                         f"{': ' + ', '.join(r['flag_names']) if r['flag_names'] else ''}; target window "
                         f"{r['target'] or 'none, so input follows the focused window'}).")
    game = [r for r in s['readers'] if r['game']]
    if not game:
        lines.append('No raw input reads were traced.')
        return lines
    for r in game[:3]:
        calls = ', '.join(f'{n:,} {name}' for name, n in r['calls'].items())
        rate = r['reads_per_second_median']
        per_frame = f", about {rate / s['median_fps']:.1f} per frame" if s['median_fps'] and rate else ''
        lines.append(f"Thread {r['tid']} ({r['role']}): {calls}; {rate:,.0f} reads a second{per_frame}.")
    main = game[0]
    consumer = s['threads'].get('consumer_tid')
    batched = any(name.startswith('GetRawInputBuffer read') for name in main['calls'])
    if consumer and main['tid'] == consumer:
        lines.append('Overwatch reads raw input on the thread that also pumps its window messages, where Recall '
                     'hands motion over' + (', in batches (GetRawInputBuffer).' if batched else
                                            ', one message at a time (GetRawInputData).'))
    elif consumer:
        lines.append('Overwatch reads raw input on a thread other than the one that receives Recall\'s deliveries: '
                     'motion reaches it only when the window thread next pumps its messages.')
    if s['fixmes']:
        lines.append(f"Wine noted {len(s['fixmes'])} unsupported raw input request(s), e.g. \"{s['fixmes'][0]['message']}\".")
    return lines


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('session', nargs='?')
    args = parser.parse_args()
    session = Path(args.session) if args.session else max((p for p in LOGS.iterdir() if p.is_dir() and
                                                             (p / 'battlenet.log').exists()), key=lambda p: p.name)
    print('\n'.join(summarise(session)['verdict']))
    print(f'\nFull summary: {session / "rawinput-trace.json"}')


if __name__ == '__main__':
    main()
