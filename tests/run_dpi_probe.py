#!/usr/bin/env python3
"""Check Battle.net's own DPI (WINE_APP_DPI) against a real engine, in a fresh scratch installation.

Installs the archive with the given worker, prepares a new Windows environment, then runs
portable_dpi_probe.c under that engine's Wine as Battle.net.exe and as Overwatch.exe, each
time in a fresh Wine session:
- without WINE_APP_DPI, both see the session's 96 DPI, as before;
- with WINE_APP_DPI=192:Battle.net.exe, Battle.net sees 192 for the system and every
  monitor, and Overwatch, started in the same session, still sees 96 everywhere, whichever
  of them starts the session (and so fills Wine's shared display cache);
- the display cache itself stays at 96 either way.
Needs Rosetta, a display session and Wine outside the command sandbox. No game, account or
Battle.net is involved; Wine's server for the scratch root is stopped at exit.
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]
APP_DPI = '192:Battle.net.exe;Battle.net Launcher.exe'


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
    compiler = ROOT / 'runtime/toolchains/llvm-mingw-20251216-ucrt-macos-universal/bin/x86_64-w64-mingw32-gcc'
    probe = out / 'portable-dpi-probe.exe'
    subprocess.run([str(compiler), '-O2', '-g0', '-Wall', '-Wextra', '-Werror', str(ROOT / 'tests/portable_dpi_probe.c'),
                    '-o', str(probe), '-lshcore', '-luser32', '-lgdi32', '-ladvapi32'], check=True)
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
    programs = root / 'environment/drive_c/dpi-probe'

    def start(name, awareness, app_dpi, hold=0):
        run_env = dict(env, WINE_APP_DPI=app_dpi) if app_dpi else env
        return subprocess.Popen([str(engine / 'bin/wine'), str(programs / name), awareness, *([str(hold)] if hold else [])],
                                env=run_env, cwd=root, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)

    def line(process):
        for text in process.stdout:
            if text.startswith('{'):
                return json.loads(text)
        return {}

    def session(label, first, second, awareness='pmv2', app_dpi=APP_DPI):
        """FIRST starts a fresh session and stays open while SECOND runs in it."""
        subprocess.run([str(engine / 'bin/wineserver'), '-k'], env=env, timeout=60)
        subprocess.run([str(engine / 'bin/wineserver'), '-w'], env=env, timeout=60)
        holder = start(first, awareness, app_dpi, hold=20000)
        seen = {first: line(holder)}
        if second:
            seen[second] = line(start(second, awareness, app_dpi))
        holder.wait(timeout=120)
        results[label] = seen
        (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        return seen

    def dpis(seen):
        """Every DPI a program reports: system, screen device, monitors, its window."""
        if not seen.get('monitors'):
            return None
        return {seen['system'], seen['caps'], seen['window']['dpi'], *(m['effective'] for m in seen['monitors'])}

    try:
        setup('install-runtime', '--archive', a.archive.resolve(), '--sha256', a.sha256, '--version', a.version)
        setup('prepare')
        programs.mkdir()
        for name in ('Battle.net.exe', 'Overwatch.exe'):
            shutil.copyfile(probe, programs / name)
        before = session('without WINE_APP_DPI', 'Battle.net.exe', 'Overwatch.exe', app_dpi=None)
        bnet_first = session('Battle.net starts the session', 'Battle.net.exe', 'Overwatch.exe')
        game_first = session('Overwatch starts the session', 'Overwatch.exe', 'Battle.net.exe')
        system = session('Battle.net system-aware', 'Battle.net.exe', 'Overwatch.exe', awareness='system')
        checks = {
            'off: Battle.net sees 96 as before': dpis(before['Battle.net.exe']) == {96},
            'off: Overwatch sees 96 as before': dpis(before['Overwatch.exe']) == {96},
            'on, Battle.net first: Battle.net sees 192': dpis(bnet_first['Battle.net.exe']) == {192},
            'on, Battle.net first: Overwatch sees 96': dpis(bnet_first['Overwatch.exe']) == {96},
            'on, Overwatch first: Overwatch sees 96': dpis(game_first['Overwatch.exe']) == {96},
            'on, Overwatch first: Battle.net sees 192': dpis(game_first['Battle.net.exe']) == {192},
            'on, system-aware: Battle.net sees 192': dpis(system['Battle.net.exe']) == {192},
            'on, system-aware: Overwatch sees 96': dpis(system['Overwatch.exe']) == {96},
            'display cache stays at 96': all(set(s.get('cached') or [0]) == {96}
                                            for run in results.values() for s in run.values()),
            'screen size unchanged for both': len({tuple(s['screen']) for run in results.values() for s in run.values()}) == 1,
        }
        results['checks'] = checks
        (out / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
        print(json.dumps(checks, indent=2))
        return 0 if all(checks.values()) else 1
    finally:
        subprocess.run([str(engine / 'bin/wineserver'), '-k'], env=env, timeout=60)


if __name__ == '__main__':
    raise SystemExit(main())
