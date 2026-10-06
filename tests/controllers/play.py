#!/usr/bin/env python3
"""Controllers in the real game on a test engine (1.2: winebus built with SDL2).

Starts Battle.net from the engine against the installed Recall app's environment, with
the app's environment and arguments (as tests/game_mode/play.py does). The player clicks
Update and Play in Battle.net (it asks to update at every start) and plays with the
controllers under test. Once Wine's services run, tests/controllers/probe.c lists the
game controllers and XInput slots this session offers the game; winebus's decisions
(winedevice.exe:warn+hid) go to battlenet.log. Both are summarized in controllers.txt
when the game quits (or after --max-minutes), and the session is closed.

The engine runs from an APFS clone in runtime/controllers/engine (made from the test
engine's artifact when missing), so scripts/battlenet_closer.py, which only signals
this checkout's engines, closes Battle.net once the game runs, as the app does.

Takes over the screen: ask the owner. Never modifies the installed app or its runtime.
"""
import argparse
import datetime
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import candidate_contract  # noqa: E402
import run as probe_tool  # noqa: E402

APP_ROOT = Path.home() / 'Library/Application Support/Overwatch2Mac'
ENGINE = ROOT / 'runtime/controllers/engine'
APP_BINARIES = ('Recall.app/Contents/MacOS/Recall', 'Overwatch 2 Mac.app/Contents/MacOS/Overwatch2Mac')
CLIENT = 'drive_c/Program Files (x86)/Battle.net/Battle.net.exe'
CLIENT_ARGS = ['--disable-gpu-compositing', '--from-launcher', '--in-process-gpu',
               '--use-gl=angle', '--use-angle=swiftshader', '--exec=launch Pro']


def processes():
    table = subprocess.run(['/bin/ps', '-axo', 'pid=,comm='], capture_output=True, text=True, check=True).stdout
    for line in table.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2:
            yield int(fields[0]), fields[1]


def servers(engine):
    roots = (str(APP_ROOT / 'runtimes') + '/', str(engine) + '/')
    return [command for _, command in processes() if command.endswith('/wineserver') and command.startswith(roots)]


def game_running():
    return any(command.endswith('Overwatch.exe') for _, command in processes())


def preflight(engine):
    if not (engine / 'lib/libSDL2-2.0.0.dylib').is_file():
        raise SystemExit(f'{engine} has no SDL2; make it with scripts/derive_runtime.py --controllers.')
    if not (APP_ROOT / 'environment' / CLIENT).is_file():
        raise SystemExit('Battle.net is not installed in the Recall environment.')
    if any(command.endswith(APP_BINARIES) for _, command in processes()):
        raise SystemExit('Quit the Recall app first, so it cannot start a second session.')
    if game_running():
        raise SystemExit('Overwatch is running. Quit the game first; this tool never closes a match.')
    # Idle Wine services or Battle.net from an earlier session: close them as the app's Stop does.
    for command in servers(engine):
        subprocess.run([command, '-k'], env={'PATH': '/usr/bin:/bin', 'WINEPREFIX': str(APP_ROOT / 'environment')},
                       timeout=30)
    deadline = time.time() + 30
    while servers(engine):
        if time.time() > deadline:
            raise SystemExit('The previous session did not exit.')
        time.sleep(0.5)


def environment(engine):
    """The app's wineEnv and clientEnvironment (scripts/portable_setup.m) with the test engine."""
    config = APP_ROOT / 'dxmt.conf' if (APP_ROOT / 'dxmt.conf').is_file() else engine / 'config/dxmt.conf'
    env = dict(candidate_contract.load()['environment'])
    env.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME=str(APP_ROOT / 'home'), USER='player',
               TMPDIR=str(APP_ROOT / 'tmp'), WINEPREFIX=str(APP_ROOT / 'environment'), WINEARCH='win64',
               WINESERVER=str(engine / 'bin/wineserver'), WINELOADER=str(engine / 'bin/wine'),
               WINEDEBUG=probe_tool.DEBUG,
               CX_APPLEGPTK_LIBD3DSHARED_PATH=str(engine / 'lib/external/libd3dshared.dylib'),
               DXMT_SHADER_CACHE_PATH=str(APP_ROOT / 'cache/shaders'), DXMT_LOG_LEVEL='error', DXMT_LOG_PATH='none',
               DXMT_CONFIG_FILE='Z:' + str(config).replace('/', '\\'),
               DXMT_PIPELINE_CACHE_PATH=str(APP_ROOT / 'cache/pipelines'), QT_SCALE_FACTOR='2')
    return env


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--engine', type=Path, default=ENGINE)
    parser.add_argument('--max-minutes', type=float, default=60, help='Close the session after this long.')
    args = parser.parse_args()
    if args.engine == ENGINE and not ENGINE.exists():
        ENGINE.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(['/bin/cp', '-cR', str(probe_tool.ARTIFACTS / probe_tool.TEST_ENGINE), str(ENGINE)], check=True)
    engine = args.engine.resolve()

    preflight(engine)
    session = probe_tool.LOGS / ('play-' + engine.name + '-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    session.mkdir(parents=True)
    print(session, flush=True)
    env = environment(engine)
    log = session / 'battlenet.log'
    with log.open('w') as out:
        subprocess.Popen([str(engine / 'bin/wine'), str(APP_ROOT / 'environment' / CLIENT), *CLIENT_ARGS], env=env,
                         cwd=APP_ROOT, stdin=subprocess.DEVNULL, stdout=out, stderr=out, start_new_session=True)
    with (session / 'battlenet-closer.log').open('w') as out:
        subprocess.Popen([sys.executable, str(ROOT / 'scripts/battlenet_closer.py'), '--engine', str(engine),
                          '--prefix', str(APP_ROOT / 'environment'), '--grace-seconds', '25',
                          '--log', str(session / 'battlenet-closer.json')],
                         cwd=ROOT, stdin=subprocess.DEVNULL, stdout=out, stderr=out, start_new_session=True)

    # What this session offers the game, read once Wine's services have found the controllers.
    time.sleep(10)
    probe_exe = probe_tool.build_probe(session / 'probe.exe')
    seen = subprocess.run([str(engine / 'bin/wine'), str(probe_exe), '0'], env=dict(env, WINEDEBUG='-all'),
                          capture_output=True, text=True, errors='replace').stdout
    (session / 'probe.txt').write_text(seen)
    print(seen, flush=True)

    game_seen, deadline = None, time.time() + args.max_minutes * 60
    while time.time() < deadline:
        time.sleep(5)
        if game_running():
            if not game_seen:
                print('Overwatch is running', flush=True)
            game_seen = game_seen or time.time()
        elif game_seen:
            print('Overwatch quit', flush=True)
            break
    subprocess.run([str(engine / 'bin/wineserver'), '-k'], env=env, timeout=30)
    lines = probe_tool.summary(seen + log.read_text(errors='replace'))
    lines.append(f'game ran {round(time.time() - game_seen)} s' if game_seen else 'game never started')
    (session / 'controllers.txt').write_text('\n'.join(lines) + '\n')
    print('\n'.join(lines))


if __name__ == '__main__':
    main()
