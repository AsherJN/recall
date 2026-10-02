#!/usr/bin/env python3
"""Mouselook driver probe: shooter-style cursor handling, previous behaviour versus mouselook.

Runs tests/mouselook/probe.c three times on the mouselook test runtime (scripts/mouselook_session.py
prepare): with mouselook not allowed (the previous behaviour, same driver), with mouselook from pointer
events only (WINEMAC_MOUSELOOK_RAW=0), and with mouselook and raw input, the default. The probe takes
the foreground and moves the pointer for about 15 seconds per run.
Uses a scratch Windows prefix under runtime/mouselook, never the Overwatch environment.
Exit status 1 if mouselook does not engage, raw input does not start inside Wine or find a mouse,
raw input slows re-centring, or any cursor position the game can see changes. Real mouse motion needs the play-test: macOS gives
the probe no way to move the mouse itself.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import mouselook_session  # noqa: E402

WORK = ROOT / 'runtime/mouselook'
PREFIX = WORK / 'probe-prefix'
EXE = WORK / 'probe/mouselook_probe.exe'
SOURCE = Path(__file__).resolve().parent / 'probe.c'
MINGW = ROOT / 'runtime/toolchains/llvm-mingw-20251216-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang'
ENGINE = mouselook_session.ENGINE


def environment(extra=None):
    env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(WORK / 'probe-home'), 'USER': 'player',
           'WINEPREFIX': str(PREFIX), 'WINEARCH': 'win64', 'WINESERVER': str(ENGINE / 'bin/wineserver'),
           'WINELOADER': str(ENGINE / 'bin/wine'), 'WINEDEBUG': '-all', 'WINEMSYNC': '1',
           'WINEDLLOVERRIDES': 'mscoree,mshtml='}
    env.update(extra or {})
    return env


def wine(args, extra=None, timeout=180):
    return subprocess.run([str(ENGINE / 'bin/wine'), *map(str, args)], env=environment(extra),
                          capture_output=True, text=True, timeout=timeout)


def server(flag):
    subprocess.run([str(ENGINE / 'bin/wineserver'), flag], env=environment(), capture_output=True, timeout=120)


def prepare():
    mouselook_session.prepare()
    if not EXE.exists() or EXE.stat().st_mtime < SOURCE.stat().st_mtime:
        EXE.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([str(MINGW), '-O2', '-Wall', '-o', str(EXE), str(SOURCE), '-luser32'], check=True)
    if not (PREFIX / 'system.reg').exists():
        (WORK / 'probe-home').mkdir(parents=True, exist_ok=True)
        wine(['wineboot', '-i'], timeout=600)
        server('-w')


def run(allowed, raw=True):
    with tempfile.TemporaryDirectory() as tmp:
        extra = {'WINEMAC_INPUT_STATS': os.path.join(tmp, 'input')}
        if allowed:
            extra['WINEMAC_MOUSELOOK'] = EXE.name
        if allowed and not raw:
            extra['WINEMAC_MOUSELOOK_RAW'] = '0'
        result = wine([EXE], extra)
        server('-k')
        phases = {}
        for line in result.stdout.splitlines():
            if line.startswith('{'):
                value = json.loads(line)
                phases[value['phase']] = value
        stats = [json.loads(line) for path in Path(tmp).glob('input-*.jsonl')
                 for line in path.read_text().splitlines() if line.startswith('{')]
    stats = [line for line in stats if line['exe'].lower() == EXE.name]
    totals = {key: sum(line[key] for line in stats) for key in
              ('warps', 'setpos_calls', 'setpos_fast', 'mouselook_enters', 'mouselook_exits')}
    totals['mouselook_seen'] = any(line['mode'] in ('mouselook', 'raw') for line in stats)
    totals['raw_seen'] = any(line['mode'] == 'raw' for line in stats)
    totals['raw_started'] = any(line.get('raw_started') for line in stats)
    totals['raw_mice'] = max((line.get('raw_mice', 0) for line in stats), default=0)
    totals['clip_handler'] = sorted({line['clip_handler'] for line in stats})
    return {'phases': phases, 'driver': totals, 'exit_status': result.returncode}


def main():
    prepare()
    results = {'previous': run(False), 'pointer': run(True, raw=False), 'mouselook': run(True)}
    failures = []
    for mode, result in results.items():
        if set(result['phases']) != {'visible', 'aiming'}:
            failures.append(f'{mode}: the probe did not finish (exit status {result["exit_status"]})')
            continue
        for phase in result['phases'].values():
            if not phase['foreground']:
                failures.append(f'{mode}/{phase["phase"]}: the probe window was not in front; rerun without touching the Mac')
            for check in ('readback_mismatches',):
                if phase[check]:
                    failures.append(f'{mode}/{phase["phase"]}: {phase[check]} cursor read-backs differed from the position set')
            for check in ('idle_position_ok', 'pointer_after_ok'):
                if not phase[check]:
                    failures.append(f'{mode}/{phase["phase"]}: {check} failed')
    mouselook, pointer, previous = results['mouselook'], results['pointer'], results['previous']
    if not failures:
        for name in ('pointer', 'mouselook'):
            if not results[name]['driver']['mouselook_seen'] or not results[name]['driver']['mouselook_exits']:
                failures.append(f'{name}: mouselook did not engage and release during the aiming phase')
        if pointer['driver']['raw_started']:
            failures.append('raw input started although WINEMAC_MOUSELOOK_RAW=0')
        if previous['driver']['mouselook_seen'] or previous['driver']['raw_started']:
            failures.append('mouselook or raw input engaged although it was not allowed')
        if not mouselook['driver']['raw_started'] or not mouselook['driver']['raw_seen']:
            failures.append('raw input did not start inside Wine (Game Controller framework)')
        elif not mouselook['driver']['raw_mice']:
            failures.append('raw input found no mouse (GCMouse)')
        # Without the Mac pointer, a re-centre is Wine's own server work only.
        fast, slow = mouselook['phases']['aiming']['setpos_median_us'], previous['phases']['aiming']['setpos_median_us']
        if fast > 150 or fast * 4 > slow:
            failures.append(f're-centring still waits in mouselook ({fast:.0f} us versus {slow:.0f} us before)')
        # Raw input must leave the re-centre fast path alone.
        plain = pointer['phases']['aiming']['setpos_median_us']
        if fast > plain * 1.5 + 25:
            failures.append(f're-centring is slower with raw input ({fast:.0f} us versus {plain:.0f} us without)')
    print(f'{"run/phase":20} {"frame ms":>9} {"re-centre median":>17} {"mean":>9} {"p99":>9} {"max":>9} {"server trip":>12}')
    for mode, result in results.items():
        for name, phase in result['phases'].items():
            print(f'{mode + "/" + name:20} {phase["frame_mean_us"] / 1000:>9.2f} '
                  f'{phase["setpos_median_us"]:>14.1f} us {phase["setpos_mean_us"]:>6.0f} us '
                  f'{phase["setpos_p99_us"]:>6.0f} us {phase["setpos_max_us"]:>6.0f} us {phase["server_roundtrip_us"]:>9.1f} us')
        print(f'{"":20} driver: {json.dumps(result["driver"])}')
    output = WORK / 'probe/last-result.json'
    output.write_text(json.dumps({'results': results, 'failures': failures}, indent=2) + '\n')
    print('\n'.join(['FAIL: ' + failure for failure in failures]) if failures else 'PASS')
    sys.exit(1 if failures else 0)


if __name__ == '__main__':
    main()
