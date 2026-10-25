#!/usr/bin/env python3
"""Display modes probe (REC-45): does the game's picture fill its window in every mode?

Runs tests/display_modes/probe.c on the mouselook test engine (scripts/mouselook_session.py
prepare: the installed engine with the driver from `build_wine_native.py winemac`), in a
scratch Windows prefix with Retina mode on, as players have it. The probe switches between
fullscreen, windowed, borderless and maximized the way Overwatch does, drawing solid green.
After each step it checks, once the window has settled:
  - picture: a screenshot of the window's content area is green (none of the window's gray
    background showing), and
  - geometry: the window driver draws the picture exactly where Wine has the window's
    client area, so clicks land where they are seen (DXMT_CANVAS_LOG): the content view
    is unscaled outside fullscreen, the client view sits at Wine's client rectangle and
    the Metal view fills it.
Takes over the main display for about a minute; ask the owner first. Never touches the
Overwatch environment. Exit status 1 if any step fails.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import candidate_contract  # noqa: E402
import mouselook_session  # noqa: E402

WORK = ROOT / 'runtime/display-modes'
PREFIX = WORK / 'prefix'
HOME = WORK / 'home'
EXE = WORK / 'display_probe.exe'
LISTER = WORK / 'window_list'
SOURCE = Path(__file__).resolve().parent / 'probe.c'
MINGW = ROOT / 'runtime/toolchains/llvm-mingw-20251216-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang'
ENGINE = mouselook_session.ENGINE
LOGS = ROOT / 'logs/display-modes'
# A prefix made by tests/mouselook/run.py in another worktree saves a wineboot (APFS clone).
SEED_PREFIXES = sorted(ROOT.parent.glob('*/runtime/mouselook/probe-prefix'))
# Overwatch's own sequence: start windowed, fullscreen, then every mode change through fullscreen.
STEPS = ['fullscreen', 'windowed:2560x1440', 'fullscreen', 'borderless', 'windowed:1600x900', 'maximize',
         'fullscreen', 'windowed:1920x1080']
SETTLE_S = 2.5
GREEN_MIN = 0.98   # share of the picture's interior that must be the probe's green
EDGE_MIN = 0.9     # share of each side's border line that must be red
TITLE_BAR_MAX = 40  # points


def environment(session, extra=None):
    contract = candidate_contract.load()
    env = {k: v for k, v in contract['environment'].items()
           if not k.startswith(('WINEMAC_MOUSELOOK', 'WINEMAC_INPUT', 'WINE_GAME_MODE', 'DXMT_PIPELINE', 'DXMT_PREPARE'))}
    env.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME=str(HOME), USER='player', WINEPREFIX=str(PREFIX),
               WINEARCH='win64', WINESERVER=str(ENGINE / 'bin/wineserver'), WINELOADER=str(ENGINE / 'bin/wine'),
               WINEDEBUG='-all', CX_APPLEGPTK_LIBD3DSHARED_PATH=str(ENGINE / 'lib/external/libd3dshared.dylib'),
               DXMT_LOG_LEVEL='error', DXMT_LOG_PATH='none', DXMT_SHADER_CACHE_PATH=str(WORK / 'shaders'))
    if session:
        env.update(DXMT_CONFIG_FILE=mouselook_session.windows_path(session / 'dxmt.conf'),
                   DXMT_CANVAS_LOG=str(session / 'canvas'),
                   DXMT_WINDOW_LOG=mouselook_session.windows_path(session / 'window'),
                   DXMT_GEOMETRY_LOG=mouselook_session.windows_path(session / 'geometry'))
    env.update(extra or {})
    return env


def wine(args, timeout=600):
    return subprocess.run([str(ENGINE / 'bin/wine'), *map(str, args)], env=environment(None),
                          capture_output=True, text=True, timeout=timeout)


def server(flag):
    subprocess.run([str(ENGINE / 'bin/wineserver'), flag], env=environment(None), capture_output=True, timeout=120)


def prepare_probe_only():
    """The probe and the window lister, rebuilt when their sources change."""
    WORK.mkdir(parents=True, exist_ok=True)
    if not EXE.exists() or EXE.stat().st_mtime < SOURCE.stat().st_mtime:
        subprocess.run([str(MINGW), '-O2', '-Wall', '-o', str(EXE), str(SOURCE), '-ld3d11', '-ldxgi', '-luser32',
                        '-ldxguid'], check=True)
    lister_source = ROOT / 'scripts/owned_window_control.m'
    if not LISTER.exists() or LISTER.stat().st_mtime < lister_source.stat().st_mtime:
        subprocess.run(['/usr/bin/clang', '-fobjc-arc', '-framework', 'Cocoa', '-framework', 'ApplicationServices',
                        str(lister_source), '-o', str(LISTER)], check=True)


def prepare():
    runtime = mouselook_session.prepare()
    prepare_probe_only()
    HOME.mkdir(exist_ok=True)
    if not (PREFIX / 'system.reg').exists():
        seeds = [p for p in SEED_PREFIXES if (p / 'system.reg').is_file()]
        if seeds:
            subprocess.run(['/bin/cp', '-Rc', str(seeds[0]), str(PREFIX)], check=True)
        else:
            result = wine(['wineboot', '-i'])
            if result.returncode:
                raise SystemExit('wineboot failed: ' + result.stderr[-2000:])
    if '"RetinaMode"="Y"' not in (PREFIX / 'user.reg').read_text(errors='replace'):
        # As the worker does for players (portable_retina.h).
        wine(['reg.exe', 'add', r'HKCU\Software\Wine\Mac Driver', '/v', 'RetinaMode', '/d', 'Y', '/f'])
        server('-w')
        if '"RetinaMode"="Y"' not in (PREFIX / 'user.reg').read_text(errors='replace'):
            raise SystemExit('Could not turn on Retina mode in the probe prefix')
    return runtime


def processes():
    return list(mouselook_session.processes())


def probe_pid():
    for pid, command in processes():
        if command.endswith('display_probe.exe'):
            return pid
    return None


def window_bounds(pid):
    """The probe's largest on-screen window, in global points (top-left origin)."""
    out = subprocess.run([str(LISTER), str(pid), 'windows'], capture_output=True, text=True, timeout=10).stdout
    # Any level: Wine raises a window covering a screen above the menu bar (cocoa_app.m).
    windows = [w for w in json.loads(out or '[]') if w['onscreen'] and 0 <= w['layer'] < 1000]
    if not windows:
        return None
    best = max(windows, key=lambda w: w['bounds']['Width'] * w['bounds']['Height'])
    b = best['bounds']
    return [b['X'], b['Y'], b['Width'], b['Height']]


