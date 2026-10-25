#!/usr/bin/env python3
"""Live display-mode session (REC-45): Overwatch from the mouselook test engine, with the logs
that show where its picture lands and how fast frames reach the screen.

  start [--mode fullscreen|windowed|borderless]
          Starts Overwatch as scripts/mouselook_session.py play does (the installed Recall
          environment, the app's launch settings, the test engine with the driver from
          `build_wine_native.py winemac`), plus DXMT_CANVAS_LOG, DXMT_WINDOW_LOG,
          DXMT_GEOMETRY_LOG and DXMT_DISPLAY_LOG under logs/display-modes/live-<stamp>.
          --mode first writes that display mode into the game's settings (Overwatch's
          own keys, see MODES). The Recall app may stay open; a running game or
          Battle.net may not.
  play                   Hands "launch Overwatch" to the running Battle.net, as the app does
                         (Battle.net ignores the command at its own start).
  inspect                The game window's geometry as Wine has it (display_probe.exe).
  click X Y              A left click at client coordinates, sent inside Wine.
  key VK[+VK...]         Keys (hexadecimal virtual-key codes), sent inside Wine.
                         These three take --app Battle.net.exe for the launcher.
  shot NAME [--display N]  A screenshot of display N (1 = main) into the session folder.
  wshot NAME             A screenshot of the game's client area only, with the factor that turns
                         its pixels into the client coordinates click takes.
  settings               The display keys in the game's settings file.
Never quits a match; the player ends the session in the game.
"""
import argparse
import datetime
import json
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import candidate_contract  # noqa: E402
import mouselook_session as session_tool  # noqa: E402
import run as probe_run  # noqa: E402

LOGS = ROOT / 'logs/display-modes'
SETTINGS = session_tool.APP_ROOT / 'environment/drive_c/users/crossover/Documents/Overwatch/Settings/Settings_v0.ini'
# Overwatch's [Render.13] keys for each display mode, as the game saved them on 2026-10-22.
MODES = {
    'fullscreen': {'WindowMode': '0', 'FullscreenWindow': '0', 'FullscreenWindowEnabled': '0', 'WindowedFullscreen': '0'},
    'borderless': {'WindowMode': '1', 'FullscreenWindow': '0', 'FullscreenWindowEnabled': '0', 'WindowedFullscreen': '1'},
    'windowed': {'WindowMode': '2', 'FullscreenWindow': '0', 'FullscreenWindowEnabled': '0', 'WindowedFullscreen': '0'},
}
DISPLAY_KEYS = ('WindowMode', 'FullscreenWindow', 'FullscreenWindowEnabled', 'WindowedFullscreen', 'FullScreenWidth',
                'FullScreenHeight', 'FullScreenRefresh', 'WindowedWidth', 'WindowedHeight', 'WindowedPosX', 'WindowedPosY',
                'WindowedRefresh', 'RenderScale', 'CustomRenderScale', 'UseCustomRenderScale', 'DynamicRenderScale')


def latest_session():
    found = sorted(LOGS.glob('live-*'))
    if not found:
        raise SystemExit('No live session yet: run start first.')
    return found[-1]


def settings_lines():
    return SETTINGS.read_bytes().decode('utf-8').split('\n')


def display_settings():
    values = {}
    section = None
    for raw in settings_lines():
        line = raw.strip()
        if line.startswith('['):
            section = line
            continue
        if section == '[Render.13]' and '=' in line:
            key, value = (part.strip() for part in line.split('=', 1))
            if key in DISPLAY_KEYS:
                values[key] = value.strip('"')
    return values


def write_mode(mode):
    text = SETTINGS.read_bytes().decode('utf-8')
    newline = '\r\n' if '\r\n' in text else '\n'
    lines = text.split(newline)
    start = next(i for i, line in enumerate(lines) if line.strip() == '[Render.13]') + 1
    end = next((i for i in range(start, len(lines)) if lines[i].strip().startswith('[')), len(lines))
    for key, value in MODES[mode].items():
        found = [i for i in range(start, end) if lines[i].split('=')[0].strip() == key]
        line = f'{key} = "{value}"'
        if found:
            lines[found[0]] = line
        else:
            lines.insert(end, line)
            end += 1
    SETTINGS.write_bytes(newline.join(lines).encode('utf-8'))


