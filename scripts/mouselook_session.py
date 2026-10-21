#!/usr/bin/env python3
"""Mouselook play-test: the installed engine with only the window driver swapped in.

Developer/QA tool. Never modifies the installed app, its engine or its caches.

  prepare  Clone the installed Recall app's active engine (an APFS clone costs no disk
           space), swap in the driver from `build_wine_native.py winemac` with the
           engine's minimum macOS, and verify every other file against the engine's
           manifest.
  play     Start Overwatch from that engine as the app's Play button does, against the
           installed Recall environment, with the app's exact environment and launch
           settings (Battle.net's size, Game Mode, MetalFX upscaling and the Metal HUD
           as the app has them), plus per-second input statistics and DXMT frame timing
           under logs/mouselook/<stamp>/. Battle.net exits 25 s after the game starts, as
           in the app. The game's resolution and display are the ones the app last
           launched with.
             --blind          The blind input test: after a warm-up, the driver runs each
                              input variant (VARIANTS) for two stretches in a random order,
                              marking each change with the same sound, and
                              Control-Option-Command-M records "I felt a hitch".
             --variant NAME   Start with this input variant (default: the players' one, the
                              launch settings' WINEMAC_INPUT_VARIANT; precise from 1.5.0).
             --timing-switch  Control-Option-Command-M switches between the legacy and
                              fixed variants (Basso and Glass sounds).
             --raw-switch     The hotkey switches raw input off and on instead (Glass =
                              raw input, Basso = pointer events).
  keep     Runs beside a session (play starts it): saves DXMT's rotated frame log segments,
           which it otherwise drops after about ten minutes of frames.
  report   For each mode or variant and mouse motion: FPS, hitches, raw input's rate, the
           motion it delivered, how old each move's event time was when Wine sent it on,
           and motion macOS saw that raw input did not. A blind test adds the variants'
           comparison, per stretch, with the player's marks, and writes report.html.
"""
import argparse
import bisect
import csv
import datetime
import hashlib
import html
import json
import math
import os
from pathlib import Path
import random
import shutil
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import candidate_contract  # noqa: E402
import derive_runtime  # noqa: E402

ENGINE = ROOT / 'runtime/mouselook/engine'
DRIVER = ROOT / 'runtime/build/wine-native/winemac/current/winemac.so'
DRIVER_PATH = 'lib/wine/x86_64-unix/winemac.so'
APP_ROOT = Path.home() / 'Library/Application Support/Overwatch2Mac'
APP_DOMAIN = 'org.overwatch2mac.launcher'
# The launcher's executable, under its current and former names.
APP_BINARIES = ('Recall.app/Contents/MacOS/Recall', 'Overwatch 2 Mac.app/Contents/MacOS/Overwatch2Mac')
LOGS = ROOT / 'logs/mouselook'
CLIENT = 'drive_c/Program Files (x86)/Battle.net/Battle.net.exe'
# The app's launch command (portable_setup.m launchClient); "launch Pro" starts Overwatch.
CLIENT_ARGS = ['--disable-gpu-compositing', '--from-launcher', '--in-process-gpu',
               '--use-gl=angle', '--use-angle=swiftshader', '--exec=launch Pro']
# What portable_setup.m battleNetSize names, at 192 DPI.
BATTLENET_DPI = '192:Battle.net.exe;Battle.net Launcher.exe;BlizzardError.exe'
METAL_HUD = {'MTL_HUD_ENABLED': '1', 'MTL_HUD_DISABLE_MENU_BAR': '1',
             'MTL_HUD_ELEMENTS': 'device,rosetta,layersize,memory,gamemode,fps,gputime,frameinterval,'
                                 'frameintervalgraph,shaders'}
MOVING, STILL = 100, 5  # macOS mouse events in a second

# The driver's input variants (cocoa_app.m input_variants), as the report names them.
VARIANTS = {
    'legacy': 'Recall 1.4 and earlier',         # stale event times, every delivery on the 1 ms timer
    'stamps': 'Correct time stamps only',       # real event times, deliveries as legacy
    'at-once': 'Faster sending only',           # stale event times, a report goes out at once
    'fixed': 'Both (the first fix)',            # real times, at once, pointer events stand in
    'keys': 'No key-press wait',                # legacy, key presses read a cached input-method state
    'clicks': 'Clicks in order only',           # legacy, mouse buttons from GCMouse in order with motion
    'precise': 'Precise input',                 # fixed, plus mouse buttons from GCMouse in order with motion
}
BLIND_STRETCH_S, BLIND_WARMUP_S = 75, 40
RAWINPUT_TRACE = '-all,+timestamp,+pid,+rawinput'  # --trace-rawinput: only the raw input channel, every class
HITCH_MS = 15.0         # a frame this long is a hitch: about twice a frame at the play-tests' 130-150 FPS
EPISODE_GAP_MS = 250    # hitch frames this close together are one hitch to the player
MARK_GRACE_MS = 300     # frames this soon after a mark are left out, so pressing the hotkey never counts
MARK_MATCH_MS = 2000    # a mark answers a hitch up to this long before it
COLOURS = {'legacy': 'var(--base)', 'stamps': '#af52de', 'at-once': '#007aff', 'fixed': '#ff9500', 'keys': '#34c759',
           'clicks': '#5ac8fa', 'precise': '#ff2d55'}


def sha(path):
    with open(path, 'rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def players_variant():
    """The input variant players get: the launch settings' WINEMAC_INPUT_VARIANT (legacy if unset)."""
    return candidate_contract.load()['environment'].get('WINEMAC_INPUT_VARIANT', 'legacy')


def windows_path(path):
    """Wine's Z: drive maps to the macOS filesystem root."""
    return 'Z:' + str(Path(path).resolve()).replace('/', '\\')


def app_state():
    return json.loads((APP_ROOT / 'state.json').read_text())


def installed_engine():
    """The installed app's active engine and its manifest."""
    version = app_state().get('active_runtime')
    engine = APP_ROOT / 'runtimes' / str(version)
    manifest_path = engine / 'runtime.json'
    if not version or not manifest_path.is_file():
        raise SystemExit('The Recall app has no installed engine; run setup in the app first.')
    manifest = json.loads(manifest_path.read_text())
    if manifest.get('version') != version:
        raise SystemExit(f'The installed engine {version} has an unexpected manifest.')
    return engine, manifest


def minimum_field(text):
    """'15.0' as the Mach-O version field (major << 16 | minor << 8)."""
    major, minor = (text.split('.') + ['0'])[:2]
    return int(major) << 16 | int(minor) << 8


def prepare():
    if not DRIVER.is_file():
        raise SystemExit('Build the driver first: python3 scripts/build_wine_native.py winemac')
    source, manifest = installed_engine()
    if ENGINE.exists():
        current = ENGINE / 'runtime.json'
        version = json.loads(current.read_text()).get('version') if current.is_file() else None
        if version != manifest['version']:
            # Only ever this tool's own clone of an engine.
            if not current.is_file() or ENGINE.resolve().parent != (ROOT / 'runtime/mouselook').resolve():
                raise SystemExit(f'{ENGINE} is not a test engine; move it aside first.')
            shutil.rmtree(ENGINE)
    fresh = not ENGINE.exists()
    if fresh:
        ENGINE.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['/bin/cp', '-Rc', str(source), str(ENGINE)], check=True)
    for relative, spec in manifest['files'].items():
        if relative == DRIVER_PATH:
            continue
        path = ENGINE / relative
        if 'symlink' in spec:
            same = path.is_symlink() and os.readlink(path) == spec['symlink']
        else:
            # A fresh clone is checked file by file; later runs only by size (the clone is ours).
            same = path.is_file() and (sha(path) == spec['sha256'] if fresh else path.stat().st_size == spec['bytes'])
        if not same:
            raise SystemExit('Test engine differs from the installed engine: ' + relative)
    target = ENGINE / DRIVER_PATH
    staged = target.with_name(target.name + '.new')
    shutil.copy2(DRIVER, staged)
    # Keep the engine's minimum macOS (derive_runtime.py does the same for a release).
    derive_runtime.restamp(staged, minimum_field(manifest.get('minimum_macos', '26.0')))
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(staged)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if target.is_file() and sha(target) == sha(staged):
        staged.unlink()
    else:
        staged.replace(target)
    return {'engine': str(ENGINE), 'engine_version': manifest['version'], 'driver_sha256': sha(target),
            'build_sha256': sha(DRIVER), 'shipped_driver_sha256': manifest['files'][DRIVER_PATH]['sha256']}


