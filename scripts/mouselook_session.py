#!/usr/bin/env python3
"""Mouselook play-test: the shipped runtime with only the experimental window driver swapped in.

Developer/QA tool. Never modifies the installed app, its runtime or the Phase 2 archive.

  prepare  Clone the Phase 2 runtime (an APFS clone costs no disk space), swap in the
           driver from build_mouselook_driver.py and verify every other file against
           the runtime manifest.
  play     Start Battle.net from that runtime against the installed Recall app's
           environment with the app's exact environment and arguments, plus:
           mouselook with raw input allowed for Overwatch.exe; Control-Option-Command-M
           switching raw input off and on in game (Glass sound = raw input, Basso =
           pointer events); per-second input statistics and DXMT frame timing under
           logs/mouselook/<stamp>/. Battle.net exits 25 s after the game starts, as in the app.
  report   FPS with the mouse still versus moving, and the cost of delivering motion,
           for each mode, from a play session.
"""
import argparse
import csv
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import candidate_contract  # noqa: E402

RUNTIME_VERSION = 'phase2-20260913.8'
ENGINE_SOURCE = ROOT / 'runtime/phase-2/artifacts' / RUNTIME_VERSION
ENGINE = ROOT / 'runtime/mouselook/engine'
DRIVER = ROOT / 'runtime/build/winemac-mouselook/current/winemac.so'
DRIVER_PATH = 'lib/wine/x86_64-unix/winemac.so'
APP_ROOT = Path.home() / 'Library/Application Support/Overwatch2Mac'
# The launcher's executable, under its current and former names.
APP_BINARIES = ('Recall.app/Contents/MacOS/Recall', 'Overwatch 2 Mac.app/Contents/MacOS/Overwatch2Mac')
LOGS = ROOT / 'logs/mouselook'
CLIENT = 'drive_c/Program Files (x86)/Battle.net/Battle.net.exe'
CLIENT_ARGS = ['--disable-gpu-compositing', '--from-launcher', '--in-process-gpu',
               '--use-gl=angle', '--use-angle=swiftshader']
MOVING, STILL = 100, 5  # macOS mouse events in a second


def sha(path):
    with open(path, 'rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def windows_path(path):
    """Wine's Z: drive maps to the macOS filesystem root."""
    return 'Z:' + str(Path(path).resolve()).replace('/', '\\')


def prepare():
    if not DRIVER.is_file():
        raise SystemExit('Build the driver first: python3 scripts/build_mouselook_driver.py')
    manifest = json.loads((ENGINE_SOURCE / 'runtime.json').read_text())
    if manifest['version'] != RUNTIME_VERSION:
        raise SystemExit('Unexpected Phase 2 runtime manifest')
    if not ENGINE.exists():
        ENGINE.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['/bin/cp', '-Rc', str(ENGINE_SOURCE), str(ENGINE)], check=True)
    for relative, spec in manifest['files'].items():
        if relative == DRIVER_PATH:
            continue
        path = ENGINE / relative
        same = os.readlink(path) == spec['symlink'] if 'symlink' in spec else sha(path) == spec['sha256']
        if not same:
            raise SystemExit('Test runtime differs from the shipped runtime: ' + relative)
    target = ENGINE / DRIVER_PATH
    if sha(target) != sha(DRIVER):
        target.unlink()
        shutil.copy2(DRIVER, target)
    return {'engine': str(ENGINE), 'driver_sha256': sha(target),
            'shipped_driver_sha256': manifest['files'][DRIVER_PATH]['sha256']}


def processes():
    table = subprocess.run(['/bin/ps', '-axo', 'pid=,comm='], capture_output=True, text=True, check=True).stdout
    for line in table.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2:
            yield int(fields[0]), fields[1]


def running_servers():
    """Wine servers of the installed app's runtimes or of this test runtime."""
    roots = (str(APP_ROOT / 'runtimes') + '/', str(ENGINE) + '/')
    return [(pid, command) for pid, command in processes()
            if command.endswith('/wineserver') and command.startswith(roots)]


