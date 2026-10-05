#!/usr/bin/env python3
"""Game Mode on the real game, with the product mechanism.

Starts Battle.net from a test engine against the installed Recall app's environment,
with the app's environment and arguments (as scripts/mouselook_session.py does). The
contract's WINE_GAME_MODE=Overwatch.exe makes ntdll start Overwatch from the engine's
game app (scripts/game_mode_app.py); --off leaves it out, which is the control. The
player clicks Update and Play in Battle.net: it asks to update at every start, so it
never starts the game by itself.

Make the test engine from the 1.1 engine with this branch's ntdll and the game app,
signed ad hoc (it never leaves this Mac):
  cp -cR runtime/phase-2/artifacts/<1.1 engine> runtime/game-mode/engine
  cp runtime/build/wine-native/ntdll/current/ntdll.so runtime/game-mode/engine/lib/wine/x86_64-unix/
  python3 scripts/game_mode_app.py runtime/game-mode/engine

Records gamepolicyctl and gamepolicyd's verdict while the game runs, which executable
the game process runs, and with --trace-network Wine's socket and DNS calls in the game
process only (WINEDEBUG=Overwatch.exe:+winsock,...), summarized in network.txt. --hud
turns on the Metal Performance HUD as Recall's Settings switch does. Closes the session
(wineserver -k) unless --keep-running. Takes over the screen: ask the owner. Never
modifies the installed app or its runtime.

--stand-in runs tests/game_mode/standin.c, built as Overwatch.exe, instead of Battle.net
and the game: a D3D11 window that goes fullscreen through the canvas.
"""
import argparse
import ctypes
import datetime
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import candidate_contract  # noqa: E402
import game_mode_app  # noqa: E402

APP_ROOT = Path.home() / 'Library/Application Support/Overwatch2Mac'
ENGINE = ROOT / 'runtime/game-mode/engine'
APP_BINARIES = ('Recall.app/Contents/MacOS/Recall', 'Overwatch 2 Mac.app/Contents/MacOS/Overwatch2Mac')
CLIENT = 'drive_c/Program Files (x86)/Battle.net/Battle.net.exe'
CLIENT_ARGS = ['--disable-gpu-compositing', '--from-launcher', '--in-process-gpu',
               '--use-gl=angle', '--use-angle=swiftshader', '--exec=launch Pro']
HUD = {'MTL_HUD_ENABLED': '1', 'MTL_HUD_DISABLE_MENU_BAR': '1',
       'MTL_HUD_ELEMENTS': 'device,rosetta,layersize,memory,gamemode,fps,gputime,frameinterval,frameintervalgraph,shaders'}
TRACE = 'Overwatch.exe:+timestamp,Overwatch.exe:+winsock,Overwatch.exe:+dnsapi,Overwatch.exe:+iphlpapi,Overwatch.exe:+nsi'
GAMEPOLICYCTL = '/Applications/Xcode.app/Contents/Developer/usr/bin/gamepolicyctl'
LOGS = ROOT / 'logs/game-mode'
MINGW_CLANG = ROOT / 'runtime/toolchains/llvm-mingw-20251216-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang'


def processes():
    table = subprocess.run(['/bin/ps', '-axo', 'pid=,comm='], capture_output=True, text=True, check=True).stdout
    for line in table.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2:
            yield int(fields[0]), fields[1]


def servers(engine):
    roots = (str(APP_ROOT / 'runtimes') + '/', str(engine) + '/')
    return [(pid, command) for pid, command in processes()
            if command.endswith('/wineserver') and command.startswith(roots)]


def game_pid():
    return next((pid for pid, command in processes() if command.endswith('Overwatch.exe')), None)


def executable_path(pid):
    buffer = ctypes.create_string_buffer(4096)
    size = ctypes.CDLL('/usr/lib/libproc.dylib').proc_pidpath(pid, buffer, len(buffer))
    return buffer.value.decode() if size > 0 else None


def game_mode():
    text = subprocess.run([GAMEPOLICYCTL, 'game-mode', 'status'], capture_output=True, text=True).stdout
    match = re.search(r'Game mode is (\w+)', re.sub(r'\x1b\[[0-9;]*m', '', text))
    return match.group(1) if match else text.strip()


def frontmost():
    asn = subprocess.run(['/usr/bin/lsappinfo', 'front'], capture_output=True, text=True).stdout.strip()
    info = subprocess.run(['/usr/bin/lsappinfo', 'info', '-only', 'name', asn], capture_output=True, text=True).stdout
    match = re.search(r'"LSDisplayName"="([^"]*)"', info)
    return match.group(1) if match else info.strip()