def processes():
    table = subprocess.run(['/bin/ps', '-axo', 'pid=,comm='], capture_output=True, text=True, check=True).stdout
    for line in table.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2:
            yield int(fields[0]), fields[1]


def running_servers():
    """Wine servers of the installed app's engines or of this test engine."""
    roots = (str(APP_ROOT / 'runtimes') + '/', str(ENGINE) + '/')
    return [(pid, command) for pid, command in processes()
            if command.endswith('/wineserver') and command.startswith(roots)]


def preflight(stop_running):
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


def app_settings():
    """The app's launch settings (AppModel.swift: --metal-hud, --metalfx, hidden gameMode)."""
    def flag(key, default):
        value = subprocess.run(['/usr/bin/defaults', 'read', APP_DOMAIN, key], capture_output=True, text=True)
        return value.stdout.strip() == '1' if value.returncode == 0 else default
    return {'metal_hud': flag('metalHUD', False), 'metalfx': flag('metalFXUpscaling', False),
            'game_mode': flag('gameMode', True), 'korean_support': bool(app_state().get('korean_support'))}


def environment(session, settings, variant=None, switch=None, raw=True, raw_interval_us=None, blind=None,
                trace_rawinput=False, display_log=False):
    """The app's environment (portable_setup.m wineEnv and clientEnvironment) with the test
    engine, plus diagnostics."""
    root = APP_ROOT
    contract = candidate_contract.load()
    config = root / 'dxmt.conf' if (root / 'dxmt.conf').is_file() else ENGINE / 'config/dxmt.conf'
    env = dict(contract['environment'])
    env.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME=str(root / 'home'), USER='player',
               TMPDIR=str(root / 'tmp'), WINEPREFIX=str(root / 'environment'), WINEARCH='win64',
               WINESERVER=str(ENGINE / 'bin/wineserver'), WINELOADER=str(ENGINE / 'bin/wine'),
               WINEDEBUG='-all', CX_APPLEGPTK_LIBD3DSHARED_PATH=str(ENGINE / 'lib/external/libd3dshared.dylib'),
               DXMT_SHADER_CACHE_PATH=str(root / 'cache/shaders'), DXMT_LOG_LEVEL='error', DXMT_LOG_PATH='none',
               DXMT_CONFIG_FILE=windows_path(config), DXMT_PIPELINE_CACHE_PATH=str(root / 'cache/pipelines'))
    env['WINE_APP_DPI'] = BATTLENET_DPI
    if settings['metalfx']:
        env.update(contract['metalfx_environment'])
    if settings['korean_support']:
        env['WINEMAC_SCREEN_READBACK'] = '1'
    if not settings['game_mode']:
        env.pop('WINE_GAME_MODE', None)
    if settings['metal_hud']:
        env.update(METAL_HUD)
    env.update(DXMT_FRAME_LOG=windows_path(session / 'frames'), WINEMAC_INPUT_STATS=str(session / 'input'))
    if variant:
        env['WINEMAC_INPUT_VARIANT'] = variant
    if blind:
        env.update(WINEMAC_INPUT_VARIANTS=','.join(blind['sequence']),
                   WINEMAC_INPUT_STRETCH_S=str(blind['stretch_s']), WINEMAC_INPUT_WARMUP_S=str(blind['warmup_s']))
        switch = 'mark'
    if switch:
        env['WINEMAC_MOUSELOOK_SWITCH'] = switch
    if not raw:
        env['WINEMAC_MOUSELOOK_RAW'] = '0'
    if raw_interval_us is not None:
        env['WINEMAC_MOUSELOOK_RAW_INTERVAL_US'] = str(raw_interval_us)
    if trace_rawinput:
        # Wine's own trace of the raw input calls (registration, GetRawInputData, GetRawInputBuffer), each
        # line with its millisecond tick, process and thread. It lands in battlenet.log: the game inherits
        # Battle.net's output. tests/mouselook/rawinput_trace.py summarises it.
        env['WINEDEBUG'] = RAWINPUT_TRACE
    if display_log:
        # When each frame was requested and when it reached the screen (winemetal's display log; see
        # summarize_display.py). With the input statistics it shows whether presentation changes while
        # the mouse moves: on macOS 26 a hidden cursor can tie presentation to the display refresh
        # while the mouse moves (upstream Wine MR !11880).
        env['DXMT_DISPLAY_LOG'] = str(session / 'display')
    return env


def blind_sequence(variants, rng=random):
    """Each variant twice: a random order, then nearly its reverse (its first two swapped, so no
    variant runs twice in a row). Each variant's two stretches then sit, on average, within half a
    stretch of the session's middle, so warming up or tiring weighs on every variant alike."""
    order = list(variants)
    rng.shuffle(order)
    back = order[::-1]
    if len(back) > 1:
        back[0], back[1] = back[1], back[0]
    return order + back