def preflight(stop_running):
    state = json.loads((APP_ROOT / 'state.json').read_text())
    if state.get('active_runtime') != RUNTIME_VERSION:
        raise SystemExit(f'The installed app uses {state.get("active_runtime")}; this driver was built for {RUNTIME_VERSION}.')
    if not (APP_ROOT / 'environment' / CLIENT).is_file():
        raise SystemExit('Battle.net is not installed in the Recall environment.')
    if any(command.endswith(APP_BINARIES) for _, command in processes()):
        raise SystemExit('Quit the Recall app first (Command-Q), so it cannot start a second session.')
    servers = running_servers()
    if servers and any(command.endswith('Overwatch.exe') for _, command in processes()):
        raise SystemExit('Overwatch is running. Quit the game first; this tool never closes a match.')
    if servers and not stop_running:
        raise SystemExit('Battle.net is still running. Quit it, or rerun with --stop-running to close it.')
    for _, command in servers:
        env = {'PATH': '/usr/bin:/bin', 'WINEPREFIX': str(APP_ROOT / 'environment')}
        subprocess.run([command, '-k'], env=env, timeout=30)
    deadline = time.time() + 30
    while running_servers():
        if time.time() > deadline:
            raise SystemExit('The previous session did not exit.')
        time.sleep(0.5)


def environment(session, allow, interval_us, unscaled=False, raw=True, raw_interval_us=None):
    """The app's wineEnv (scripts/portable_setup.m) with the test runtime and diagnostics."""
    root = APP_ROOT
    config = root / 'dxmt.conf' if (root / 'dxmt.conf').is_file() else ENGINE / 'config/dxmt.conf'
    env = dict(candidate_contract.load()['environment'])
    env.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME=str(root / 'home'), USER='player',
               TMPDIR=str(root / 'tmp'), WINEPREFIX=str(root / 'environment'), WINEARCH='win64',
               WINESERVER=str(ENGINE / 'bin/wineserver'), WINELOADER=str(ENGINE / 'bin/wine'),
               WINEDEBUG='-all', CX_APPLEGPTK_LIBD3DSHARED_PATH=str(ENGINE / 'lib/external/libd3dshared.dylib'),
               DXMT_SHADER_CACHE_PATH=str(root / 'cache/shaders'), DXMT_LOG_LEVEL='error', DXMT_LOG_PATH='none',
               DXMT_CONFIG_FILE=windows_path(config), DXMT_PIPELINE_CACHE_PATH=str(root / 'cache/pipelines'),
               DXMT_FRAME_LOG=windows_path(session / 'frames'), WINEMAC_INPUT_STATS=str(session / 'input'))
    if allow:
        env.update(WINEMAC_MOUSELOOK='Overwatch.exe', WINEMAC_MOUSELOOK_SWITCH='1')
    else:
        env.pop('WINEMAC_MOUSELOOK', None)  # the app's contract enables it
    if interval_us:
        env['WINEMAC_MOUSELOOK_INTERVAL_US'] = str(interval_us)
    if unscaled:
        env['WINEMAC_MOUSELOOK_UNSCALED'] = '1'
    if not raw:
        env['WINEMAC_MOUSELOOK_RAW'] = '0'
    if raw_interval_us is not None:
        env['WINEMAC_MOUSELOOK_RAW_INTERVAL_US'] = str(raw_interval_us)
    return env


