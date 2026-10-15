#!/usr/bin/env python3
"""Check Chinese and Korean text against a real engine, in a fresh scratch installation.

Installs the archive with the given worker, chooses Global Battle.net in English and prepares a
new Windows environment, then runs portable_font_probe.c under that engine's Wine: Chinese and
Korean draw as boxes, as in 1.3.1. Then it chooses Simplified Chinese, has the worker add its
font replacements (portable_region.h) and runs the probe again: every GDI face draws both, the
replaced families exist for DirectWrite and its system fallback finds a font for both scripts
in Chinese, Korean and English locales. Needs Rosetta, a display session and Wine outside the
command sandbox. No game, account or Battle.net is involved; Wine's server for the scratch root
is stopped at exit.
"""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--archive', type=Path, required=True)
    p.add_argument('--sha256', required=True)
    p.add_argument('--version', required=True)
    p.add_argument('--worker', type=Path, required=True)
    p.add_argument('--root', type=Path, required=True, help='new scratch installation folder (outside the checkout)')
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    root, out, worker = a.root.resolve(), a.output.resolve(), a.worker.resolve()
    if root.is_relative_to(ROOT) or root.exists():
        p.error('Use a new scratch root outside the checkout; an existing one is never adopted')
    out.mkdir(parents=True, exist_ok=True)
    root.parent.mkdir(parents=True, exist_ok=True)  # the worker never creates a missing parent
    probe = out / 'portable-font-probe.exe'
    compiler = ROOT / 'runtime/toolchains/llvm-mingw-20251216-ucrt-macos-universal/bin/x86_64-w64-mingw32-gcc'
    subprocess.run([str(compiler), '-O2', '-g0', '-Wall', '-Wextra', '-Werror', str(ROOT / 'tests/portable_font_probe.c'),
                    '-o', str(probe), '-ldwrite', '-lgdi32'], check=True)
    events, results = [], {}

    def setup(command, *args):
        r = subprocess.run([str(worker), command, '--root', str(root), *map(str, args)], capture_output=True, text=True, timeout=600)
        events.extend(json.loads(line) for line in r.stdout.splitlines())
        (out / 'setup-events.json').write_text(json.dumps(events, indent=2) + '\n')
        if r.returncode:
            raise RuntimeError(f'{command} failed: ' + r.stdout)

    engine = root / 'runtimes' / a.version
    contract = json.loads((ROOT / 'docs/candidate-parity-contract.json').read_text())['environment']
    env = dict(contract, PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME=str(root / 'home'), USER='player', TMPDIR=str(root / 'tmp'),
               WINEPREFIX=str(root / 'environment'), WINEARCH='win64', WINESERVER=str(engine / 'bin/wineserver'),
               WINELOADER=str(engine / 'bin/wine'), WINEDEBUG='-all',
               CX_APPLEGPTK_LIBD3DSHARED_PATH=str(engine / 'lib/external/libd3dshared.dylib'))

    def run(label):
        # A fresh server, so Wine reads the fonts and the registry as a new session would.
        subprocess.run([str(engine / 'bin/wineserver'), '-w'], env=env, timeout=60)
        r = subprocess.run([str(engine / 'bin/wine'), str(probe)], env=env, cwd=root, capture_output=True, text=True, timeout=300)
        results[label] = [json.loads(l) for l in r.stdout.splitlines() if l.startswith('{')]
        (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        return results[label]

    def gdi(rows, key):
        return [r[key] for r in rows if 'gdi' in r]

    try:
        setup('install-runtime', '--archive', a.archive.resolve(), '--sha256', a.sha256, '--version', a.version)
        setup('battlenet', '--region', 'global', '--language', 'enUS')
        setup('prepare')
        english = run('English')
        checks = {
            'English: no replacements added': not [e for e in events if e.get('stage') == 'fonts'],
            'English: Chinese draws as boxes, as in 1.3.1': not all(gdi(english, 'han')),
        }
        setup('battlenet', '--region', 'global', '--language', 'zhCN')
        setup('fonts')
        chinese = run('Simplified Chinese')
        fallbacks = [r for r in chinese if 'fallback' in r]
        checks.update({
            'Chinese: replacements added': any(e.get('stage') == 'fonts' and e.get('changed') for e in events),
            'Chinese: every GDI face draws Chinese': all(gdi(chinese, 'han')),
            'Chinese: every GDI face draws Korean': all(gdi(chinese, 'hangul')),
            'Chinese: replaced families exist for DirectWrite': all(r['exists'] for r in chinese if 'exists' in r),
            'Chinese: DirectWrite falls back to a font in every locale': len(fallbacks) == 4 and all(r['family'] for r in fallbacks),
        })
    finally:
        if engine.exists():
            subprocess.run([str(engine / 'bin/wineserver'), '-k'], env=env, timeout=60)
    (out / 'checks.json').write_text(json.dumps(checks, indent=2) + '\n')
    print(json.dumps({'checks': checks, 'results': results}, indent=2, ensure_ascii=False))
    raise SystemExit(0 if all(checks.values()) else 1)


if __name__ == '__main__':
    main()