def play(args):
    preflight(args.stop_running)
    runtime = prepare()
    settings = app_settings()
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    session = LOGS / stamp
    session.mkdir(parents=True)
    blind = None
    if args.blind:
        chosen = args.blind_variants.split(',') if args.blind_variants else list(VARIANTS)
        unknown = [name for name in chosen if name not in VARIANTS]
        if unknown or len(chosen) < 2:
            raise SystemExit(f'--blind-variants needs two or more of: {", ".join(VARIANTS)}')
        blind = {'sequence': blind_sequence(chosen), 'stretch_s': args.stretch_seconds,
                 'warmup_s': args.warmup_seconds}
    switch = 'timing' if args.timing_switch else '1' if args.raw_switch else None
    env = environment(session, settings, args.variant, switch, not args.raw_off, args.raw_interval_us, blind,
                      args.trace_rawinput, args.display_log)
    record = dict(runtime, started=stamp, app_settings=settings, variant=args.variant or players_variant(),
                  switch=env.get('WINEMAC_MOUSELOOK_SWITCH'), raw_input=not args.raw_off,
                  raw_interval_us=args.raw_interval_us, blind=blind, winedebug=env['WINEDEBUG'],
                  display_log=args.display_log,
                  contract_profile=candidate_contract.load()['profile'])
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
    with (session / 'keeper.log').open('w') as log:
        subprocess.Popen([sys.executable, str(Path(__file__).resolve()), 'keep', str(session)],
                         cwd=ROOT, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    print(f'Overwatch is starting from the test engine. Session logs: {session}')
    if blind and len(set(blind['sequence'])) == 2:
        stretches = len(blind['sequence'])
        minutes = round((blind['warmup_s'] + blind['stretch_s'] * stretches) / 60)
        print(f'\nBlind A/B: {stretches} stretches of {blind["stretch_s"]} seconds, about {minutes} minutes of play, '
              'in the Practice Range.\n'
              f'  - The first {blind["warmup_s"]} seconds in the game are a warm-up.\n'
              '  - A soft "ping" starts each stretch. Two versions take turns: stretches 1 and 3 run one,\n'
              '    2 and 4 the other, and nothing tells you which.\n'
              '  - Play as you would with a hitscan hero: flick between bots and shoot, track and shoot.\n'
              '    Notice which stretches feel more precise and more responsive when you click.\n'
              '  - If something goes wrong (a click lost or doubled, the camera stuck), note the stretch.\n'
              '  - The clock only runs while you are in the game aiming; menus pause it.\n'
              '  - A short fanfare means the test is done. Quit the game and say which felt better:\n'
              '    stretches 1 and 3, or 2 and 4.')
        return
    if blind:
        stretches = len(blind['sequence'])
        minutes = round((blind['warmup_s'] + blind['stretch_s'] * stretches) / 60)
        print(f'\nBlind mouse test: {stretches} stretches of {blind["stretch_s"]} seconds, about {minutes} minutes '
              'of play.\nPlay in the Practice Range as you did last time: strafe while tracking bots, swipe, shoot.\n'
              f'  - The first {blind["warmup_s"]} seconds in the game are a warm-up.\n'
              f'  - A soft "ping" starts each stretch. Each runs one of {len(set(blind['sequence']))} versions, in a random order;\n'
              '    nothing tells you which.\n'
              '  - Whenever you feel a stutter or a hitch, press Control-Option-Command-M. A tiny "tink" confirms it.\n'
              '    (Control is crouch in Overwatch, so your hero may duck for a moment.)\n'
              '  - The clock only runs while you are in the game aiming; menus pause it.\n'
              '  - A short fanfare means the test is done. Quit the game, then double-click\n'
              '    "Mouse Fix Test - Report".')
        return
    if switch == 'timing':
        print(f'Raw input starts with the {args.variant or players_variant()} variant. In game, Control-Option-Command-M '
              'switches between legacy (Basso) and fixed (Glass).')
    elif switch:
        print('In game, Control-Option-Command-M switches raw input off and on: Glass = raw input, '
              'Basso = pointer events.')
    print('Afterwards, run: python3 scripts/mouselook_session.py report')


def keep_segments(session):
    """Copies DXMT's rotated frame log segments into kept/: it keeps three 2 MiB segments per log,
    about ten minutes of frames at 140 FPS, and drops older ones. Returns the copies made."""
    kept = session / 'kept'
    kept.mkdir(exist_ok=True)
    copied = 0
    for path in sorted(session.glob('frames-*.[12].csv')):
        try:
            with path.open() as stream:
                stream.readline()
                first = stream.readline().split(',')
            size = path.stat().st_size
        except OSError:
            continue
        # A segment is named by its first row's Unix time: column 5 of frames, 7 of events.
        column = 6 if '.events.' in path.name else 4
        if len(first) <= column:
            continue
        target = kept / f'{path.name[:-len(".1.csv")]}.{first[column].strip()}.csv'
        if target.exists() and target.stat().st_size == size:
            continue
        shutil.copyfile(path, target)
        copied += 1
    return copied


def keep(args):
    session = Path(args.session)
    started, seen, idle = time.time(), False, None
    while time.time() - started < args.hours * 3600:
        try:
            if keep_segments(session):
                print(time.strftime('%H:%M:%S'), 'kept rotated frame log segments', flush=True)
        except OSError as error:
            print(time.strftime('%H:%M:%S'), error, flush=True)
        if any(command.startswith(str(ENGINE) + '/') for _, command in running_servers()):
            seen, idle = True, None
        elif seen or time.time() - started > 600:
            idle = idle or time.time()
            if time.time() - idle > 15:
                break
        time.sleep(2)
    keep_segments(session)


def frame_records(session):
    """(present time in ms, present interval in ms) of every DXMT frame of the session, from its
    frame log segments and the copies `keep` saved, once each."""
    frames = {}
    for folder in (session, session / 'kept'):
        for path in sorted(folder.glob('frames-*.csv')):
            if '.events' in path.name:  # DXMT's event logs share the prefix and also carry unix_us
                continue
            with path.open(newline='') as stream:
                for row in csv.DictReader(stream):
                    try:
                        frames[int(row['unix_us'])] = int(row['present_interval_us']) / 1000
                    except (KeyError, TypeError, ValueError):
                        continue
    return sorted((stamp / 1000, interval) for stamp, interval in frames.items())


def frame_times(session):
    """Present timestamps (ms) from every DXMT frame log segment of the session."""
    return [stamp for stamp, _ in frame_records(session)]


def load_lines(session):
    lines = []
    for path in session.glob('input-*.jsonl'):
        for text in path.read_text().splitlines():
            try:
                line = json.loads(text)
            except json.JSONDecodeError:
                continue
            if line.get('exe', '').lower() == 'overwatch.exe':
                lines.append(line)
    return sorted(lines, key=lambda line: line['unix_ms'])


def line_windows(lines):
    """(start ms, end ms, line): the stretch of time each per-second line covers."""
    windows, previous = [], None
    for line in lines:
        end = line['unix_ms']
        start = previous if previous and end - previous <= 1500 else end - 1000
        previous = end
        windows.append((start, end, line))
    return windows


def classify(line, stretches=0):
    """(mode, motion) for a clean in-game second, or None. Raw input's mode carries its variant, or
    its timing for drivers before the variants; in a blind test only the stretches count."""
    if not line['app_active'] or not (line['hidden'] or line['transparent']):
        return None
    if line['mouselook_enters'] or line['mouselook_exits'] or line['switches']:
        return None
    if stretches and not 1 <= line.get('stretch', 0) <= stretches:
        return None
    motion = 'moving' if line['mac_moves'] >= MOVING else 'still' if line['mac_moves'] <= STILL else None
    mode = line['mode']
    if mode == 'raw' and (line.get('variant') or line.get('raw_timing')):
        mode = f'raw-{line.get("variant") or line["raw_timing"]}'
    return (mode, motion) if motion else None


def summary(rows):
    seconds = len(rows)
    per_call = [row['setpos_us'] / row['setpos_calls'] for row in rows if row['setpos_calls'] > row['setpos_fast']]
    fps = sorted(row['fps'] for row in rows)
    intervals = [interval for row in rows for interval in row.get('intervals', ())]
    delivered = sum(row['moves_delivered'] for row in rows)
    mac_motion = sum(row['mac_dx'] + row['mac_dy'] for row in rows)
    raw_motion = sum(row.get('raw_dx', 0) + row.get('raw_dy', 0) for row in rows)
    relative = sum(row.get('moved_relative', 0) for row in rows)
    counts_per_point = raw_motion / mac_motion if raw_motion and mac_motion else None
    unmatched = sum(row.get('pointer_unmatched_dx', 0) + row.get('pointer_unmatched_dy', 0) for row in rows)
    return {'seconds': seconds, 'median_fps': round(statistics.median(fps), 1),
            'low_fps_10th_percentile': round(fps[int(len(fps) * 0.1)], 1),
            # Frames of HITCH_MS or more, a minute, and the longest.
            'hitch_frames_per_minute': round(sum(i >= HITCH_MS for i in intervals) * 60 / seconds, 1),
            'worst_frame_ms': round(max(intervals), 1) if intervals else None,
            'mouse_events_per_second': round(statistics.mean(row['mac_moves'] for row in rows)),
            'raw_reports_per_second': round(statistics.mean(row.get('raw_moves', 0) for row in rows)),
            'raw_deliveries_per_second': round(statistics.mean(row.get('raw_posted', 0) for row in rows)),
            'pointer_fallback_per_second': round(statistics.mean(row.get('pointer_fallback', 0) for row in rows), 1),
            # Mouse counts per pointer-event point: the tracking speed's inverse when both carry the motion.
            'counts_per_point': round(counts_per_point, 3) if counts_per_point else None,
            'raw_counts': round(raw_motion),
            'delivered_counts': sum(row.get('moved_abs', 0) for row in rows),
            # How old a move's Windows event time was when Wine sent it to the game.
            'event_age_ms': round(sum(row.get('move_age_ms_avg', 0) * row.get('moved_relative', 0)
                                      for row in rows) / relative, 1) if relative else None,
            'event_age_max_ms': max((row.get('move_age_ms_max', 0) for row in rows), default=0),
            # Motion macOS reported while raw input had been silent for 50 ms, in mouse counts.
            'unmatched_pointer_events_per_second': round(statistics.mean(row.get('pointer_unmatched', 0)
                                                                         for row in rows), 2),
            'unmatched_counts': round(unmatched * counts_per_point) if counts_per_point else round(unmatched),
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


def after_mark(stamp, marks):
    """Whether a frame presented at `stamp` follows a mark closely enough to be the hotkey's doing."""
    index = bisect.bisect_right(marks, stamp)
    return index > 0 and stamp - marks[index - 1] <= MARK_GRACE_MS


def hitch_episodes(frames, marks):
    """When hitches start, as a player sees them: frames of HITCH_MS or more, merged while less than
    EPISODE_GAP_MS apart, leaving out frames just after a mark."""
    episodes, last = [], None
    for stamp, interval in frames:
        if interval < HITCH_MS or after_mark(stamp, marks):
            continue
        if last is None or stamp - last > EPISODE_GAP_MS:
            episodes.append(stamp)
        last = stamp
    return episodes


def rate_test(a, a_time, b, b_time):
    """Two-sided exact test that counts a (over a_time) and b (over b_time) come from one Poisson
    rate: given a + b events, a is binomial with the share of time a had."""
    n = a + b
    if not n or not a_time or not b_time:
        return 1.0
    share = a_time / (a_time + b_time)
    probabilities = [math.comb(n, k) * share ** k * (1 - share) ** (n - k) for k in range(n + 1)]
    observed = probabilities[a]
    return min(1.0, sum(p for p in probabilities if p <= observed * (1 + 1e-9)))


def percentile(values, share):
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * share))] if values else None


