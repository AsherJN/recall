#!/usr/bin/env python3
"""Controllers through Wine without the game, in a scratch prefix.

For each engine (default: the 1.2 test engine and, as the control, 1.1's), lists the HID
game controllers Wine creates (an XInput pad's path carries "IG_"), the connected XInput
slots, and the devices winebus ignores and why (winedevice.exe:warn+hid). Builds
tests/controllers/probe.c with the pinned LLVM-MinGW and makes the prefix
(runtime/controllers/prefix) once. Each engine runs the probe twice: the first run starts
Wine's services, the second reads what they created. --watch N then prints every XInput
state change for N seconds: press buttons meanwhile.

Never touches the installed app or its environment. Wine does not run inside the command
sandbox. Logs go to logs/controllers/.
"""
import argparse
import datetime
import os
from pathlib import Path
import re
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = ROOT / 'runtime/phase-2/artifacts'
TEST_ENGINE, CONTROL_ENGINE = 'phase2-20261005.1', 'phase2-20261004.4'
MINGW_CLANG = ROOT / 'runtime/toolchains/llvm-mingw-20251216-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang'
PREFIX = ROOT / 'runtime/controllers/prefix'
LOGS = ROOT / 'logs/controllers'
DEBUG = '-all,winedevice.exe:warn+hid,winedevice.exe:err+hid'


def build_probe(output):
    subprocess.run([str(MINGW_CLANG), '-O2', '-Wall', str(Path(__file__).with_name('probe.c')),
                    '-lsetupapi', '-lhid', '-lxinput1_4', '-o', str(output)], check=True)
    return output


def wine_env(engine, prefix, debug=DEBUG):
    return dict(os.environ, WINEPREFIX=str(prefix), WINEARCH='win64', WINEDEBUG=debug,
                WINEDLLOVERRIDES='mscoree,mshtml=', WINESERVER=str(engine / 'bin/wineserver'),
                WINELOADER=str(engine / 'bin/wine'))


def summary(log_text):
    """The lines that say what a game sees: controllers, XInput slots and winebus's decisions."""
    keep = re.compile(r'^(hid |xinput )|ignoring (non-)?hidraw device|SDL|could not load|bus init returned')
    lines = []
    for line in log_text.splitlines():
        line = re.sub(r'^[0-9a-f]+:(warn|err):hid:', r'\1: ', line)
        if keep.search(line) and 'UDEV' not in line and line not in lines:
            lines.append(line)
    return lines


def probe(engine, probe_exe, settle, watch):
    env = wine_env(engine, PREFIX)
    if not (PREFIX / 'system.reg').exists():
        PREFIX.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(engine / 'bin/wine'), 'wineboot', '-i'], env=env, capture_output=True, check=True)
        subprocess.run([str(engine / 'bin/wineserver'), '-w'], env=env, check=True)
    output = []
    try:
        for seconds in (0, watch):
            if output:
                time.sleep(settle)
                if watch:
                    print(f'Press buttons now, for {watch} s', flush=True)
            run = subprocess.run([str(engine / 'bin/wine'), str(probe_exe), str(seconds)], env=env,
                                 capture_output=True, text=True, errors='replace')
            output.append(run.stdout + run.stderr)
    finally:
        subprocess.run([str(engine / 'bin/wineserver'), '-k'], env=env)
        subprocess.run([str(engine / 'bin/wineserver'), '-w'], env=env)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('engines', nargs='*', default=[CONTROL_ENGINE, TEST_ENGINE],
                        help='Runtime versions under runtime/phase-2/artifacts, or engine folders')
    parser.add_argument('--settle', type=float, default=4, help="Seconds for Wine's services to find the controllers")
    parser.add_argument('--watch', type=int, default=0, help='Print XInput state changes for this many seconds')
    args = parser.parse_args()
    LOGS.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    probe_exe = build_probe(LOGS / 'probe.exe')
    for name in args.engines:
        engine = Path(name) if '/' in name else ARTIFACTS / name
        print(f'== {engine.name}', flush=True)
        first, second = probe(engine.resolve(), probe_exe, args.settle, args.watch)
        (LOGS / f'probe-{engine.name}-{stamp}.log').write_text(first + '\n---\n' + second)
        print('\n'.join(summary(first + second)), flush=True)


if __name__ == '__main__':
    main()
