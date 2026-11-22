#!/usr/bin/env python3
"""Recall #80/#81: a stale font instance id must not leave Wine's font lock held, against a real engine.

Battle.net's install window froze for every player (November 2026): its Qt loads "Noto Sans" from
memory, Wine's DirectWrite keeps each realized font's instance id to read the font's file later,
and win32u had freed some of those fonts. A freed id's entry in the handle table links the free
list, yet win32u still took it for a font: NtGdiGetFontFileData faulted inside FreeType with the
font lock held, Wine returned the fault to the program as a result, and the lock stayed held.
patches/wine-win32u-display-log.patch has the handle table say which entries are in use.

Runs stale_handle_probe.c under the engine's Wine, with Recall's launch environment, in a new
scratch Windows environment. Passes when a live id reads its file, no stale id is accepted and
another thread can still select a font. With --control ENGINE, also runs an engine without the
change, to show the failure (a stale id accepted, then every font call blocked).

No game, account or Battle.net; needs Rosetta and Wine outside the command sandbox. Wine's server
for the scratch root is stopped at exit.
"""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--engine', type=Path, required=True, help='an extracted runtime with the change')
    p.add_argument('--control', type=Path, help='an extracted runtime without it')
    p.add_argument('--root', type=Path, required=True, help='new scratch folder outside the checkout')
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    root, out = a.root.resolve(), a.output.resolve()
    if root.is_relative_to(ROOT) or root.exists():
        p.error('Use a new scratch root outside the checkout; an existing one is never adopted')
    root.mkdir(parents=True)
    out.mkdir(parents=True, exist_ok=True)
    probe = out / 'stale-handle-probe.exe'
    compiler = ROOT / 'runtime/toolchains/llvm-mingw-20251216-ucrt-macos-universal/bin/x86_64-w64-mingw32-gcc'
    subprocess.run([str(compiler), '-O2', '-g0', '-Wall', '-Wextra', '-Wno-unused-parameter', '-Werror',
                    str(Path(__file__).parent / 'stale_handle_probe.c'), '-o', str(probe), '-lgdi32'], check=True)
    contract = json.loads((ROOT / 'docs/candidate-parity-contract.json').read_text())['environment']

    def run(engine):
        env = dict(contract, PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME=str(root / 'home'), USER='player',
                   TMPDIR=str(root / 'tmp'), WINEPREFIX=str(root / 'environment'), WINEARCH='win64',
                   WINESERVER=str(engine / 'bin/wineserver'), WINELOADER=str(engine / 'bin/wine'), WINEDEBUG='-all',
                   WINEDLLOVERRIDES='mscoree,mshtml=',
                   CX_APPLEGPTK_LIBD3DSHARED_PATH=str(engine / 'lib/external/libd3dshared.dylib'))
        (root / 'home').mkdir(exist_ok=True)
        (root / 'tmp').mkdir(exist_ok=True)
        try:
            r = subprocess.run([str(engine / 'bin/wine'), str(probe)], env=env, cwd=root, capture_output=True,
                               text=True, timeout=120)
            lines = [json.loads(line) for line in r.stdout.splitlines() if line.startswith('{')]
            return lines[-1] if lines else {'error': 'no result', 'stderr': r.stderr[-400:]}
        finally:
            subprocess.run([str(engine / 'bin/wineserver'), '-k'], env=env, timeout=60)
            subprocess.run([str(engine / 'bin/wineserver'), '-w'], env=env, timeout=60)

    def healthy(r):
        return (r.get('realized', 0) > 10 and r.get('live_id_read') is True and r.get('stale_reads') == 'returned'
                and r.get('stale_info_accepted') == 0 and r.get('stale_data_accepted') == 0
                and r.get('font_use_afterwards') == 'ok')

    results = {'engine': run(a.engine.resolve())}
    results['passed'] = healthy(results['engine'])
    if a.control:
        results['control'] = run(a.control.resolve())
        results['control_shows_the_failure'] = (results['control'].get('stale_data_accepted', 0) > 0
                                                and 'blocked' in (results['control'].get('stale_reads'),
                                                                  results['control'].get('font_use_afterwards')))
    (out / 'results.json').write_text(json.dumps(results, indent=1) + '\n')
    print(json.dumps(results, indent=1))
    raise SystemExit(0 if results['passed'] and results.get('control_shows_the_failure', True) else 1)


if __name__ == '__main__':
    main()
