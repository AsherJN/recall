#!/usr/bin/env python3
"""Mouse rate check: movement updates a second from each macOS source, with the pointer frozen as in game.

Builds tests/mouselook/rate_check.m into a small app and opens it. The player clicks Start and moves the
mouse in circles for 30 seconds. Prints the result and keeps summary.json and samples.csv under
logs/mouselook/rate-check-<stamp>. Installs nothing and changes no setting.

  --direct     also read the mouse itself (macOS asks for Input Monitoring permission)
  --selftest   list the mice each source can see, with no window
  --synthetic  analyse generated samples (tests/test_mouse_rate_check.py)
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
SOURCE = Path(__file__).resolve().with_name('rate_check.m')
APP = ROOT / 'runtime/build/mouse-rate-check/Mouse Rate Check.app'
EXECUTABLE = APP / 'Contents/MacOS/MouseRateCheck'
LOGS = ROOT / 'logs/mouselook'
DEVELOPER_DIR = '/Library/Developer/CommandLineTools'
CLANG = DEVELOPER_DIR + '/usr/bin/clang'
SDK = DEVELOPER_DIR + '/SDKs/MacOSX.sdk'
INFO = {'CFBundleExecutable': EXECUTABLE.name, 'CFBundleIdentifier': 'local.overwatch2mac.mouse-rate-check',
        'CFBundleName': 'Mouse Rate Check', 'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1',
        'LSMinimumSystemVersion': '26.0', 'NSHighResolutionCapable': True, 'NSPrincipalClass': 'NSApplication'}


def build():
    """Compile and ad-hoc sign the app when the source or this script changed."""
    newest = max(SOURCE.stat().st_mtime, Path(__file__).stat().st_mtime)
    if EXECUTABLE.exists() and EXECUTABLE.stat().st_mtime >= newest:
        return
    EXECUTABLE.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([CLANG, '-fobjc-arc', '-O2', '-Wall', '-Wextra', '-Wno-unused-parameter', '-isysroot', SDK,
                    '-mmacosx-version-min=26.0', '-framework', 'AppKit', '-framework', 'GameController',
                    '-framework', 'IOKit', '-o', str(EXECUTABLE), str(SOURCE)],
                   check=True, env={**os.environ, 'DEVELOPER_DIR': DEVELOPER_DIR})
    (APP / 'Contents/Info.plist').write_bytes(plistlib.dumps(INFO))
    subprocess.run(['codesign', '--force', '--sign', '-', str(APP)], check=True, capture_output=True)


def show(summary, folder):
    print()
    for line in summary['verdict']:
        print(line)
    rows = [('Mouse, read directly', summary['mouse'])] if summary['mouse']['available'] else []
    rows += [('Pointer events, merging on', summary['pointer']['merging_on']),
             ('Pointer events, merging off', summary['pointer']['merging_off']),
             ('Game-controller input', summary['game'])]
    print(f'\n{"":28} {"per second":>10} {"delay ms":>9}')
    for name, row in rows:
        rate = '–' if row.get('per_s') is None else f'{row["per_s"]:,.0f}'
        delay = '–' if row.get('delay_ms') is None else f'{row["delay_ms"]:.1f}'
        print(f'{name:28} {rate:>10} {delay:>9}')
    print(f'\nMoving seconds: {summary["moving_seconds"]} of {summary["seconds"]}'
          f'{"" if summary["completed"] else " (stopped early)"}. Saved in {folder.relative_to(ROOT)}.')


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('--direct', action='store_true', help='also read the mouse itself (asks for permission)')
    parser.add_argument('--selftest', action='store_true', help='list the mice each source can see')
    parser.add_argument('--synthetic', action='store_true', help='analyse generated samples')
    parser.add_argument('--no-mouse', action='store_true', help='with --synthetic: without the direct mouse feed')
    args = parser.parse_args()
    build()
    if args.selftest or args.synthetic:
        extra = ['--selftest'] if args.selftest else ['--synthetic', *(['--no-mouse'] if args.no_mouse else [])]
        sys.exit(subprocess.run([str(EXECUTABLE), *extra]).returncode)
    folder = LOGS / time.strftime('rate-check-%Y%m%d-%H%M%S')
    folder.mkdir(parents=True)
    print('Opening Mouse Rate Check. Click Start, then move the mouse in circles until the bar fills.')
    subprocess.run(['open', '-W', '-n', str(APP), '--args', '--out', str(folder),
                    *(['--direct'] if args.direct else [])], check=True)
    summary = folder / 'summary.json'
    if not summary.exists():
        print('No result: the window was closed before a check finished.')
        sys.exit(1)
    show(json.loads(summary.read_text()), folder)


if __name__ == '__main__':
    main()