def play(args):
    preflight(args.stop_running)
    runtime = prepare()
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    session = LOGS / stamp
    session.mkdir(parents=True)
    env = environment(session, not args.previous_only, args.interval_us, args.unscaled,
                      not args.raw_off, args.raw_interval_us)
    record = dict(runtime, started=stamp, mouselook_allowed=not args.previous_only,
                  interval_us=args.interval_us, unscaled=args.unscaled, raw_input=not args.raw_off,
                  raw_interval_us=args.raw_interval_us, contract_profile=candidate_contract.load()['profile'])
    (session / 'session.json').write_text(json.dumps(record, indent=2) + '\n')
    with (session / 'battlenet.log').open('w') as log:
        subprocess.Popen([str(ENGINE / 'bin/wine'), str(APP_ROOT / 'environment' / CLIENT), *CLIENT_ARGS],
                         env=env, cwd=APP_ROOT, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                         start_new_session=True)
    with (session / 'battlenet-closer.log').open('w') as log:
        subprocess.Popen([sys.executable, str(ROOT / 'scripts/battlenet_closer.py'), '--engine', str(ENGINE),
                          '--prefix', str(APP_ROOT / 'environment'), '--grace-seconds', '25',
                          '--log', str(session / 'battlenet-closer.json')],
                         cwd=ROOT, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    print(f'Battle.net is starting from the test runtime. Session logs: {session}')
    if not args.previous_only and not args.raw_off:
        print('Raw input uses mouse counts, as on Windows: set your PC sensitivity in Overwatch. In game, '
              'Control-Option-Command-M switches raw input off and on: Glass sound = raw input, '
              'Basso = pointer events.')
    print('Afterwards, run: python3 scripts/mouselook_session.py report')


def frame_times(session):
    """Present timestamps (ms) from every DXMT frame log segment of the session."""
    stamps = []
    for path in sorted(session.glob('frames-*.csv')):
        if '.events' in path.name:  # DXMT's event logs share the prefix and also carry unix_us
            continue
        with path.open(newline='') as stream:
            for row in csv.DictReader(stream):
                try:
                    stamps.append(int(row['unix_us']) / 1000)
                except (KeyError, TypeError, ValueError):
                    continue
    return sorted(set(stamps))


def classify(line):
    """(mode, motion) for a clean in-game second, or None."""
    if not line['app_active'] or not (line['hidden'] or line['transparent']):
        return None
    if line['mouselook_enters'] or line['mouselook_exits'] or line['switches']:
        return None
    motion = 'moving' if line['mac_moves'] >= MOVING else 'still' if line['mac_moves'] <= STILL else None
    return (line['mode'], motion) if motion else None


def report(args):
    session = Path(args.session) if args.session else max(LOGS.glob('2*'), default=None)
    if not session or not session.is_dir():
        raise SystemExit('No mouselook session found.')
    lines = []
    for path in session.glob('input-*.jsonl'):
        for text in path.read_text().splitlines():
            try:
                line = json.loads(text)
            except json.JSONDecodeError:
                continue
            if line.get('exe', '').lower() == 'overwatch.exe':
                lines.append(line)
    lines.sort(key=lambda line: line['unix_ms'])
    frames = frame_times(session)
    if not lines or not frames:
        raise SystemExit(f'{session} has no Overwatch input statistics or frame timing yet.')

    groups, index, previous = {}, 0, None
    for line in lines:
        end = line['unix_ms']
        start = previous if previous and end - previous <= 1500 else end - 1000
        previous = end
        while index < len(frames) and frames[index] <= start:
            index += 1
        count = 0
        while index + count < len(frames) and frames[index + count] <= end:
            count += 1
        key = classify(line)
        if key and count:
            line = dict(line, fps=count * 1000 / (end - start))
            groups.setdefault(key, []).append(line)

    def summary(rows):
        seconds = len(rows)
        per_call = [row['setpos_us'] / row['setpos_calls'] for row in rows if row['setpos_calls'] > row['setpos_fast']]
        fps = sorted(row['fps'] for row in rows)
        delivered = sum(row['moves_delivered'] for row in rows)
        mac_motion = sum(row['mac_dx'] + row['mac_dy'] for row in rows)
        raw_motion = sum(row.get('raw_dx', 0) + row.get('raw_dy', 0) for row in rows)
        return {'seconds': seconds, 'median_fps': round(statistics.median(fps), 1),
                'low_fps_10th_percentile': round(fps[int(len(fps) * 0.1)], 1),
                'mouse_events_per_second': round(statistics.mean(row['mac_moves'] for row in rows)),
                'raw_reports_per_second': round(statistics.mean(row.get('raw_moves', 0) for row in rows)),
                'raw_deliveries_per_second': round(statistics.mean(row.get('raw_posted', 0) for row in rows)),
                'pointer_fallback_per_second': round(statistics.mean(row.get('pointer_fallback', 0) for row in rows), 1),
                # Mouse counts per pointer-event point: the tracking speed's inverse when both carry the motion.
                'counts_per_point': round(raw_motion / mac_motion, 3) if raw_motion and mac_motion else None,
                'moves_delivered_per_second': round(statistics.mean(row['moves_delivered'] for row in rows)),
                # Time the client thread spent handing motion to Wine.
                'delivery_ms_per_second': round(statistics.mean(row['deliver_us'] for row in rows) / 1000, 2),
                'delivery_us_each': round(sum(row['deliver_us'] for row in rows) / delivered, 1) if delivered else 0,
                'warps_per_second': round(statistics.mean(row['warps'] for row in rows), 1),
                'recentres_per_second': round(statistics.mean(row['setpos_calls'] for row in rows), 1),
                'recentre_wait_us': round(statistics.mean(per_call), 1) if per_call else 0,
                'recentre_wait_max_us': round(max(row['setpos_max_us'] for row in rows), 1),
                'motion_dropped_per_second': round(statistics.mean(row['dropped_after_warp'] for row in rows), 1),
                # Previous behaviour: motion at the edge-pinned scale, not the canvas scale.
                'edge_pinned_share': round(sum(row['posted_relative'] for row in rows) /
                                           max(1, sum(row['posted_relative'] + row['posted_absolute'] for row in rows)), 2)}

    result = {'session': str(session), 'peak_mouse_events_per_second': max(line['mac_moves'] for line in lines),
              'modes': {f'{mode}/{motion}': summary(rows) for (mode, motion), rows in sorted(groups.items())
                        if len(rows) >= 3}}
    for mode in ('legacy', 'mouselook', 'raw'):
        still, moving = result['modes'].get(f'{mode}/still'), result['modes'].get(f'{mode}/moving')
        if still and moving:
            result[f'{mode}_fps_drop_while_moving_percent'] = round(
                100 * (1 - moving['median_fps'] / still['median_fps']), 1)
    seen = {'hid_cursor': any(line['hidden'] for line in lines),
            'transparent_cursor': any(line['transparent'] for line in lines),
            'confined_cursor': any(line['clipping'] for line in lines),
            're_centred_cursor': any(line['setpos_calls'] for line in lines),
            'mouselook_engaged': any(line['mode'] in ('mouselook', 'raw') for line in lines),
            'raw_input_engaged': any(line['mode'] == 'raw' for line in lines)}
    result['raw_mice'] = max((line.get('raw_mice', 0) for line in lines), default=0)
    result['game_behaviour'] = seen
    (session / 'report.json').write_text(json.dumps(result, indent=2) + '\n')

    print(f'Session {session.name}; peak mouse events per second: {result["peak_mouse_events_per_second"]}')
    print('Game: ' + ', '.join(f'{k.replace("_", " ")}={"yes" if v else "no"}' for k, v in seen.items()))
    print(f'{"mode/mouse":18} {"secs":>5} {"FPS":>6} {"low":>6} {"pointer/s":>9} {"raw/s":>6} '
          f'{"delivered/s":>11} {"cost ms/s":>9} {"fallback/s":>10} {"warps/s":>7} {"dropped/s":>9}')
    for name, row in result['modes'].items():
        print(f'{name:18} {row["seconds"]:>5} {row["median_fps"]:>6} {row["low_fps_10th_percentile"]:>6} '
              f'{row["mouse_events_per_second"]:>9} {row["raw_reports_per_second"]:>6} '
              f'{row["moves_delivered_per_second"]:>11} {row["delivery_ms_per_second"]:>9} '
              f'{row["pointer_fallback_per_second"]:>10} {row["warps_per_second"]:>7} '
              f'{row["motion_dropped_per_second"]:>9}')
    raw_moving = result['modes'].get('raw/moving')
    if raw_moving:
        print(f'Raw input: {result["raw_mice"]} mice seen; {raw_moving["counts_per_point"]} mouse counts per '
              f'pointer point; each delivery cost the game thread {raw_moving["delivery_us_each"]} us.')
    for mode in ('legacy', 'mouselook', 'raw'):
        if f'{mode}_fps_drop_while_moving_percent' in result:
            print(f'{mode}: FPS drop while moving {result[f"{mode}_fps_drop_while_moving_percent"]}%')
    print(f'Full report: {session / "report.json"}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('prepare', help='Create or refresh the test runtime')
    launch = commands.add_parser('play', help='Start a play-test session')
    launch.add_argument('--stop-running', action='store_true', help='Close a running Battle.net/Overwatch session first')
    launch.add_argument('--previous-only', action='store_true',
                        help='Measure the previous behaviour only (mouselook not allowed)')
    launch.add_argument('--interval-us', type=int, default=0,
                        help='Optional cap on mouselook motion delivery, in microseconds between deliveries')
    launch.add_argument('--unscaled', action='store_true',
                        help='Mouselook motion at the edge-pinned scale instead of the fullscreen canvas scale')
    launch.add_argument('--raw-off', action='store_true',
                        help='Mouselook from pointer events only, without raw input')
    launch.add_argument('--raw-interval-us', type=int, default=None,
                        help='Minimum time between raw input deliveries in microseconds (default 1000; 0 = every report)')
    summary = commands.add_parser('report', help='Summarise a play-test session')
    summary.add_argument('session', nargs='?', help='Session directory (default: latest)')
    args = parser.parse_args()
    if args.command == 'prepare':
        print(json.dumps(prepare(), indent=2))
    elif args.command == 'play':
        play(args)
    else:
        report(args)


if __name__ == '__main__':
    main()
