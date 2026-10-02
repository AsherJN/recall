#!/usr/bin/env python3
"""Validate a new signaling build in an isolated engine before publishing it.

Uses only the standalone graphics probe's own windows. The existing game engine,
prefix and shader cache remain intact. Close other diagnostic users of the prefix
before running; the created engine is retained for reviewed publication/rollback.
"""
from pathlib import Path
import csv
import datetime
import hashlib
import json
import shutil
import subprocess

import launch_cx26 as launch
import stage_dxmt_local as stage

ROOT = launch.ROOT
ENGINE = ROOT / 'runtime/build/dxmt-local/signaling-validated-engine'
PREFIX = ROOT / 'runtime/diagnostics/prefix-window-sizing-20260911-124251'


def csv_rows(path):
    with path.open(newline='') as stream:
        rows = list(csv.DictReader(stream))
    if any(None in row or any(v is None for v in row.values()) for row in rows):
        raise RuntimeError(f'Incomplete CSV in completed probe: {path.name}')
    return rows


def main():
    if ENGINE.exists() or not PREFIX.is_dir():
        raise SystemExit('Expected a new staging engine and the existing diagnostic prefix.')
    if any(line.strip().endswith('Overwatch.exe') for line in
           subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()):
        raise SystemExit('Close Overwatch before graphics validation.')
    if shutil.disk_usage(ROOT).free < 5 * 2**30:
        raise SystemExit('At least 5 GiB free is required.')
    manifest = stage.validate_build()
    diff = subprocess.check_output(['git', '-C', str(ROOT / 'runtime/source/dxmt-ow2'), 'diff', '--binary'])
    assert hashlib.sha256(diff).hexdigest() == manifest['patch_sha256']
    folder = ROOT / 'logs/dxmt' / ('signaling-validation-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    folder.mkdir()
    subprocess.run(['/bin/cp', '-cR', str(stage.ENGINE), str(ENGINE)], check=True)
    for name in stage.FILES:
        shutil.copy2(stage.INSTALL / name, ENGINE / 'lib/wine' / name)
        assert hashlib.sha256((ENGINE / 'lib/wine' / name).read_bytes()).hexdigest() == manifest['files'][name]
    (ENGINE / 'local-build-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    # This patch preserves the bridge ABI. Refuse an unexpected prefix mutation.
    assert hashlib.sha256((PREFIX / 'drive_c/windows/system32/winemetal.dll').read_bytes()).hexdigest() == manifest['files']['x86_64-windows/winemetal.dll']
    cache = folder / 'isolated-cache'
    cache.mkdir()
    report = dict(engine=str(ENGINE), prefix=str(PREFIX), manifest=manifest, runs={},
                  scope='Real graphics integration and trace validation; not a gameplay FPS comparison.')
    try:
        for name, measured, count in [('cold', True, 240), ('warm', True, 120), ('quiet', False, 24)]:
            run_dir = folder / name
            run_dir.mkdir()
            config = run_dir / 'dxmt.conf'
            config.write_text('[python.exe]\nd3d11.releaseShaderIR = True\nd3d11.preferredMaxFrameRate = 60\nd3d11.shaderCompilerThreads = 4\nd3d11.shaderCompilerNormalPriority = True\n')
            env = launch.build_environment('dxmt', ENGINE, PREFIX, profile='smooth60', source_build=True,
                                           pipeline_cache=False)
            env.update(DXMT_CONFIG_FILE=launch.windows_path(config), DXMT_SHADER_CACHE_PATH=str(cache))
            if measured:
                for key, basename in [('DXMT_FRAME_LOG', 'frames'), ('DXMT_GEOMETRY_LOG', 'geometry'),
                                      ('DXMT_WINDOW_LOG', 'windows'), ('DXMT_SHADER_LOG', 'shaders')]:
                    env[key] = launch.windows_path(run_dir / basename)
                env['DXMT_DISPLAY_LOG'] = str(run_dir / 'display')
            with (run_dir / 'probe.log').open('w') as output:
                result = subprocess.run([str(ENGINE / 'bin/wine'),
                    launch.windows_path(ROOT / 'runtime/diagnostics/python-3.13.7-embed/python.exe'),
                    launch.windows_path(ROOT / 'scripts/d3d11_render_probe_windows.py'),
                    '--frames', str(count), '--width', '1920', '--height', '1080', '--blue', '83'],
                    env=env, stdout=output, stderr=subprocess.STDOUT, timeout=120)
            result.check_returncode()
            records = [json.loads(line) for line in (run_dir / 'probe.log').read_text(errors='replace').splitlines() if line.startswith('{')]
            passed = next(row for row in records if row.get('result') == 'PASS')
            assert len(passed['verified_pixels']) == 3 and passed['backbuffer'] == [1920, 1080]
            run = dict(probe=passed)
            if measured:
                shaders = [p for p in run_dir.glob('shaders-*.csv') if not any(x in p.name for x in ('pipelines', 'summary'))]
                assert len(shaders) == 1
                rows = csv_rows(shaders[0])
                assert len(rows) == 2 and all(row['result'] == 'ready' for row in rows)
                assert all(row['cache'] == ('missing' if name == 'cold' else 'hit') for row in rows)
                if name == 'warm':
                    assert all(int(row['translate_us']) == 0 for row in rows)
                run['shaders'] = rows
                geometry = csv_rows(next(run_dir.glob('geometry-*.csv')))
                assert all(float(row[key]) == value for row in geometry for key, value in
                           [('present_source_width', 1920), ('present_source_height', 1080),
                            ('drawable_width', 1920), ('drawable_height', 1080)])
                assert geometry
                pipelines = csv_rows(next(run_dir.glob('shaders-pipelines-*.csv')))
                assert any(row['phase'] == 'createMetal' for row in pipelines)
                run['pipelines'] = pipelines
                for row in pipelines:
                    if row['phase'] == 'wait':
                        published, returned = int(row['ready_published_monotonic_us']), int(row['wait_return_monotonic_us'])
                        assert published > 0 and returned >= published
                        assert int(row['ready_to_return_us']) == returned - published
                display = csv_rows(next(run_dir.glob('display-*.csv')))
                assert sum(row['event'] == 'presented' and row['presented_state'] == 'valid' for row in display) >= count // 2
                run['display_event_count'] = len(display)
            else:
                assert not list(run_dir.glob('*.csv')), 'Quiet mode emitted diagnostic CSV.'
            report['runs'][name] = run
            (folder / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
            print(f'{name}: actual 1080p draw/readback and diagnostics checks passed', flush=True)
    finally:
        env = launch.build_environment('dxmt', ENGINE, PREFIX, profile='smooth60', source_build=True,
                                       pipeline_cache=False)
        subprocess.run([str(ENGINE / 'bin/wineserver'), '-k'], env=env, timeout=15,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([str(ENGINE / 'bin/wineserver'), '-w'], env=env, timeout=30, check=True)
    print(folder, flush=True)


if __name__ == '__main__':
    main()
