#!/usr/bin/env python3
"""Recall #46: a keyboard layout chosen in macOS while a program runs reaches it, against a real engine.

Runs layout_probe.c under the engine's Wine, with Recall's launch environment, in a new scratch
Windows environment. While the probe's window is in front, input_source.c selects LAYOUT, then
the input source that was selected before. Passes when the character the probe's Q key types
changes to LAYOUT's and back. With --control ENGINE, also runs an engine without the change and
reports whether it followed (in a plain window macOS's current input context is usually the
window's own, which the engine without the change needs; Overwatch's often is not).

Takes over the screen for about ten seconds per engine: the probe's window comes to the front,
and the selected input source changes. LAYOUT is enabled for the test if it was not, and
disabled again afterwards; the input source selected before is always selected again at exit.
Ask the owner before each run. No game, account or Battle.net; needs Rosetta and Wine outside
the command sandbox. Wine's server for the scratch root is stopped at exit.
"""
import argparse
import json
from pathlib import Path
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[2]


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--engine', type=Path, required=True, help='an extracted runtime with the change')
    p.add_argument('--control', type=Path, help='an extracted runtime without it')
    p.add_argument('--root', type=Path, required=True, help='new scratch folder outside the checkout')
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--layout', default='com.apple.keylayout.Russian', help='input source to switch to')
    a = p.parse_args()
    root, out = a.root.resolve(), a.output.resolve()
    if root.is_relative_to(ROOT) or root.exists():
        p.error('Use a new scratch root outside the checkout; an existing one is never adopted')
    root.mkdir(parents=True)
    out.mkdir(parents=True, exist_ok=True)
    here = Path(__file__).parent
    probe, tool = out / 'layout-probe.exe', out / 'input-source'
    compiler = ROOT / 'runtime/toolchains/llvm-mingw-20251216-ucrt-macos-universal/bin/x86_64-w64-mingw32-gcc'
    subprocess.run([str(compiler), '-O2', '-g0', '-Wall', '-Wextra', '-Wno-unused-parameter', '-Werror',
                    str(here / 'layout_probe.c'), '-o', str(probe)], check=True)
    subprocess.run(['/usr/bin/clang', '-O2', '-Wall', '-Werror', '-framework', 'Carbon', str(here / 'input_source.c'),
                    '-o', str(tool)], check=True)
    contract = json.loads((ROOT / 'docs/candidate-parity-contract.json').read_text())['environment']

    def source(*args):
        r = subprocess.run([str(tool), *args], capture_output=True, text=True)
        if r.returncode:
            raise SystemExit(f'input_source {" ".join(args)} failed')
        return r.stdout.strip()

    def environment(engine):
        return dict(contract, PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME=str(root / 'home'), USER='player',
                    TMPDIR=str(root / 'tmp'), WINEPREFIX=str(root / 'environment'), WINEARCH='win64',
                    WINESERVER=str(engine / 'bin/wineserver'), WINELOADER=str(engine / 'bin/wine'), WINEDEBUG='-all',
                    WINEDLLOVERRIDES='mscoree,mshtml=', CX_APPLEGPTK_LIBD3DSHARED_PATH=str(engine / 'lib/external/libd3dshared.dylib'))

    def front():
        asn = subprocess.run(['/usr/bin/lsappinfo', 'front'], capture_output=True, text=True).stdout.strip()
        r = subprocess.run(['/usr/bin/lsappinfo', 'info', '-only', 'name', asn], capture_output=True, text=True)
        return r.stdout.strip()

    def run(engine, original):
        env = environment(engine)
        (root / 'home').mkdir(exist_ok=True)
        (root / 'tmp').mkdir(exist_ok=True)
        lines, ready = [], threading.Event()
        try:
            process = subprocess.Popen([str(engine / 'bin/wine'), str(probe), '10'], env=env, cwd=root,
                                       stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)

            def read():
                for line in process.stdout:
                    if line.startswith('{'):
                        lines.append(json.loads(line))
                        if lines[-1].get('ready'):
                            ready.set()
            threading.Thread(target=read, daemon=True).start()
            if not ready.wait(300):
                process.kill()
                return {'error': 'the probe never opened its window'}
            started = time.monotonic()
            time.sleep(2)
            in_front = front()
            switched = time.monotonic()
            source('select', a.layout)
            time.sleep(3)
            back = time.monotonic()
            source('select', original)
            process.wait(timeout=60)
        finally:
            source('select', original)
            subprocess.run([str(engine / 'bin/wineserver'), '-k'], env=env, timeout=60)
            subprocess.run([str(engine / 'bin/wineserver'), '-w'], env=env, timeout=60)
        to_ms = lambda t: (t - started) * 1000
        samples = [line for line in lines if 'q' in line]
        before = [s['q'] for s in samples if s['ms'] < to_ms(switched)]
        during = [s['q'] for s in samples if to_ms(switched) + 1000 <= s['ms'] < to_ms(back)]
        after = [s['q'] for s in samples if s['ms'] >= to_ms(back) + 1500]
        first = before[0] if before else None
        layouts = lambda low, high: sorted({s['hkl'] for s in samples if low <= s['ms'] < high})
        return {'front_app': in_front, 'foreground': lines[0].get('foreground') if lines else None,
                'hkl_before': layouts(0, to_ms(switched)), 'hkl_during': layouts(to_ms(switched) + 1000, to_ms(back)),
                'q_before': first, 'q_during': sorted(set(during)), 'q_after': sorted(set(after)),
                'followed': bool(during) and all(q != first for q in during),
                'returned': bool(after) and all(q == first for q in after),
                'inputlangchange': [line for line in lines if 'inputlangchange' in line]}

    original = source('current')
    enabled_here = source('enabled', a.layout) == '0'
    try:
        if enabled_here:
            source('enable', a.layout)
        results = {'layout': a.layout, 'original': original, 'engine': run(a.engine.resolve(), original)}
        if a.control:
            results['control'] = run(a.control.resolve(), original)
    finally:
        source('select', original)
        if enabled_here:
            source('disable', a.layout)
    results['restored'] = source('current') == original and (not enabled_here or source('enabled', a.layout) == '0')
    results['passed'] = results['engine'].get('followed') and results['engine'].get('returned')
    (out / 'results.json').write_text(json.dumps(results, indent=1) + '\n')
    print(json.dumps(results, indent=1))
    raise SystemExit(0 if results['passed'] and results['restored'] else 1)


if __name__ == '__main__':
    main()
