#!/usr/bin/env python3
"""Mouse timing check: report rate, click timing and raw input after Command-Tab.

Builds timing_check.m into a small app and opens it. Step 1 (30 s): the player swipes and clicks with the pointer
frozen as in game. Step 2: Command-Tab away and back three times. Prints the result and keeps summary.json,
events.csv and marks.csv in the output folder. Installs nothing and changes no setting.

  --out DIR      where to keep the recording (default: logs/mouselook/timing-check-<stamp>)
  --sens N       Overwatch sensitivity, to express motion in degrees (asked for if not given)
  --analyse DIR  analyse an existing recording only
  --selftest     list the mice GCMouse sees, with no window
  --synthetic    analyse generated events with known answers
"""
import argparse
import csv
import json
import math
import os
from pathlib import Path
import plistlib
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).resolve().with_name('timing_check.m')
APP = ROOT / 'runtime/build/mouse-timing-check/Mouse Timing Check.app'
EXECUTABLE = APP / 'Contents/MacOS/MouseTimingCheck'
LOGS = ROOT / 'logs/mouselook'
DEVELOPER_DIR = '/Library/Developer/CommandLineTools'
INFO = {'CFBundleExecutable': EXECUTABLE.name, 'CFBundleIdentifier': 'local.overwatch2mac.mouse-timing-check',
        'CFBundleName': 'Mouse Timing Check', 'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1',
        'LSMinimumSystemVersion': '26.0', 'NSHighResolutionCapable': True, 'NSPrincipalClass': 'NSApplication'}
OW_DEGREES_PER_COUNT = 0.0066  # Overwatch yaw per mouse count at sensitivity 1
STANDARD_RATES = (125, 250, 500, 1000, 2000, 4000, 8000)
PHASE_CLICKS, PHASE_SWITCH = 1, 2


def build():
    newest = max(SOURCE.stat().st_mtime, Path(__file__).stat().st_mtime)
    if EXECUTABLE.exists() and EXECUTABLE.stat().st_mtime >= newest:
        return
    EXECUTABLE.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([DEVELOPER_DIR + '/usr/bin/clang', '-fobjc-arc', '-O2', '-Wall', '-Wextra', '-Wno-unused-parameter',
                    '-isysroot', DEVELOPER_DIR + '/SDKs/MacOSX.sdk', '-mmacosx-version-min=26.0',
                    '-framework', 'AppKit', '-framework', 'GameController', '-o', str(EXECUTABLE), str(SOURCE)],
                   check=True, env={**os.environ, 'DEVELOPER_DIR': DEVELOPER_DIR})
    (APP / 'Contents/Info.plist').write_bytes(plistlib.dumps(INFO))
    subprocess.run(['codesign', '--force', '--sign', '-', str(APP)], check=True, capture_output=True)


# ---- Analysis ----

def quantile(values, q):
    values = sorted(values)
    return values[min(len(values) - 1, int(q * len(values)))] if values else None


def summary_stats(values, digits=2):
    if not values:
        return None
    return {'n': len(values), 'mean': round(statistics.fmean(values), digits),
            'median': round(quantile(values, 0.5), digits), 'p90': round(quantile(values, 0.9), digits),
            'min': round(min(values), digits), 'max': round(max(values), digits)}


def load(folder):
    folder = Path(folder)
    events = []
    with open(folder / 'events.csv', newline='') as f:
        for row in csv.DictReader(f):
            events.append({'feed': row['feed'], 'kind': row['kind'], 'button': int(row['button']),
                           'source': int(row['source']), 'phase': int(row['phase']), 'active': int(row['active']),
                           'recv': int(row['recv_ns']), 'recv_cont': int(row['recv_cont_ns']),
                           'stamp': float(row['stamp_s']), 'dx': float(row['dx']), 'dy': float(row['dy'])})
    marks = []
    with open(folder / 'marks.csv', newline='') as f:
        for row in csv.DictReader(f):
            marks.append({'at': int(row['at_ns']), 'what': row['what'], 'value': int(row['value'])})
    context = json.loads((folder / 'context.json').read_text())
    return events, marks, context


