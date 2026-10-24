#!/usr/bin/env python3
"""Run AppModel's setting/launch race regression tests without Wine or a game.

The test bundle, fixture worker and installation are temporary. The app's real
entry point is excluded, so no Recall window or game process is started.
"""
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts'))
from build_portable_setup import MINIMUM_MACOS  # noqa: E402


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='recall-advanced-settings-') as temporary:
        bundle = Path(temporary)/'AdvancedSettingsTests.app'
        executable = bundle/'Contents/MacOS/AdvancedSettingsTests'
        executable.parent.mkdir(parents=True)
        (bundle/'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'org.overwatch2mac.settings-regression',
            'CFBundleExecutable': executable.name,
            'CFBundlePackageType': 'APPL',
        }))
        sources = [str(path) for path in sorted((ROOT/'app/Sources').glob('*.swift'))
                   if path.name != 'Main.swift']
        subprocess.run(['/usr/bin/swiftc', '-Onone', '-j', '4',
                        '-target', 'arm64-apple-macos' + MINIMUM_MACOS,
                        '-parse-as-library', *sources,
                        str(ROOT/'tests/AdvancedSettingsTests.swift'),
                        '-o', str(executable)], check=True)
        subprocess.run([str(executable)], check=True)
