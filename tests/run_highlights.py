#!/usr/bin/env python3
"""Run HighlightsTests.swift: the Recall mark's Mac name, the Highlights window's clip list and a
marked copy made with AVFoundation (REC-53, REC-96, REC-97). No Wine, game or app window.

The app's sources (all but Main.swift, which starts the app) are compiled with the tests. The
home folder is a scratch one (CFFIXED_USER_HOME), so Movies › Overwatch and Recall's caches are
scratch folders and nothing of the player's is touched.
"""
from pathlib import Path
import os
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts'))
from build_portable_setup import MINIMUM_MACOS  # noqa: E402


if __name__ == '__main__':
    with tempfile.TemporaryDirectory(prefix='recall-highlights-') as temporary:
        executable = Path(temporary)/'HighlightsTests'
        home = Path(temporary)/'home'
        (home/'Movies').mkdir(parents=True)
        sources = [str(path) for path in sorted((ROOT/'app/Sources').glob('*.swift')) if path.name != 'Main.swift']
        subprocess.run(['/usr/bin/swiftc', '-Onone', '-j', '4', '-target', 'arm64-apple-macos' + MINIMUM_MACOS,
                        '-parse-as-library', *sources, str(ROOT/'tests/HighlightsTests.swift'),
                        '-o', str(executable)], check=True)
        subprocess.run([str(executable)], check=True, env=dict(os.environ, CFFIXED_USER_HOME=str(home)))