def clock_of_stamps(moves):
    """Which clock GCMouse's lastEventTimestamp is on, from its offset to the arrival time."""
    if not moves:
        return None
    absolute = [m['recv'] / 1e9 - m['stamp'] for m in moves if m['stamp'] > 0]
    continuous = [m['recv_cont'] / 1e9 - m['stamp'] for m in moves if m['stamp'] > 0]
    if not absolute:
        return {'clock': 'none'}
    out = {'absolute_offset_ms': round(quantile(absolute, 0.5) * 1e3, 3),
           'continuous_offset_ms': round(quantile(continuous, 0.5) * 1e3, 3)}
    for name, offsets in (('mach_absolute', absolute), ('mach_continuous', continuous)):
        good = sum(0 <= o < 0.02 for o in offsets)
        if good >= 0.9 * len(offsets):
            out['clock'] = name
            out['age_ms'] = summary_stats([o * 1e3 for o in offsets], 3)
            return out
    out['clock'] = 'unknown'
    return out


def report_rate(moves, start):
    """Reports a second while moving, and the mouse's polling setting it implies."""
    if not moves:
        return None
    by_source = {}
    for m in moves:
        by_source.setdefault(m['source'], []).append(m)
    source, series = max(by_source.items(), key=lambda item: len(item[1]))
    seconds = {}
    slots = {}
    windows = {}
    for m in series:
        at = m['recv'] - start
        if at < 0:
            continue
        seconds[at // 10**9] = seconds.get(at // 10**9, 0) + 1
        slots.setdefault(at // 10**9, set()).add((at % 10**9) // (20 * 10**6))
        windows[at // (100 * 10**6)] = windows.get(at // (100 * 10**6), 0) + 1
    moving = [s for s in seconds if len(slots[s]) >= 40]  # moved in 80% of the 50 slots of 20 ms
    rates = [seconds[s] for s in moving]
    fastest = quantile(list(windows.values()), 0.95) * 10 if windows else None
    setting = min(STANDARD_RATES, key=lambda r: abs(math.log(r / fastest))) if fastest else None
    gaps = [(b['recv'] - a['recv']) / 1e6 for a, b in zip(series, series[1:]) if b['recv'] - a['recv'] < 5 * 10**6]
    return {'source': source, 'sources_moving': len(by_source), 'moving_seconds': len(moving),
            'per_second_median': quantile(rates, 0.5), 'per_second_max': max(rates) if rates else None,
            'fastest_100ms_rate': fastest, 'likely_setting_hz': setting,
            'gap_ms': summary_stats(gaps, 3)}


def match_clicks(game_downs, app_downs, window_ns=100 * 10**6):
    """Pairs each AppKit button press with the GCMouse press of the same button nearest in time."""
    pairs, used = [], set()
    for a in app_downs:
        best = None
        for i, g in enumerate(game_downs):
            if i in used or g['button'] != a['button']:
                continue
            gap = abs(a['recv'] - g['recv'])
            if gap < window_ns and (best is None or gap < best[0]):
                best = (gap, i)
        if best:
            used.add(best[1])
            pairs.append((game_downs[best[1]], a))
    unmatched_game = [g for i, g in enumerate(game_downs) if i not in used]
    return pairs, unmatched_game, len(app_downs) - len(pairs)


def clicks(events, sens):
    game_moves = [e for e in events if e['feed'] == 'game' and e['kind'] == 'move']
    game_downs = [e for e in events if e['feed'] == 'game' and e['kind'] == 'down' and e['phase'] == PHASE_CLICKS]
    app_downs = [e for e in events if e['feed'] == 'app' and e['kind'] == 'down' and e['phase'] == PHASE_CLICKS]
    # A GCMouse press may come twice, once per interface of the same mouse: keep the first of each button.
    deduped = []
    for g in game_downs:
        if deduped and deduped[-1]['button'] == g['button'] and g['recv'] - deduped[-1]['recv'] < 5 * 10**6:
            continue
        deduped.append(g)
    pairs, unmatched_game, unmatched_app = match_clicks(deduped, app_downs)
    rows = []
    for g, a in pairs:
        lo, hi = sorted((g['recv'], a['recv']))
        between = [m for m in game_moves if lo <= m['recv'] < hi]
        sx, sy = sum(m['dx'] for m in between), sum(m['dy'] for m in between)
        around = [m for m in game_moves if g['recv'] - 50 * 10**6 <= m['recv'] < g['recv'] + 50 * 10**6]
        speed = math.hypot(sum(m['dx'] for m in around), sum(m['dy'] for m in around)) / 0.1
        rows.append({'button': a['button'],
                     'gap_ms': (a['recv'] - g['recv']) / 1e6,                  # AppKit click after GCMouse click
                     'appkit_age_ms': a['recv'] / 1e6 - a['stamp'] * 1e3,        # AppKit arrival after hardware time
                     'game_age_ms': g['recv'] / 1e6 - a['stamp'] * 1e3,          # GCMouse arrival after hardware time
                     'counts_between': math.hypot(sx, sy),
                     'speed_counts_per_s': speed})
    swiping = [r for r in rows if r['speed_counts_per_s'] >= 2000]
    out = {'matched': len(rows), 'appkit_only': unmatched_app, 'gcmouse_only': len(unmatched_game),
           'gap_ms': summary_stats([r['gap_ms'] for r in rows]),
           'appkit_age_ms': summary_stats([r['appkit_age_ms'] for r in rows]),
           'game_age_ms': summary_stats([r['game_age_ms'] for r in rows]),
           'swiping_clicks': len(swiping),
           'swiping_speed_counts_per_s': summary_stats([r['speed_counts_per_s'] for r in swiping], 0),
           'swiping_counts_between': summary_stats([r['counts_between'] for r in swiping], 1),
           'per_click': [{k: round(v, 3) for k, v in r.items()} for r in rows]}
    if sens and swiping:
        degrees = [r['counts_between'] * OW_DEGREES_PER_COUNT * sens for r in swiping]
        out['swiping_degrees_between'] = summary_stats(degrees, 3)
    return out


def switching(events, marks):
    """After each return to the app in step 2: did GCMouse motion come back while the pointer moved?"""
    phase2 = [m for m in marks if m['what'] == 'start' and m['value'] == 2]
    if not phase2:
        return None
    begin = phase2[0]['at']
    edges = [m for m in marks if m['at'] >= begin and m['what'] in ('activate', 'resign', 'finish')]
    returns = []
    for i, m in enumerate(edges):
        if m['what'] != 'activate':
            continue
        end = next((e['at'] for e in edges[i + 1:]), None) or max(e['recv'] for e in events) + 1
        app_moves = [e for e in events if e['feed'] == 'app' and e['kind'] == 'move' and m['at'] <= e['recv'] < end]
        game_moves = [e for e in events if e['feed'] == 'game' and e['kind'] == 'move' and m['at'] <= e['recv'] < end]
        first_app = (app_moves[0]['recv'] - m['at']) / 1e6 if app_moves else None
        first_game = (game_moves[0]['recv'] - m['at']) / 1e6 if game_moves else None
        returns.append({'return': m['value'], 'seconds': round((end - m['at']) / 1e9, 2),
                        'pointer_events': len(app_moves), 'gcmouse_reports': len(game_moves),
                        'first_pointer_ms': first_app and round(first_app, 1),
                        'first_gcmouse_ms': first_game and round(first_game, 1),
                        'resumed': bool(game_moves) if len(app_moves) >= 10 else None})
    background = [e for e in events if e['feed'] == 'game' and e['kind'] == 'move' and e['phase'] == PHASE_SWITCH
                  and not e['active']]
    notes = sorted({m['what'] for m in marks if m['what'] in ('detach', 'attach', 'reattach', 'input_replaced',
                                                              'handler_cleared', 'current') and m['at'] >= begin})
    return {'returns': returns, 'gcmouse_reports_while_away': len(background), 'framework_notes': notes}


def analyse(folder, sens=None):
    events, marks, context = load(folder)
    start = context['started_ns']
    moves = [e for e in events if e['feed'] == 'game' and e['kind'] == 'move' and e['phase'] == PHASE_CLICKS]
    summary = {'schema': 1, 'context': context, 'sensitivity': sens,
               'gcmouse_clock': clock_of_stamps(moves),
               'rate': report_rate(moves, start),
               'clicks': clicks(events, sens),
               'switching': switching(events, marks)}
    summary['verdict'] = verdict(summary)
    (Path(folder) / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True))
    return summary


def verdict(s):
    lines = []
    r = s['rate']
    if r and r['moving_seconds']:
        lines.append(f"Your mouse sent about {r['per_second_median']:,.0f} reports a second while moving "
                     f"(up to {r['fastest_100ms_rate']:,.0f} in its fastest moments): it looks set to "
                     f"{r['likely_setting_hz']:,} Hz.")
    elif r:
        lines.append('Not enough steady movement to measure the report rate.')
    else:
        lines.append('No motion arrived through the Game Controller framework.')
    c = s['clicks']
    if c['matched']:
        g = c['gap_ms']
        lines.append(f"Clicks: {c['matched']} measured. A click reached the app as a macOS mouse event (Recall's click "
                     f"path today) {g['median']:.1f} ms after it reached the game-controller path (Recall's motion path); "
                     f"{g['p90']:.1f} ms at the 90th percentile, {g['max']:.1f} ms at worst.")
        if c['swiping_clicks']:
            b = c['swiping_counts_between']
            line = (f"In the {c['swiping_clicks']} clicks made while swiping (median "
                    f"{c['swiping_speed_counts_per_s']['median']:,.0f} counts a second), {b['median']:.0f} counts of "
                    f"motion (up to {b['max']:.0f}) arrived in that gap, so the game would apply them before the click")
            if c.get('swiping_degrees_between'):
                d = c['swiping_degrees_between']
                line += (f": at sensitivity {s['sensitivity']:g} that is {d['median']:.2f}° "
                         f"({d['p90']:.2f}° at the 90th percentile) past where you clicked")
            lines.append(line + '.')
    else:
        lines.append('No click was measured on both paths.')
    if c['appkit_only'] or c['gcmouse_only']:
        lines.append(f"Clicks seen on only one path: {c['appkit_only']} macOS-only, {c['gcmouse_only']} game-controller-only.")
    w = s['switching']
    if w and w['returns']:
        judged = [x for x in w['returns'] if x['resumed'] is not None]
        resumed = sum(1 for x in judged if x['resumed'])
        lines.append(f"Command-Tab: game-controller motion resumed after {resumed} of {len(judged)} returns"
                     + (f" ({len(w['returns']) - len(judged)} without enough movement to judge)."
                        if len(judged) < len(w['returns']) else '.'))
        if w['framework_notes']:
            lines.append('Framework events while switching: ' + ', '.join(w['framework_notes']) + '.')
    elif w is not None:
        lines.append('Step 2 started but no return to the app was recorded.')
    return lines


# ---- Synthetic check ----

def synthetic(folder):
    """A 2,000 Hz mouse swiping left and right; clicks reach GCMouse 0.3 ms and AppKit 3.3 ms after the
    hardware; GCMouse resumes after two of three returns. Known answers are asserted."""
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    start = 10**12
    rows, marks = [], [(start, 'start', 1)]
    def add(feed, kind, button, phase, active, recv, stamp_ns, dx=0.0, dy=0.0, source=0):
        rows.append((feed, kind, button, source, phase, active, recv, recv + 5 * 10**9, stamp_ns / 1e9, dx, dy))
    period = 500_000  # 2,000 Hz
    for i in range(30 * 2000):
        t = start + i * period
        dx = 10.0 if (i // 1000) % 2 == 0 else -10.0  # 20,000 counts a second, reversing every 0.5 s
        add('game', 'move', 0, 1, 1, t + 300_000, t, dx, 0.0)
    for k in range(25):
        t = start + 10**9 * (k + 1) + 250_000_000
        add('game', 'down', 0, 1, 1, t + 300_000, t)
        add('game', 'down', 0, 1, 1, t + 350_000, t, source=1)      # the mouse's second interface
        add('app', 'down', 0, 1, 1, t + 3_300_000, t)
        add('game', 'up', 0, 1, 1, t + 80_300_000, t + 80_000_000)
        add('app', 'up', 0, 1, 1, t + 83_300_000, t + 80_000_000)
    switch_at = start + 31 * 10**9
    marks.append((switch_at, 'start', 2))
    for n in range(1, 4):
        away = switch_at + (n - 1) * 5 * 10**9 + 10**9
        back = away + 2 * 10**9
        marks += [(away, 'resign', n - 1), (back, 'activate', n)]
        for j in range(200):
            t = back + 100_000_000 + j * 5_000_000
            add('app', 'move', 0, 2, 1, t + 4_000_000, t, 3.0, 0.0)
            if n != 2:
                add('game', 'move', 0, 2, 1, t + 300_000, t, 2.0, 0.0)
    marks.append((switch_at + 16 * 10**9, 'finish', 1))
    rows.sort(key=lambda r: r[6])
    with open(folder / 'events.csv', 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['feed', 'kind', 'button', 'source', 'phase', 'active', 'recv_ns', 'recv_cont_ns', 'stamp_s', 'dx', 'dy'])
        w.writerows(rows)
    with open(folder / 'marks.csv', 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['at_ns', 'what', 'value'])
        w.writerows(marks)
    (folder / 'context.json').write_text(json.dumps({'started_ns': start, 'mice': [], 'returns': 3}))
    s = analyse(folder, sens=5)
    assert s['gcmouse_clock']['clock'] == 'mach_absolute', s['gcmouse_clock']
    assert s['rate']['likely_setting_hz'] == 2000, s['rate']
    assert s['clicks']['matched'] == 25 and s['clicks']['gcmouse_only'] == 0, s['clicks']
    assert abs(s['clicks']['gap_ms']['median'] - 3.0) < 0.01, s['clicks']['gap_ms']
    # 3.0 ms at 20,000 counts a second: 6 reports of 10 counts.
    assert 55 <= s['clicks']['swiping_counts_between']['median'] <= 65, s['clicks']['swiping_counts_between']
    resumed = [x['resumed'] for x in s['switching']['returns']]
    assert resumed == [True, False, True], resumed
    return s


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--out')
    parser.add_argument('--sens', type=float)
    parser.add_argument('--analyse')
    parser.add_argument('--selftest', action='store_true')
    parser.add_argument('--synthetic', metavar='DIR')
    args = parser.parse_args()
    if args.synthetic:
        s = synthetic(args.synthetic)
        print('\n'.join(s['verdict']))
        print('synthetic: all known answers matched')
        return
    if args.analyse:
        print('\n'.join(analyse(args.analyse, args.sens)['verdict']))
        return
    build()
    if args.selftest:
        sys.exit(subprocess.run([str(EXECUTABLE), '--selftest']).returncode)
    sens = args.sens or None
    if args.sens is None and sys.stdin.isatty():
        answer = input('Your Overwatch sensitivity (press Return to skip): ').strip()
        sens = float(answer) if answer else None
    folder = Path(args.out) if args.out else LOGS / time.strftime('timing-check-%Y%m%d-%H%M%S')
    folder.mkdir(parents=True, exist_ok=True)
    print('Opening Mouse Timing Check. Follow the two steps in its window.')
    subprocess.run(['open', '-W', '-n', str(APP), '--args', '--out', str(folder)], check=True)
    if not (folder / 'events.csv').exists():
        print('The check closed before it recorded anything.')
        return
    summary = analyse(folder, sens)
    print()
    print('\n'.join(summary['verdict']))
    print(f'\nSaved in {folder}.')


if __name__ == '__main__':
    main()