def session_settings(session):
    """The app's launch settings as this session started them (start --game-mode overrides)."""
    record = session / 'session.json'
    if record.is_file():
        return json.loads(record.read_text())['app_settings']
    return session_tool.app_settings()


def set_retina(enabled):
    """Wine's Retina mode for the next session, as the worker writes it (portable_retina.h).
    The app's next launch writes its own value again."""
    env = session_tool.environment(LOGS, session_tool.app_settings())
    value = 'Y' if enabled else 'N'
    subprocess.run([str(session_tool.ENGINE / 'bin/wine'), 'reg.exe', 'add', r'HKCU\Software\Wine\Mac Driver', '/v',
                    'RetinaMode', '/d', value, '/f'], env=env, capture_output=True, timeout=120)
    subprocess.run([str(session_tool.ENGINE / 'bin/wineserver'), '-w'], env=env, timeout=120)
    text = (session_tool.APP_ROOT / 'environment/user.reg').read_text(errors='replace')
    if f'"RetinaMode"="{value}"' not in text:
        raise SystemExit('Retina mode was not written')


def environment(session):
    env = session_tool.environment(session, session_settings(session), display_log=True)
    env.update(DXMT_CANVAS_LOG=str(session / 'canvas'),
               DXMT_WINDOW_LOG=session_tool.windows_path(session / 'window'),
               DXMT_GEOMETRY_LOG=session_tool.windows_path(session / 'geometry'))
    return env