def capture(rect, path):
    x, y, w, h = rect
    subprocess.run(['/usr/sbin/screencapture', '-x', '-t', 'bmp', f'-R{x},{y},{w},{h}', str(path)], check=True,
                   timeout=20)


def read_bmp(path):
    data = path.read_bytes()
    offset, = struct.unpack_from('<I', data, 10)
    width, height, _, bits = struct.unpack_from('<iiHH', data, 18)
    if bits not in (24, 32):
        raise RuntimeError(f'{path.name}: {bits}-bit BMP')
    step = bits // 8
    stride = (width * step + 3) & ~3
    top_down = height < 0
    height = abs(height)

    def pixel(x, y):
        row = y if top_down else height - 1 - y
        i = offset + row * stride + x * step
        b, g, r = data[i], data[i + 1], data[i + 2]
        return r, g, b
    return width, height, pixel


def picture(path, backbuffer, edge):
    """How the probe's picture sits in a screenshot of the content area. The picture is green
    inside a red border edge backbuffer pixels wide: interior is the green share of the area
    inside the border, edges the red share along a line through each side's border. A picture
    drawn too small leaves the window's gray on the right and bottom; one drawn too large
    loses its border."""
    width, height, pixel = read_bmp(path)
    scale_x, scale_y = width / backbuffer[0], height / backbuffer[1]
    bx, by = edge * scale_x, edge * scale_y

    def kind(x, y):
        r, g, b = pixel(min(width - 1, max(0, int(x))), min(height - 1, max(0, int(y))))
        return 'green' if g > 150 and r < 110 and b < 110 else 'red' if r > 150 and g < 110 and b < 110 else 'other'

    def share(points, wanted):
        points = list(points)
        return sum(kind(x, y) == wanted for x, y in points) / max(1, len(points))
    xs = [bx * 2 + (width - bx * 4) * i / 159 for i in range(160)]
    ys = [by * 2 + (height - by * 4) * i / 89 for i in range(90)]
    interior = share(((x, y) for y in ys for x in xs), 'green')
    edges = {'top': share(((x, by / 2) for x in xs), 'red'), 'bottom': share(((x, height - 1 - by / 2) for x in xs), 'red'),
             'left': share(((bx / 2, y) for y in ys), 'red'), 'right': share(((width - 1 - bx / 2, y) for y in ys), 'red')}
    return {'interior': round(interior, 4), 'edges': {k: round(v, 4) for k, v in edges.items()}, 'shot_px': [width, height]}