def preflight(engine):
    if not (engine / game_mode_app.BUNDLE).is_dir():
        raise SystemExit(f'{engine} has no game app; see this script\'s help to make the test engine.')
    identifier = plistlib.loads((engine / game_mode_app.BUNDLE / 'Contents/Info.plist').read_bytes())['CFBundleIdentifier']
    game_mode_app.check(engine, identifier)
    if not (APP_ROOT / 'environment' / CLIENT).is_file():
        raise SystemExit('Battle.net is not installed in the Recall environment.')
    if any(command.endswith(APP_BINARIES) for _, command in processes()):
        raise SystemExit('Quit the Recall app first, so it cannot start a second session.')
    if game_pid():
        raise SystemExit('Overwatch is running. Quit the game first; this tool never closes a match.')
    # Idle Wine services or Battle.net from an earlier session: close them as the app's Stop does.
    for _, command in servers(engine):
        subprocess.run([command, '-k'], env={'PATH': '/usr/bin:/bin', 'WINEPREFIX': str(APP_ROOT / 'environment')},
                       timeout=30)
    deadline = time.time() + 30
    while servers(engine):
        if time.time() > deadline:
            raise SystemExit('The previous session did not exit.')
        time.sleep(0.5)


def environment(engine, args):
    """The app's wineEnv and clientEnvironment (scripts/portable_setup.m) with the test engine."""
    config = APP_ROOT / 'dxmt.conf' if (APP_ROOT / 'dxmt.conf').is_file() else engine / 'config/dxmt.conf'
    env = dict(candidate_contract.load()['environment'])
    env.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME=str(APP_ROOT / 'home'), USER='player',
               TMPDIR=str(APP_ROOT / 'tmp'), WINEPREFIX=str(APP_ROOT / 'environment'), WINEARCH='win64',
               WINESERVER=str(engine / 'bin/wineserver'), WINELOADER=str(engine / 'bin/wine'),
               WINEDEBUG=('-all,' + TRACE) if args.trace_network else '-all',
               CX_APPLEGPTK_LIBD3DSHARED_PATH=str(engine / 'lib/external/libd3dshared.dylib'),
               DXMT_SHADER_CACHE_PATH=str(APP_ROOT / 'cache/shaders'), DXMT_LOG_LEVEL='error', DXMT_LOG_PATH='none',
               DXMT_CONFIG_FILE='Z:' + str(config).replace('/', '\\'),
               DXMT_PIPELINE_CACHE_PATH=str(APP_ROOT / 'cache/pipelines'), QT_SCALE_FACTOR='2')
    if args.hud:
        env.update(HUD)
    if args.off:
        env.pop('WINE_GAME_MODE')
    return env


def gamepolicyd(start, end, pid):
    text = subprocess.run(['/usr/bin/log', 'show', '--style', 'compact', '--start', start, '--end', end,
                           '--predicate', 'process == "gamepolicyd"'], capture_output=True, text=True).stdout
    ours = re.compile(r'[(:]%d[)\]]|pid=%d\b' % (pid, pid)) if pid else None
    return [line for line in text.splitlines()
            if re.search(r'Found game|gaming session|Game mode status', line) or (ours and ours.search(line))]