def start(args):
    processes = list(session_tool.processes())
    if session_tool.running_servers() or any(c.endswith(('Overwatch.exe', 'Battle.net.exe')) for _, c in processes):
        raise SystemExit('A Recall session is running. Quit the game and Battle.net first.')
    runtime = session_tool.prepare()
    probe_run.prepare_probe_only()
    if args.mode:
        write_mode(args.mode)
    if args.retina:
        set_retina(args.retina == 'on')
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    session = LOGS / f'live-{stamp}'
    session.mkdir(parents=True)
    settings = session_tool.app_settings()
    if args.game_mode:
        settings['game_mode'] = args.game_mode == 'on'
    retina = '"RetinaMode"="Y"' in (session_tool.APP_ROOT / 'environment/user.reg').read_text(errors='replace')
    record = dict(runtime, started=stamp, mode=args.mode, app_settings=settings, retina_mode=retina,
                  settings_before=display_settings(), contract_profile=candidate_contract.load()['profile'])
    (session / 'session.json').write_text(json.dumps(record, indent=2) + '\n')
    env = environment(session)
    subprocess.Popen(['/usr/bin/log', 'stream', '--style', 'compact', '--predicate', 'subsystem == "com.apple.gamepolicyd"'],
                     stdout=(session / 'gamepolicy.log').open('w'), stderr=subprocess.STDOUT, start_new_session=True)
    with (session / 'battlenet.log').open('w') as log:
        subprocess.Popen([str(session_tool.ENGINE / 'bin/wine'), str(session_tool.APP_ROOT / 'environment' / session_tool.CLIENT),
                          *session_tool.CLIENT_ARGS], env=env, cwd=session_tool.APP_ROOT, stdin=subprocess.DEVNULL,
                         stdout=log, stderr=log, start_new_session=True)
    with (session / 'battlenet-closer.log').open('w') as log:
        subprocess.Popen([sys.executable, str(ROOT / 'scripts/battlenet_closer.py'), '--engine', str(session_tool.ENGINE),
                          '--prefix', str(session_tool.APP_ROOT / 'environment'), '--grace-seconds', '25',
                          '--log', str(session / 'battlenet-closer.json')],
                         cwd=ROOT, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    with (session / 'keeper.log').open('w') as log:
        subprocess.Popen([sys.executable, str(ROOT / 'scripts/mouselook_session.py'), 'keep', str(session)],
                         cwd=ROOT, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    print(json.dumps({'session': str(session), 'driver_sha256': runtime['driver_sha256'], 'mode': args.mode,
                      'game_mode': settings['game_mode'], 'retina_mode': retina, 'settings': record['settings_before']}, indent=2))


def play():
    session = latest_session()
    with (session / 'battlenet-play.log').open('a') as log:
        subprocess.Popen([str(session_tool.ENGINE / 'bin/wine'), str(session_tool.APP_ROOT / 'environment' / session_tool.CLIENT),
                          *session_tool.CLIENT_ARGS], env=environment(session), cwd=session_tool.APP_ROOT,
                         stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    print(json.dumps({'play': str(session)}))


def probe(args_list, session=None):
    session = session or latest_session()
    result = subprocess.run([str(session_tool.ENGINE / 'bin/wine'), str(probe_run.EXE), *args_list],
                            env=environment(session), capture_output=True, text=True, timeout=60)
    return result.returncode, result.stdout, result.stderr


def game_pid():
    for pid, command in session_tool.processes():
        if command.endswith('Overwatch.exe'):
            return pid
    raise SystemExit('Overwatch is not running.')


def window_shot(name):
    """The game's client area: its largest on-screen window less the title bar, which is what
    Wine's client rectangle covers (two Wine pixels a point in Retina mode)."""
    code, out, err = probe(['inspect', 'Overwatch.exe'])
    wine = json.loads(out.splitlines()[0])
    probe_run.prepare_probe_only()
    bounds = probe_run.window_bounds(game_pid())
    x, y, w, h = bounds
    client_w, client_h = wine['client'][0] / 2, wine['client'][1] / 2
    title = max(0, h - client_h)
    rect = [x, y + title, w, h - title]
    path = latest_session() / f'{name}.png'
    subprocess.run(['/usr/sbin/screencapture', '-x', f'-R{rect[0]},{rect[1]},{rect[2]},{rect[3]}', str(path)], check=True)
    width = int(subprocess.run(['/usr/bin/sips', '-g', 'pixelWidth', str(path)], capture_output=True, text=True)
                .stdout.split()[-1])
    print(json.dumps({'shot': str(path), 'window_pt': bounds, 'client_wine': wine['client'],
                      'client_per_shot_px': round(wine['client'][0] / width, 4)}))


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    p = sub.add_parser('start')
    p.add_argument('--mode', choices=sorted(MODES))
    p.add_argument('--game-mode', choices=['on', 'off'], help="Override the app's Game Mode setting for this session")
    p.add_argument('--retina', choices=['on', 'off'], help="Write Wine's Retina mode before the session")
    sub.add_parser('play')
    p = sub.add_parser('inspect')
    p.add_argument('--app', default='Overwatch.exe')
    p = sub.add_parser('click')
    p.add_argument('--app', default='Overwatch.exe')
    p.add_argument('x', type=int)
    p.add_argument('y', type=int)
    p = sub.add_parser('key')
    p.add_argument('--app', default='Overwatch.exe')
    p.add_argument('keys')
    p = sub.add_parser('shot')
    p.add_argument('name')
    p.add_argument('--display', type=int, default=1)
    p = sub.add_parser('wshot')
    p.add_argument('name')
    sub.add_parser('settings')
    args = parser.parse_args()
    if args.command == 'start':
        start(args)
    elif args.command == 'play':
        play()
    elif args.command == 'inspect':
        code, out, err = probe(['inspect', args.app])
        print(out.strip() or err.strip())
        sys.exit(code)
    elif args.command == 'click':
        code, out, err = probe(['click', args.app, str(args.x), str(args.y)])
        print(json.dumps({'click': [args.x, args.y], 'status': code, 'error': err.strip()}))
        sys.exit(code)
    elif args.command == 'key':
        code, out, err = probe(['key', args.app, args.keys])
        print(json.dumps({'key': args.keys, 'status': code, 'error': err.strip()}))
        sys.exit(code)
    elif args.command == 'shot':
        path = latest_session() / f'{args.name}.png'
        subprocess.run(['/usr/sbin/screencapture', '-x', f'-D{args.display}', str(path)], check=True)
        print(path)
    elif args.command == 'wshot':
        window_shot(args.name)
    elif args.command == 'settings':
        print(json.dumps(display_settings(), indent=2))


if __name__ == '__main__':
    main()
