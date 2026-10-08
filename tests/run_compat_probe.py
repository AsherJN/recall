#!/usr/bin/env python3
"""Check Settings › Advanced against a real engine, in a fresh scratch installation.

Installs the archive with the given worker, prepares a new Windows environment, then
runs portable_compat_probe.c under that engine's Wine with each setting off and on:
- automatic proxy detection: off after setup, on and off again from Settings;
- Korean account support: the certificate chain Windows builds for INTERMEDIATE (a
  certificate DigiCert Trusted Root G4 issued, such as DigiCert Trusted G4 Code Signing
  RSA4096 SHA384 2021 CA1) ends at the self-signed G4 without it and at DigiCert Assured
  ID Root CA with it; reading the screen back fails without it and gives black with it.
Needs Rosetta, a display session and Wine outside the command sandbox. No game,
account or Battle.net is involved; Wine's server for the scratch root is stopped at exit.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ASSURED_ID = '0563B8630D62D75ABBC8AB1E4BDFB5A899B24D43'  # DigiCert Assured ID Root CA (SHA-1)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--archive', type=Path, required=True)
    p.add_argument('--sha256', required=True)
    p.add_argument('--version', required=True)
    p.add_argument('--worker', type=Path, required=True)
    p.add_argument('--intermediate', type=Path, required=True, help='DER certificate issued by DigiCert Trusted Root G4')
    p.add_argument('--root', type=Path, required=True, help='new scratch installation folder (outside the checkout)')
    p.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    root, out, worker = a.root.resolve(), a.output.resolve(), a.worker.resolve()
    if root.is_relative_to(ROOT) or root.exists():
        p.error('Use a new scratch root outside the checkout; an existing one is never adopted')
    out.mkdir(parents=True, exist_ok=True)
    probe = out / 'portable-compat-probe.exe'
    compiler = ROOT / 'runtime/toolchains/llvm-mingw-20251216-ucrt-macos-universal/bin/x86_64-w64-mingw32-gcc'
    subprocess.run([str(compiler), '-O2', '-g0', '-Wall', '-Wextra', '-Werror', str(ROOT / 'tests/portable_compat_probe.c'),
                    '-o', str(probe), '-lwinhttp', '-lcrypt32', '-lgdi32', '-luser32'], check=True)
    intermediate = root.parent / (root.name + '-intermediate.crt')
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

    def run(label, *args, readback=False):
        # A fresh server for each run, as Battle.net starts after setup has settled.
        subprocess.run([str(engine / 'bin/wineserver'), '-w'], env=env, timeout=60)
        run_env = dict(env, WINEMAC_SCREEN_READBACK='1') if readback else env
        r = subprocess.run([str(engine / 'bin/wine'), str(probe), *args], env=run_env, cwd=root, capture_output=True,
                           text=True, timeout=120)
        line = next((l for l in r.stdout.splitlines() if l.startswith('{')), '{}')
        results[label] = json.loads(line)
        (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        return results[label]

    try:
        setup('install-runtime', '--archive', a.archive.resolve(), '--sha256', a.sha256, '--version', a.version)
        setup('prepare')
        shutil.copyfile(a.intermediate, intermediate)
        chain = ['chain', 'Z:' + str(intermediate).replace('/', '\\')]
        checks = {
            'setup: no automatic proxy detection': run('proxy after setup', 'proxy').get('auto_detect') == 0,
            'off: chain ends at the self-signed G4': run('chain, Korean off', *chain).get('root') not in (None, ASSURED_ID),
            'off: screen read fails as before': run('screen, Korean off', 'screen').get('stretchblt') == 0,
        }
        setup('korean-support', '--enabled', '1')
        checks['on: chain ends at Assured ID Root CA'] = run('chain, Korean on', *chain).get('root') == ASSURED_ID
        screen = run('screen, Korean on', 'screen', readback=True)
        checks['on: screen read gives black'] = (screen.get('stretchblt'), screen.get('bitblt'),
                                                 screen.get('stretchblt_pixel'), screen.get('bitblt_pixel')) == (1, 1, '00000000', '00000000')
        setup('network', '--proxy-detect', '1')
        checks['detection on from Settings'] = run('proxy on', 'proxy').get('auto_detect') == 1
        setup('network', '--proxy-detect', '0')
        checks['detection off again'] = run('proxy off', 'proxy').get('auto_detect') == 0
        setup('korean-support', '--enabled', '0')
        checks['Korean off again: chain as before'] = run('chain, Korean off again', *chain).get('root') == results['chain, Korean off'].get('root')
    finally:
        if engine.exists():
            subprocess.run([str(engine / 'bin/wineserver'), '-k'], env=env, timeout=60)
        intermediate.unlink(missing_ok=True)
    (out / 'checks.json').write_text(json.dumps(checks, indent=2) + '\n')
    print(json.dumps({'checks': checks, 'results': results}, indent=2))
    raise SystemExit(0 if all(checks.values()) else 1)


if __name__ == '__main__':
    main()