def blind_clean(line, stretches):
    """A second of a blind test's stretch with raw input on in the game, and no change in it."""
    return (line['app_active'] and (line['hidden'] or line['transparent']) and line['mode'] == 'raw' and
            not (line['mouselook_enters'] or line['mouselook_exits'] or line['switches']) and
            1 <= line.get('stretch', 0) <= stretches)


def blind_summary(seconds):
    """A variant's or a stretch's numbers from its clean seconds: (line, intervals, episodes, fps, marks)."""
    moving = [second for second in seconds if second['line']['mac_moves'] >= MOVING]
    frames = [interval for second in moving for interval in second['intervals']]
    lines = [second['line'] for second in seconds]

    def total(field):
        return sum(line.get(field, 0) for line in lines)

    def weighted(field, weight):
        weights = total(weight)
        return sum(line.get(field, 0) * line.get(weight, 0) for line in lines) / weights if weights else None

    minutes, aim_minutes = len(seconds) / 60, len(moving) / 60
    episodes = sum(second['episodes'] for second in moving)
    marks = sum(len(second['marks']) for second in seconds)
    matched = sum(second['matched'] for second in seconds)
    felt = sum(second['felt'] for second in moving)
    key_checks = total('key_checks')
    age = weighted('move_age_ms_avg', 'moved_relative')
    return {
        'seconds': len(seconds), 'moving_seconds': len(moving),
        # Hitches as the player sees them, while the mouse moved.
        'hitches': episodes,
        'hitches_per_minute': round(episodes / aim_minutes, 1) if moving else None,
        'hitch_frames_per_minute': round(sum(i >= HITCH_MS for i in frames) / aim_minutes, 1) if moving else None,
        'worst_frame_ms': round(max(frames), 1) if frames else None,
        'frame_time_sd_ms': round(statistics.pstdev(frames), 2) if len(frames) > 1 else None,
        'p99_frame_ms': round(percentile(frames, 0.99), 1) if frames else None,
        'median_fps': round(statistics.median(second['fps'] for second in moving), 1) if moving else None,
        'low_fps': round(percentile([second['fps'] for second in moving], 0.1), 1) if moving else None,
        # The player's marks: how many, how many came within MARK_MATCH_MS after a hitch, and the
        # share of hitches marked.
        'marks': marks, 'marks_per_minute': round(marks / minutes, 1) if seconds else None,
        'marks_after_a_hitch': matched,
        'hitches_marked_share': round(felt / episodes, 2) if episodes else None,
        'mouse_counts_per_second': round((total('raw_dx') + total('raw_dy')) / len(seconds)) if seconds else 0,
        # AppKit's clicks plus those raw input posted (precise, clicks).
        'clicks_per_minute': round((total('clicks') + total('raw_buttons')) / minutes, 1) if seconds else 0,
        # Each press and release, as GCMouse and AppKit reported it: how much later AppKit's copy came (the
        # path of today's clicks), and the GCMouse motion in between, which today's path gives the game
        # before the click. raw_buttons: posted by raw input; appkit_copies: AppKit copies then dropped;
        # appkit_buttons: posted by AppKit while raw buttons were on (raw input missed them).
        'click_gaps': total('click_gaps'),
        'click_gap_ms': round(weighted('click_gap_ms_avg', 'click_gaps'), 2)
        if weighted('click_gap_ms_avg', 'click_gaps') is not None else None,
        'click_gap_max_ms': round(max((line.get('click_gap_ms_max', 0) for line in lines), default=0), 1),
        'click_counts': round(weighted('click_counts_avg', 'click_gaps'), 1)
        if weighted('click_counts_avg', 'click_gaps') is not None else None,
        'click_counts_max': round(max((line.get('click_counts_max', 0) for line in lines), default=0), 1),
        'raw_buttons': total('raw_buttons'), 'appkit_copies': total('appkit_copies'),
        'appkit_buttons': total('appkit_buttons'), 'raw_button_repeats': total('raw_button_repeats'),
        'rearms': total('rearms'), 'inputs_replaced': total('inputs_replaced'),
        # From a GCMouse report to Wine sending its motion on, whatever the event time.
        'delivery_ms': round(weighted('delivery_ms_avg', 'moved_relative'), 3)
        if weighted('delivery_ms_avg', 'moved_relative') is not None else None,
        'delivery_max_ms': round(max((line.get('delivery_ms_max', 0) for line in lines), default=0), 1),
        'event_times': None if age is None else 'real' if age < 60_000 else 'stale',
        'event_age_ms': round(age, 1) if age is not None else None,
        'posts_per_100_reports': round(100 * total('raw_posted') / total('raw_moves'), 1) if total('raw_moves') else None,
        'counts_delivered_share': round(total('moved_abs') / (total('raw_dx') + total('raw_dy')), 4)
        if total('raw_dx') + total('raw_dy') else None,
        'pointer_fallback': total('pointer_fallback'), 'pointer_unmatched': total('pointer_unmatched'),
        # Key presses' input-method check, and every wait of Wine threads for the main thread.
        'key_checks_per_minute': round(key_checks / minutes, 1) if seconds else 0,
        'key_checks_cached_share': round(total('key_checks_cached') / key_checks, 2) if key_checks else None,
        'key_wait_ms_each': round(total('key_check_ms') / key_checks, 3) if key_checks else None,
        'key_wait_max_ms': round(max((line.get('key_check_max_ms', 0) for line in lines), default=0), 1),
        'key_query_ms_each': round(total('key_query_ms') / (key_checks - total('key_checks_cached')), 3)
        if key_checks > total('key_checks_cached') else None,
        'main_waits_per_minute': round(total('main_waits') / minutes, 1) if seconds else 0,
        'main_wait_ms_per_minute': round(total('main_wait_ms') / minutes, 1) if seconds else 0,
        'main_wait_max_ms': round(max((line.get('main_wait_max_ms', 0) for line in lines), default=0), 1),
        # How long the main thread took to start a request: what each such wait began with.
        'main_lag_ms': round(weighted('main_lag_ms_avg', 'main_lag_probes'), 3)
        if weighted('main_lag_ms_avg', 'main_lag_probes') is not None else None,
        'main_lag_max_ms': round(max((line.get('main_lag_ms_max', 0) for line in lines), default=0), 1),
        'main_lag_over_16ms_per_minute': round(total('main_lag_over_16ms') / minutes, 1) if seconds else 0,
    }


