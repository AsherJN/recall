#!/usr/bin/env python3
"""Recall #40/#50: files closed behind Wine's back when a thread exits, against a real engine.

Under msync (Recall's launch settings), Wine stored a thread's alert index from the server where
it keeps the thread's alert descriptor, and closed it when the thread exited. That closed
whatever file the process had under that number: in Overwatch a game archive, whose next read
then went to another thread's pipe and failed with error 1 ("TACT File read failed with error:
1", then the crash reading 0x40). patches/wine-ntdll-syscall-log.patch leaves the index alone.

Runs alert_probe.c (workers that make an alertable wait and exit once 1,000 files are open) under
the engine's Wine, with Recall's launch environment, in a new scratch Windows environment, three
times. Passes when no read fails and every read returns the file's own data. With --control
ENGINE, also runs an engine without the change, to show the failures (about one per worker
whose index is one of the open files).

No game, account or Battle.net; needs Rosetta and Wine outside the command sandbox. Wine's server
for the scratch root is stopped at exit.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--engine', type=Path, required=True, help='an extracted runtime with the change')
    p.add_argument('--control', type=Path, help='an extracted runtime without it')
    p.add_argument('--root', type=Path, required=True, help='new scratch folder outside the checkout')
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--runs', type=int, default=3)
    a = p.parse_args()
    root, out = a.root.resolve(), a.output.resolve()
    if root.is_relative_to(ROOT) or root.exists():
        p.error('Use a new scratch root outside the checkout; an existing one is never adopted')
    root.mkdir(parents=True)
    out.mkdir(parents=True, exist_ok=True)
    probe = out / 'alert-probe.exe'
    compiler = ROOT / 'runtime/toolchains/llvm-mingw-20251216-ucrt-macos-universal/bin/x86_64-w64-mingw32-gcc'
    subprocess.run([str(compiler), '-O2', '-g0', '-Wall', '-Wextra', '-Wno-unused-parameter', '-Werror',
                    str(Path(__file__).parent / 'alert_probe.c'), '-o', str(probe)], check=True)
    data = root / 'data.bin'
    data.write_bytes(os.urandom(65536))
    contract = json.loads((ROOT / 'docs/candidate-parity-contract.json').read_text())['environment']

    def environment(engine):
        return dict(contract, PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME=str(root / 'home'), USER='player',
                    TMPDIR=str(root / 'tmp'), WINEPREFIX=str(root / 'environment'), WINEARCH='win64',
                    WINESERVER=str(engine / 'bin/wineserver'), WINELOADER=str(engine / 'bin/wine'), WINEDEBUG='-all',
                    WINEDLLOVERRIDES='mscoree,mshtml=', CX_APPLEGPTK_LIBD3DSHARED_PATH=str(engine / 'lib/external/libd3dshared.dylib'))

    def run(engine):
        env = environment(engine)
        (root / 'home').mkdir(exist_ok=True)
        (root / 'tmp').mkdir(exist_ok=True)
        try:
            r = subprocess.run([str(engine / 'bin/wine'), str(probe), 'Z:' + str(data).replace('/', '\\')], env=env,
                               cwd=root, capture_output=True, text=True, timeout=600)
            lines = [json.loads(line) for line in r.stdout.splitlines() if line.startswith('{')]
            return lines[-1] if lines else {'error': 'no result', 'stderr': r.stderr[-400:]}
        finally:
            subprocess.run([str(engine / 'bin/wineserver'), '-k'], env=env, timeout=60)
            subprocess.run([str(engine / 'bin/wineserver'), '-w'], env=env, timeout=60)

    results = {'engine': [run(a.engine.resolve()) for _ in range(a.runs)]}
    if a.control:
        results['control'] = [run(a.control.resolve()) for _ in range(a.runs)]
    passed = all(r.get('failed') == 0 and r.get('wrong_data') == 0 for r in results['engine'])
    shown = not a.control or any(r.get('failed', 0) + r.get('wrong_data', 0) > 0 for r in results['control'])
    results['passed'] = passed
    if a.control:
        results['control_shows_the_failure'] = shown
    (out / 'results.json').write_text(json.dumps(results, indent=1) + '\n')
    print(json.dumps(results, indent=1))
    raise SystemExit(0 if passed and shown else 1)


if __name__ == '__main__':
    main()