def canvas_records(session):
    rows = []
    for path in session.glob('canvas-*.jsonl'):
        rows += [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    return sorted(rows, key=lambda r: r['host_s'])


def close(a, b, tolerance=1.01):
    return all(abs(x - y) <= tolerance for x, y in zip(a, b))


def check_step(step, probe, bounds, canvas, seen):
    """What a player would see, and whether clicks land where the picture is."""
    failures = []
    client_pt = [probe['client'][0] / 2, probe['client'][1] / 2]  # Retina mode: two Wine pixels a point
    fullscreen = step == 'fullscreen'
    if not seen:
        failures.append('no screenshot')
    else:
        if seen['interior'] < GREEN_MIN:
            failures.append(f'picture interior {seen["interior"]:.1%} green')
        cut = [side for side, value in seen['edges'].items() if value < EDGE_MIN]
        if cut:
            failures.append('picture border missing at ' + ', '.join(f'{s} ({seen["edges"][s]:.0%})' for s in cut))
    if canvas is None:
        failures.append('no canvas log record')
        return failures
    if canvas['active'] != fullscreen:
        failures.append(f'canvas active={canvas["active"]}')
    if not fullscreen:
        if not close(canvas['root_bounds'][2:], canvas['root_frame'][2:]) or not close(canvas['root_bounds'][:2], [0, 0]):
            failures.append(f'content view scaled: bounds {canvas["root_bounds"]} frame {canvas["root_frame"]}')
        if not close(canvas['client'][2:], client_pt):
            failures.append(f'client view {canvas["client"][2:]} pt, Wine client {client_pt} pt')
        if not close(canvas['metal'][2:], canvas['client'][2:]):
            failures.append(f'Metal view {canvas["metal"][2:]} in client {canvas["client"][2:]}')
        if bounds and abs(bounds[2] - client_pt[0]) > 1.01:
            failures.append(f'window {bounds[2]} pt wide, Wine client {client_pt[0]} pt')
    return failures


def content_rect(step, probe, bounds):
    """Where the picture should be, in global points: the window's content area below the
    title bar, or in fullscreen the canvas's picture, fitted to the screen with equal bars
    (cocoa_v1.m) when the shapes differ, as on a 16:10 MacBook with a 16:9 picture."""
    x, y, w, h = bounds
    if step == 'fullscreen':
        pw, ph = probe['backbuffer']
        scale = min(w / pw, h / ph)
        fw, fh = pw * scale, ph * scale
        return [round(x + (w - fw) / 2), round(y + (h - fh) / 2), round(fw), round(fh)]
    client_h = probe['client'][1] / 2
    title = h - client_h
    if title < 0 or title > TITLE_BAR_MAX:
        title = 0 if probe['style'] & 0x00C00000 == 0 else min(max(title, 0), TITLE_BAR_MAX)
    return [x, y + title, w, h - title]


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--steps', help='Comma-separated steps (default: ' + ','.join(STEPS) + ')')
    parser.add_argument('--settle', type=float, default=SETTLE_S, help='Seconds to wait after each step')
    args = parser.parse_args()
    if any(command.endswith('Overwatch.exe') for _, command in processes()):
        raise SystemExit('Overwatch is running; the probe takes over the screen. Quit the game first.')
    runtime = prepare()
    steps = args.steps.split(',') if args.steps else STEPS
    session = LOGS / datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
    session.mkdir(parents=True)
    profile = (ENGINE / 'config/dxmt.conf').read_text()
    (session / 'dxmt.conf').write_text(profile.replace('[Overwatch.exe]', '[display_probe.exe]', 1)
                                       .replace('dxgi.fullscreenCanvasHeight = 1200', 'dxgi.fullscreenCanvasHeight = 1080'))
    go = session / 'go-'
    record = dict(runtime, steps=steps, started=session.name)
    server('-k')
    probe = subprocess.Popen([str(ENGINE / 'bin/wine'), str(EXE), 'run', mouselook_session.windows_path(session / 'probe.jsonl'),
                              mouselook_session.windows_path(go), *steps],
                             env=environment(session), stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                             cwd=session)
    results = []
    try:
        for index, step in enumerate(['start'] + steps):
            line = ''
            deadline = time.time() + 60
            while not line.startswith('ready'):
                line = probe.stdout.readline()
                if not line and (probe.poll() is not None or time.time() > deadline):
                    raise SystemExit(f'The probe stopped before step {index} ({step})')
            time.sleep(args.settle)
            rows = [json.loads(r) for r in (session / 'probe.jsonl').read_text().splitlines() if r.strip()]
            mine = [r for r in rows if r.get('index') == index]
            if not mine:
                raise SystemExit(f'No probe record for step {index}')
            probe_record = mine[-1]
            pid = probe_pid()
            bounds = window_bounds(pid) if pid else None
            seen = None
            if bounds:
                shot = session / f'step-{index}-{step.replace(":", "-")}.bmp'
                capture(content_rect(step, probe_record, bounds), shot)
                seen = picture(shot, probe_record['backbuffer'], probe_record['border'])
            canvas = canvas_records(session)
            last = canvas[-1] if canvas else None
            failures = check_step(step, probe_record, bounds, last, seen)
            result = dict(index=index, step=step, passed=not failures, failures=failures, picture=seen,
                          window_pt=bounds, wine=probe_record, canvas=last)
            results.append(result)
            print(f'{index} {step:<20} {"PASS" if not failures else "FAIL"}  {"; ".join(failures)}', flush=True)
            (go.parent / f'{go.name}{index}').write_text('')
    finally:
        try:
            probe.wait(timeout=30)
        except subprocess.TimeoutExpired:
            probe.kill()
        server('-k')
        record['results'] = results
        (session / 'report.json').write_text(json.dumps(record, indent=2) + '\n')
        for shot in session.glob('*.bmp'):
            # Keep the evidence small: PNG (sips is part of macOS).
            subprocess.run(['/usr/bin/sips', '-s', 'format', 'png', str(shot), '--out', str(shot.with_suffix('.png'))],
                           capture_output=True)
            shot.unlink()
    print(session)
    failed = [r for r in results if not r['passed']]
    sys.exit(1 if failed or len(results) != len(steps) + 1 else 0)


if __name__ == '__main__':
    main()