def verdict(p):
    return 'clear' if p < 0.01 else 'likely' if p < 0.05 else 'unclear'


def blind_report(lines, frames, marks, blind):
    """The blind test's variants and stretches. Hitches count while the mouse moved; marks anywhere
    in a stretch."""
    stretches = len(blind['sequence'])
    stamps = [stamp for stamp, _ in frames]
    hitch_stamps = [stamp for stamp, interval in frames if interval >= HITCH_MS and not after_mark(stamp, marks)]
    episodes = hitch_episodes(frames, marks)
    t0 = lines[0]['unix_ms']
    by_variant, by_stretch = {}, {}
    for start, end, line in line_windows(lines):
        if not blind_clean(line, stretches):
            continue
        low, high = bisect.bisect_right(stamps, start), bisect.bisect_right(stamps, end)
        if high == low:
            continue
        second_marks = [mark for mark in line.get('marks_ms', ())]
        second_episodes = episodes[bisect.bisect_right(episodes, start):bisect.bisect_right(episodes, end)]
        second = {
            'line': line, 'fps': (high - low) * 1000 / (end - start),
            'intervals': [interval for stamp, interval in frames[low:high] if not after_mark(stamp, marks)],
            'episodes': len(second_episodes), 'marks': second_marks,
            'matched': sum(bisect.bisect_right(hitch_stamps, mark) > bisect.bisect_left(hitch_stamps, mark - MARK_MATCH_MS)
                           for mark in second_marks),
            'felt': sum(bisect.bisect_right(marks, episode + MARK_MATCH_MS) > bisect.bisect_left(marks, episode)
                        for episode in second_episodes)}
        by_variant.setdefault(line['variant'], []).append(second)
        stretch = by_stretch.setdefault(line['stretch'], {'variant': line['variant'], 'start_s': (start - t0) / 1000,
                                                          'seconds': []})
        stretch['seconds'].append(second)
    variants = {name: blind_summary(seconds) for name, seconds in sorted(by_variant.items(),
                                                                         key=lambda item: list(VARIANTS).index(item[0])
                                                                         if item[0] in VARIANTS else 99)}
    comparisons = {}
    base = variants.get('legacy')
    for name, row in variants.items():
        if name == 'legacy' or not base or not row['moving_seconds'] or not base['moving_seconds']:
            continue
        p = rate_test(row['hitches'], row['moving_seconds'], base['hitches'], base['moving_seconds'])
        rate, base_rate = row['hitches'] / row['moving_seconds'], base['hitches'] / base['moving_seconds']
        comparisons[name] = {'hitch_rate_ratio': round(rate / base_rate, 2) if base_rate else None,
                             'p_value': round(p, 4), 'verdict': verdict(p),
                             'direction': 'more' if rate > base_rate else 'fewer' if rate < base_rate else 'same'}
    stretch_rows = []
    for number, stretch in sorted(by_stretch.items()):
        row = blind_summary(stretch['seconds'])
        stretch_rows.append({'stretch': number, 'variant': stretch['variant'], 'start_s': round(stretch['start_s']),
                             **{key: row[key] for key in ('seconds', 'moving_seconds', 'hitches', 'hitches_per_minute',
                                                          'worst_frame_ms', 'median_fps', 'marks')}})
    ranked = sorted((name for name in variants if variants[name]['hitches_per_minute'] is not None),
                    key=lambda name: variants[name]['hitches_per_minute'])
    return {'sequence': blind['sequence'], 'stretch_s': blind['stretch_s'], 'warmup_s': blind['warmup_s'],
            'stretches_played': len(by_stretch), 'marks_in_session': len(marks),
            'hitch_ms': HITCH_MS, 'variants': variants, 'compared_with_legacy': comparisons,
            'smoothest_first': ranked, 'stretches': stretch_rows}


