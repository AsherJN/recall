#!/usr/bin/env python3
"""Builds Recall Mouse Probe (scripts/hid_mouse_probe.m, REC-52): a small app that counts mouse
movement from the mouse's own reports (IOHID), from Apple's mouse input for games (GCMouse) and
from the macOS pointer side by side, to see whether reading the hardware directly loses nothing.

The binary is universal: the app runs natively and starts its x86_64 copy under Rosetta, as Recall
starts Wine. Sign it with the Developer ID so that its Input Monitoring permission survives a
rebuild (macOS keys it to the bundle identifier and team). --notarize, for a tester's Mac, signs
with the hardened runtime and a timestamp, has Apple notarize it, staples the ticket and leaves a
zip of the stapled app beside it.

    python3 scripts/build_hid_mouse_probe.py --output <new .app> [--identity <Developer ID>] [--notarize]
"""
import argparse
import json
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts'))
from build_portable_setup import MINIMUM_MACOS  # noqa: E402

NAME = 'Recall Mouse Probe'
IDENTIFIER = 'org.overwatch2mac.mouse-probe'
NOTARY_PROFILE = 'overwatch-2-mac-notary'


def notarize(app):
    """Notarizes and staples app; returns the zip of the stapled app."""
    archive = app.with_suffix('.zip')
    subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(app), str(archive)], check=True)
    result = subprocess.run(['/usr/bin/xcrun', 'notarytool', 'submit', str(archive), '--keychain-profile', NOTARY_PROFILE,
                             '--wait', '--output-format', 'json'], check=True, capture_output=True, text=True)
    status = json.loads(result.stdout)
    if status.get('status') != 'Accepted':
        raise SystemExit(f'notarization {status.get("status")}: {result.stdout}')
    subprocess.run(['/usr/bin/xcrun', 'stapler', 'staple', str(app)], check=True)
    archive.unlink()
    subprocess.run(['/usr/bin/ditto', '-c', '-k', '--keepParent', str(app), str(archive)], check=True)
    print(f'notarized {status.get("id")}')
    return archive


def build(output, identity='-', distribute=False):
    if output.exists():
        raise SystemExit(f'{output} already exists')
    executable = output/'Contents/MacOS'/NAME
    executable.parent.mkdir(parents=True)
    subprocess.run(['/usr/bin/clang', '-O2', '-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-arch', 'arm64', '-arch', 'x86_64',
                    '-ffile-prefix-map='+str(ROOT)+'=/ow2-source', '-mmacosx-version-min='+MINIMUM_MACOS,
                    str(ROOT/'scripts/hid_mouse_probe.m'), '-framework', 'Cocoa', '-framework', 'IOKit',
                    '-framework', 'GameController', '-framework', 'QuartzCore', '-o', str(executable)], check=True)
    with open(output/'Contents/Info.plist', 'wb') as plist:
        plistlib.dump({'CFBundleIdentifier': IDENTIFIER, 'CFBundleName': NAME, 'CFBundleDisplayName': NAME,
                       'CFBundleExecutable': NAME, 'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': '1.0',
                       'CFBundleVersion': '1', 'LSMinimumSystemVersion': MINIMUM_MACOS, 'NSHighResolutionCapable': True,
                       'LSArchitecturePriority': ['arm64', 'x86_64']}, plist)
    signing = ['--options', 'runtime', '--timestamp'] if distribute else ['--timestamp=none']
    subprocess.run(['/usr/bin/codesign', '--force', '--sign', identity, *signing, str(output)], check=True)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--identity', default='-', help='codesign identity (ad hoc by default)')
    parser.add_argument('--notarize', action='store_true', help='hardened runtime, notarized and stapled, zipped')
    args = parser.parse_args()
    app = build(args.output.resolve(), args.identity, distribute=args.notarize)
    print(notarize(app) if args.notarize else app)


if __name__ == '__main__':
    main()