def network_summary(log):
    """Distinct socket destinations and name lookups from the game's Wine trace."""
    destinations, lookups, calls = {}, {}, {}
    for line in log.read_text(errors='replace').splitlines():
        if ':winsock:' not in line and ':dnsapi:' not in line and ':iphlpapi:' not in line and ':nsi:' not in line:
            continue
        call = re.search(r':(?:winsock|dnsapi|iphlpapi|nsi):(\w+)', line)
        if call:
            calls[call.group(1)] = calls.get(call.group(1), 0) + 1
        for address in re.findall(r'(?:\d{1,3}\.){3}\d{1,3}(?::\d+)?|\[[0-9a-fA-F:]+\](?::\d+)?', line):
            destinations[address] = destinations.get(address, 0) + 1
        for name in re.findall(r'(?:node|name|host)[^"]*"([^"]+)"', line):
            lookups[name] = lookups.get(name, 0) + 1
    lines = ['calls:'] + [f'  {n} {c}' for c, n in sorted(calls.items(), key=lambda kv: -kv[1])]
    lines += ['addresses:'] + [f'  {n} {a}' for a, n in sorted(destinations.items(), key=lambda kv: -kv[1])]
    lines += ['lookups:'] + [f'  {n} {a}' for a, n in sorted(lookups.items(), key=lambda kv: -kv[1])]
    return '\n'.join(lines) + '\n'


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--engine', type=Path, default=ENGINE)
    parser.add_argument('--off', action='store_true', help='Leave WINE_GAME_MODE out (the control).')
    parser.add_argument('--hud', action='store_true', help='Turn on the Metal Performance HUD.')
    parser.add_argument('--trace-network', action='store_true', help="Log the game process's socket and DNS calls.")
    parser.add_argument('--stand-in', action='store_true', help='Run tests/game_mode/standin.c instead of the game.')
    parser.add_argument('--watch-seconds', type=float, default=75, help='How long to watch once the game runs.')
    parser.add_argument('--max-seconds', type=float, default=540, help='Give up waiting for the game after this long.')
    parser.add_argument('--keep-running', action='store_true', help='Leave the session open afterwards.')
    args = parser.parse_args()
    engine = args.engine.resolve()

    preflight(engine)
    session = LOGS / ('play-' + ('stand-in-' if args.stand_in else '') + ('off' if args.off else 'on') + '-' +
                      datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    session.mkdir(parents=True)
    print(session, flush=True)
    started = datetime.datetime.now()
    env = environment(engine, args)
    log = session / ('standin.log' if args.stand_in else 'battlenet.log')
    if args.stand_in:
        exe = session / 'Overwatch.exe'
        subprocess.run([str(MINGW_CLANG), '-O2', '-municode', '-mwindows', str(ROOT / 'tests/game_mode/standin.c'),
                        '-ld3d11', '-ldxgi', '-ldxguid', '-luuid', '-o', str(exe)], check=True)
        env.update(DXMT_SHADER_CACHE_PATH=str(session / 'shaders'), DXMT_PIPELINE_CACHE_PATH=str(session / 'pipelines'))
        command = [str(engine / 'bin/wine'), 'start.exe', '/wait', '/unix', str(exe), str(int(args.watch_seconds + 20))]
    else:
        command = [str(engine / 'bin/wine'), str(APP_ROOT / 'environment' / CLIENT), *CLIENT_ARGS]
    with log.open('w') as out:
        subprocess.Popen(command, env=env, cwd=APP_ROOT, stdin=subprocess.DEVNULL, stdout=out, stderr=out,
                         start_new_session=True)
    if not args.stand_in:
        with (session / 'battlenet-closer.log').open('w') as out:
            subprocess.Popen([sys.executable, str(ROOT / 'scripts/battlenet_closer.py'), '--engine', str(engine),
                              '--prefix', str(APP_ROOT / 'environment'), '--grace-seconds', '25',
                              '--log', str(session / 'battlenet-closer.json')],
                             cwd=ROOT, stdin=subprocess.DEVNULL, stdout=out, stderr=out, start_new_session=True)

    samples, pid, path, game_seen, deadline = [], None, None, None, time.time() + args.max_seconds
    while time.time() < deadline:
        time.sleep(3)
        pid = pid or game_pid()
        if not pid:
            continue
        path = path or executable_path(pid)
        game_seen = game_seen or time.time()
        samples.append({'t': round(time.time() - game_seen, 1), 'game_mode': game_mode(), 'frontmost': frontmost()})
        print(json.dumps(samples[-1]), flush=True)
        if time.time() - game_seen > args.watch_seconds or not game_pid():
            break
    ended = datetime.datetime.now()
    if not args.keep_running:
        subprocess.run([str(engine / 'bin/wineserver'), '-k'], env=env, timeout=30)
    lines = gamepolicyd(started.strftime('%Y-%m-%d %H:%M:%S'), ended.strftime('%Y-%m-%d %H:%M:%S'), pid)
    (session / 'gamepolicyd.log').write_text('\n'.join(lines) + '\n')
    if args.trace_network:
        (session / 'network.txt').write_text(network_summary(log))
    result = {'game_mode_env': env.get('WINE_GAME_MODE'), 'hud': args.hud, 'game_pid': pid, 'game_executable': path,
              'from_game_app': bool(path and path.endswith(game_mode_app.EXECUTABLE)),
              'found_game': [line.split('Found game ', 1)[1] for line in lines if 'Found game' in line],
              'engaged': any(sample['game_mode'] == 'on' for sample in samples), 'samples': samples}
    (session / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps({k: result[k] for k in ('game_mode_env', 'engaged', 'from_game_app', 'found_game')}, indent=2))


if __name__ == '__main__':
    main()