def print_blind(result):
    blind = result['blind']
    print(f'\nBlind test: {blind["stretches_played"]} of {len(blind["sequence"])} stretches played. '
          f'The versions, revealed (hitches: frames of {HITCH_MS:.0f} ms or more while aiming, close ones as one):')
    print(f'{"version":28} {"hitches/min":>11} {"worst ms":>8} {"FPS":>6} {"marks/min":>9}  vs today\'s Recall')
    for name, row in blind['variants'].items():
        comparison = blind['compared_with_legacy'].get(name)
        against = '-' if not comparison else (
            f'{comparison["hitch_rate_ratio"]}x as many hitches ({comparison["verdict"]})'
            if comparison['hitch_rate_ratio'] is not None else f'{comparison["direction"]} ({comparison["verdict"]})')
        print(f'{VARIANTS.get(name, name):28} {row["hitches_per_minute"] if row["hitches_per_minute"] is not None else "-":>11} '
              f'{round(row["worst_frame_ms"]) if row["worst_frame_ms"] else "-":>8} '
              f'{round(row["median_fps"]) if row["median_fps"] else "-":>6} {row["marks_per_minute"] or 0:>9}  {against}')
    print(blind_headline(blind))
    rows = blind['variants'].values()
    marks = sum(row['marks'] for row in rows)
    if marks:
        print(f'Your marks in the stretches: {marks}; {sum(row["marks_after_a_hitch"] for row in rows)} came within '
              f'{MARK_MATCH_MS // 1000} s after a measured hitch.')
    print('\nStretch  version                       start  aiming s  hitches/min  marks')
    for row in blind['stretches']:
        print(f'{row["stretch"]:>7}  {VARIANTS.get(row["variant"], row["variant"]):28} '
              f'{row["start_s"] // 60:>3}:{row["start_s"] % 60:02d}  {row["moving_seconds"]:>8}  '
              f'{row["hitches_per_minute"] if row["hitches_per_minute"] is not None else "-":>11}  {row["marks"]:>5}')
    print('\nUnder the hood: delivery ms (report to Wine, average/worst), event times, posts per 100 reports, '
          'key checks a minute (wait ms each, worst), main-thread lag ms (average/worst)')
    for name, row in blind['variants'].items():
        print(f'  {name:8} {row["delivery_ms"]}/{row["delivery_max_ms"]}  {row["event_times"]}  '
              f'{row["posts_per_100_reports"]}  {row["key_checks_per_minute"]} ({row["key_wait_ms_each"]}, '
              f'{row["key_wait_max_ms"]})  {row["main_lag_ms"]}/{row["main_lag_max_ms"]}')
    print('\nClicks: presses and releases seen on both paths, AppKit\'s copy later by ms (average/worst), GCMouse '
          'counts in between (average/worst); posted by raw input, AppKit copies dropped, posted by AppKit')
    for name, row in blind['variants'].items():
        print(f'  {name:8} {row["click_gaps"]}  {row["click_gap_ms"]}/{row["click_gap_max_ms"]} ms  '
              f'{row["click_counts"]}/{row["click_counts_max"]} counts  {row["raw_buttons"]} / '
              f'{row["appkit_copies"]} / {row["appkit_buttons"]}')


def blind_headline(blind):
    """One plain sentence: which versions beat today's Recall, which did worse, which were alike."""
    groups = {'better': [], 'worse': [], 'alike': []}
    for name, comparison in blind['compared_with_legacy'].items():
        if comparison['verdict'] == 'unclear' or comparison['direction'] == 'same':
            groups['alike'].append(VARIANTS.get(name, name))
        else:
            groups['better' if comparison['direction'] == 'fewer' else 'worse'].append(
                f'{VARIANTS.get(name, name)}{"" if comparison["verdict"] == "clear" else " (likely)"}')
    parts = []
    if groups['better']:
        parts.append('Fewer hitches than today\'s Recall: ' + ', '.join(groups['better']) + '.')
    if groups['worse']:
        parts.append('More hitches: ' + ', '.join(groups['worse']) + '.')
    if groups['alike']:
        parts.append('No clear difference: ' + ', '.join(groups['alike']) + '.')
    return ' '.join(parts) or 'Not enough aiming to compare the versions.'


def write_html(session, result, lines, frames, marks):
    """report.html: the blind test's results, a timeline of each second's longest frame by version,
    and the stretches. Self-contained."""
    blind = result['blind']
    stretches = len(blind['sequence'])
    windows = [(start, end, line) for start, end, line in line_windows(lines) if line['mode'] == 'raw']
    if not windows:
        return None
    stamps = [stamp for stamp, _ in frames]
    t0, t1 = windows[0][0], windows[-1][1]
    width, height, left, top, bottom = 960, 220, 34, 22, 26
    plot_w, plot_h, cap = width - left - 8, height - top - bottom, 60.0

    def x(ms):
        return left + (ms - t0) / max(1, t1 - t0) * plot_w

    def y(value):
        return top + plot_h - min(value, cap) / cap * plot_h

    svg = [f'<svg viewBox="0 0 {width} {height}" role="img" aria-label="Longest frame each second">']
    for number in range(1, stretches + 1):
        span = [(start, end, line) for start, end, line in windows if line.get('stretch') == number]
        if not span:
            continue
        variant = span[-1][2]['variant']
        a, b = x(span[0][0]), x(span[-1][1])
        svg.append(f'<rect x="{a:.1f}" y="{top}" width="{max(0.5, b - a):.1f}" height="{plot_h}" '
                   f'fill="{COLOURS.get(variant, "#999")}" opacity="0.10"/>')
        svg.append(f'<text x="{(a + b) / 2:.1f}" y="{top - 7}" class="label">{number}</text>')
    for value in (15, 30, 45, 60):
        svg.append(f'<line x1="{left}" x2="{left + plot_w}" y1="{y(value):.1f}" y2="{y(value):.1f}" '
                   f'class="{"hitch" if value == 15 else "grid"}"/>')
        svg.append(f'<text x="{left - 5}" y="{y(value) + 3:.1f}" class="axis" text-anchor="end">{value}</text>')
    bar = max(0.6, plot_w / max(1, len(windows)) - 0.3)
    for start, end, line in windows:
        low, high = bisect.bisect_right(stamps, start), bisect.bisect_right(stamps, end)
        if high == low:
            continue
        worst = max(interval for _, interval in frames[low:high])
        colour = COLOURS.get(line.get('variant'), '#999') if blind_clean(line, stretches) else 'var(--muted)'
        svg.append(f'<rect x="{x(start):.1f}" y="{y(worst):.1f}" width="{bar:.1f}" height="{top + plot_h - y(worst):.1f}" '
                   f'fill="{colour}"/>')
    for mark in marks:
        if t0 <= mark <= t1:
            svg.append(f'<path d="M{x(mark) - 4:.1f},{top + plot_h + 4} l4,-7 l4,7 z" class="mark"/>')
    minutes = int((t1 - t0) / 60000)
    for minute in range(0, minutes + 1, max(1, minutes // 8 or 1)):
        svg.append(f'<text x="{x(t0 + minute * 60000):.1f}" y="{height - 6}" class="axis" '
                   f'text-anchor="middle">{minute} min</text>')
    svg.append('</svg>')

    def cell(value, suffix='', whole=False):
        if value is None:
            return '–'
        return f'{round(value) if whole else value}{suffix}'

    rows = []
    for name, row in blind['variants'].items():
        comparison = blind['compared_with_legacy'].get(name)
        if not comparison:
            against = 'the baseline'
        elif comparison['hitch_rate_ratio'] is None:
            against = f'{comparison["direction"]} hitches ({comparison["verdict"]})'
        else:
            against = f'{comparison["hitch_rate_ratio"]}× the hitches ({comparison["verdict"]})'
        rows.append(f'<tr><td><span class="chip" style="background:{COLOURS.get(name, "#999")}"></span>'
                    f'{html.escape(VARIANTS.get(name, name))}</td><td>{cell(row["hitches_per_minute"])}</td>'
                    f'<td>{cell(row["worst_frame_ms"], " ms", True)}</td><td>{cell(row["median_fps"], "", True)}</td>'
                    f'<td>{cell(row["marks_per_minute"])}</td><td>{html.escape(against)}</td></tr>')
    stretch_rows = ''.join(
        f'<tr><td>{row["stretch"]}</td><td><span class="chip" style="background:{COLOURS.get(row["variant"], "#999")}">'
        f'</span>{html.escape(VARIANTS.get(row["variant"], row["variant"]))}</td>'
        f'<td>{row["start_s"] // 60}:{row["start_s"] % 60:02d}</td><td>{row["moving_seconds"]} s</td>'
        f'<td>{cell(row["hitches_per_minute"])}</td><td>{row["marks"]}</td></tr>' for row in blind['stretches'])
    hood = ''.join(
        f'<tr><td>{html.escape(VARIANTS.get(name, name))}</td><td>{cell(row["delivery_ms"], " ms")}</td>'
        f'<td>{cell(row["event_times"])}</td><td>{cell(row["key_checks_per_minute"])}</td>'
        f'<td>{cell(row["key_wait_ms_each"], " ms")} / {cell(row["key_wait_max_ms"], " ms")}</td>'
        f'<td>{cell(row["main_lag_ms"], " ms")} / {cell(row["main_lag_max_ms"], " ms")}</td></tr>'
        for name, row in blind['variants'].items())
    headline = html.escape(blind_headline(blind))
    rows_all = blind['variants'].values()
    marks = sum(row['marks'] for row in rows_all)
    hitches = sum(row['hitches'] for row in rows_all)
    felt = sum(round((row['hitches_marked_share'] or 0) * row['hitches']) for row in rows_all)
    perception = (f'You marked {marks} times in the stretches; {sum(row["marks_after_a_hitch"] for row in rows_all)} '
                  f'of those came within {MARK_MATCH_MS // 1000} s after a measured hitch, and you marked {felt} of the '
                  f'{hitches} hitches measured while you were aiming.' if marks else
                  'You made no marks in the stretches.')
    if not any(row['key_checks_per_minute'] for row in rows_all):
        perception += (' Overwatch never ran the key-press check while you played, so “No key-press wait” '
                       'could not differ from today\'s Recall.')
    page = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Blind mouse test</title>
<style>
:root {{ --bg: #ffffff; --fg: #1d1d1f; --muted: #d1d1d6; --soft: #6e6e73; --line: #e5e5ea; --base: #3a3a3c; }}
@media (prefers-color-scheme: dark) {{ :root {{ --bg: #1c1c1e; --fg: #f5f5f7; --muted: #48484a; --soft: #98989d; --line: #38383a; --base: #e5e5ea; }} }}
body {{ margin: 0; background: var(--bg); color: var(--fg); font: 15px/1.5 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }}
main {{ max-width: 980px; margin: 0 auto; padding: 32px 16px 48px; }}
h1 {{ font-size: 28px; margin: 0 0 4px; }} h2 {{ font-size: 18px; margin: 36px 0 8px; }}
p {{ margin: 6px 0; }} .soft {{ color: var(--soft); }}
table {{ width: 100%; border-collapse: collapse; margin-top: 8px; font-variant-numeric: tabular-nums; }}
th, td {{ text-align: left; padding: 8px 10px 8px 0; border-bottom: 1px solid var(--line); vertical-align: top; }}
th {{ font-weight: 600; color: var(--soft); font-size: 13px; }}
.chip {{ display: inline-block; width: 10px; height: 10px; border-radius: 3px; margin-right: 8px; }}
.scroll {{ overflow-x: auto; }}
svg {{ width: 100%; height: auto; margin-top: 8px; }}
svg .axis, svg .label {{ fill: var(--soft); font-size: 11px; }} svg .label {{ text-anchor: middle; }}
svg .grid {{ stroke: var(--line); }} svg .hitch {{ stroke: var(--soft); stroke-dasharray: 4 3; }}
svg .mark {{ fill: var(--fg); }}
</style></head><body><main>
<h1>Blind mouse test</h1>
<p class="soft">Session {html.escape(Path(session).name)} · {blind["stretches_played"]} stretches of {blind["stretch_s"]} s,
each version twice, in an order you didn't know.</p>
<p>{headline}</p>
<p>{html.escape(perception)}</p>
<h2>Results</h2>
<p class="soft">A hitch is a frame of {HITCH_MS:.0f} ms or longer while you were moving the mouse (normal frames are about 7 ms);
hitches less than {EPISODE_GAP_MS} ms apart count as one. “Clear” means chance would produce a gap that large
less than 1 time in 100, “likely” less than 1 in 20.</p>
<div class="scroll"><table><tr><th>Version</th><th>Hitches a minute</th><th>Worst</th><th>FPS</th>
<th>Your marks a minute</th><th>Compared with today's Recall</th></tr>{"".join(rows)}</table></div>
<h2>Timeline</h2>
<p class="soft">The longest frame in each second, coloured by the version running (grey: warm-up, menus and the seconds
when a version changed). Triangles are your “felt it” marks. The dashed line is {HITCH_MS:.0f} ms.</p>
{"".join(svg)}
<h2>Stretches</h2>
<div class="scroll"><table><tr><th>#</th><th>Version</th><th>Started</th><th>Aiming</th><th>Hitches a minute</th>
<th>Marks</th></tr>{stretch_rows}</table></div>
<h2>Under the hood</h2>
<p class="soft">Delivery: from the mouse's report to Wine handing the motion to the game. Key checks: the input-method
check on every key press and release, and how long the game waited for it. Main-thread lag: how long macOS's main
thread took to answer a request.</p>
<div class="scroll"><table><tr><th>Version</th><th>Delivery</th><th>Event times</th><th>Key checks a minute</th>
<th>Key wait (average / worst)</th><th>Main-thread lag (average / worst)</th></tr>{hood}</table></div>
</main></body></html>
'''
    path = Path(session) / 'report.html'
    path.write_text(page)
    return path


def report(args):
    session = Path(args.session) if args.session else max(LOGS.glob('2*'), default=None)
    if not session or not session.is_dir():
        raise SystemExit('No mouselook session found.')
    lines = load_lines(session)
    frames = frame_records(session)
    if not lines or not frames:
        raise SystemExit(f'{session} has no Overwatch input statistics or frame timing yet.')
    record = json.loads((session / 'session.json').read_text()) if (session / 'session.json').is_file() else {}
    blind = record.get('blind')
    stretches = len(blind['sequence']) if blind else 0
    stamps = [stamp for stamp, _ in frames]
    marks = sorted(mark for line in lines for mark in line.get('marks_ms', ()))

    groups = {}
    for start, end, line in line_windows(lines):
        low, high = bisect.bisect_right(stamps, start), bisect.bisect_right(stamps, end)
        key = classify(line, stretches)
        if key and high > low:
            intervals = [interval for stamp, interval in frames[low:high] if not after_mark(stamp, marks)]
            groups.setdefault(key, []).append(dict(line, fps=(high - low) * 1000 / (end - start), intervals=intervals))

    result = {'session': str(session), 'peak_mouse_events_per_second': max(line['mac_moves'] for line in lines),
              'modes': {f'{mode}/{motion}': summary(rows) for (mode, motion), rows in sorted(groups.items())
                        if len(rows) >= 3}}
    for mode in sorted({mode for mode, _ in groups}):
        still, moving = result['modes'].get(f'{mode}/still'), result['modes'].get(f'{mode}/moving')
        if still and moving:
            result[f'{mode}_fps_drop_while_moving_percent'] = round(
                100 * (1 - moving['median_fps'] / still['median_fps']), 1)
    seen = {'hid_cursor': any(line['hidden'] for line in lines),
            'transparent_cursor': any(line['transparent'] for line in lines),
            'confined_cursor': any(line['clipping'] for line in lines),
            're_centred_cursor': any(line['setpos_calls'] for line in lines),
            'mouselook_engaged': any(line['mode'] in ('mouselook', 'raw') for line in lines),
            'raw_input_engaged': any(line['mode'] == 'raw' for line in lines),
            'mouselook_exits': sum(line['mouselook_exits'] for line in lines),
            'most_raw_sources_in_a_second': max((line.get('raw_sources', 0) for line in lines), default=0)}
    # Every count raw input posted reaches Wine once, merged or not; the sums agree but for moves
    # still queued when the session ended.
    if any('moved_x' in line for line in lines):
        result['pipeline'] = {'posted_x': sum(line.get('raw_posted_x', 0) for line in lines),
                              'posted_y': sum(line.get('raw_posted_y', 0) for line in lines),
                              'delivered_x': sum(line.get('moved_x', 0) for line in lines),
                              'delivered_y': sum(line.get('moved_y', 0) for line in lines)}
    result['raw_mice'] = max((line.get('raw_mice', 0) for line in lines), default=0)
    result['game_behaviour'] = seen
    if blind and any(line.get('stretch') for line in lines):
        result['blind'] = blind_report(lines, frames, marks, blind)
    (session / 'report.json').write_text(json.dumps(result, indent=2) + '\n')

    print(f'Session {session.name}; peak mouse events per second: {result["peak_mouse_events_per_second"]}')
    print('Game: ' + ', '.join(f'{k.replace("_", " ")}={v if not isinstance(v, bool) else "yes" if v else "no"}'
                               for k, v in seen.items()))
    print(f'{"mode/mouse":20} {"secs":>5} {"FPS":>6} {"low":>6} {"hitch/min":>9} {"worst":>6} {"raw/s":>6} '
          f'{"delivered/s":>11} {"event age ms":>12} {"fallback/s":>10} {"unmatched":>9}')
    for name, row in result['modes'].items():
        age = '-' if row['event_age_ms'] is None else f'{row["event_age_ms"]:.0f}'
        print(f'{name:20} {row["seconds"]:>5} {row["median_fps"]:>6} {row["low_fps_10th_percentile"]:>6} '
              f'{row["hitch_frames_per_minute"]:>9} {row["worst_frame_ms"] or "-":>6} {row["raw_reports_per_second"]:>6} '
              f'{row["moves_delivered_per_second"]:>11} {age:>12} {row["pointer_fallback_per_second"]:>10} '
              f'{row["unmatched_counts"]:>9}')
    for name, row in result['modes'].items():
        if name.startswith('raw') and name.endswith('/moving'):
            print(f'{name}: {result["raw_mice"]} mice seen; {row["counts_per_point"]} mouse counts per pointer point; '
                  f'{row["raw_counts"]} counts reported, {row["delivered_counts"]} delivered; each delivery cost the '
                  f'game thread {row["delivery_us_each"]} us.')
    if 'pipeline' in result:
        p = result['pipeline']
        print(f'Raw input posted {p["posted_x"]},{p["posted_y"]} counts in all; Wine sent on {p["delivered_x"]},'
              f'{p["delivered_y"]}.')
    for mode in sorted({mode for mode, _ in groups}):
        if f'{mode}_fps_drop_while_moving_percent' in result:
            print(f'{mode}: FPS drop while moving {result[f"{mode}_fps_drop_while_moving_percent"]}%')
    if 'blind' in result:
        print_blind(result)
        page = write_html(session, result, lines, frames, marks)
        if page:
            print(f'Report page: {page}')
    print(f'Full report: {session / "report.json"}')


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest='command', required=True)
    commands.add_parser('prepare', help='Create or refresh the test engine')
    launch = commands.add_parser('play', help='Start a play-test session')
    launch.add_argument('--stop-running', action='store_true', help='Close a running Battle.net session first')
    switches = launch.add_mutually_exclusive_group()
    switches.add_argument('--blind', action='store_true',
                          help='The blind input test: every input variant twice, in a random order')
    switches.add_argument('--timing-switch', action='store_true',
                          help='The test hotkey switches between the legacy and fixed input variants')
    switches.add_argument('--raw-switch', action='store_true', help='The test hotkey switches raw input off and on')
    launch.add_argument('--variant', choices=list(VARIANTS),
                        help="Start with this input variant (default: the players' one, from the launch settings)")
    launch.add_argument('--blind-variants', help='Comma-separated variants for --blind (default: all)')
    launch.add_argument('--stretch-seconds', type=int, default=BLIND_STRETCH_S,
                        help=f'Seconds of aiming per blind stretch (default {BLIND_STRETCH_S})')
    launch.add_argument('--warmup-seconds', type=int, default=BLIND_WARMUP_S,
                        help=f'Seconds of aiming before the first blind stretch (default {BLIND_WARMUP_S})')
    launch.add_argument('--raw-off', action='store_true',
                        help='Mouselook from pointer events only, without raw input')
    launch.add_argument('--raw-interval-us', type=int, default=None,
                        help='Minimum time between raw input deliveries in microseconds (default 1000; 0 = every report)')
    launch.add_argument('--trace-rawinput', action='store_true',
                        help="Log Wine's raw input calls: which thread reads the mouse, how and how often")
    launch.add_argument('--display-log', action='store_true',
                        help='Log when each frame was requested and when it reached the screen')
    keeper = commands.add_parser('keep', help="Save a session's rotated frame log segments until it ends")
    keeper.add_argument('session')
    keeper.add_argument('--hours', type=float, default=4)
    summary_parser = commands.add_parser('report', help='Summarise a play-test session')
    summary_parser.add_argument('session', nargs='?', help='Session directory (default: latest)')
    args = parser.parse_args()
    if args.command == 'prepare':
        print(json.dumps(prepare(), indent=2))
    elif args.command == 'play':
        play(args)
    elif args.command == 'keep':
        keep(args)
    else:
        report(args)


if __name__ == '__main__':
    main()
