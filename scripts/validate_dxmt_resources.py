#!/usr/bin/env python3
"""Validate final built libraries in the existing isolated diagnostic engine."""
import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import launch_cx26 as launch
import stage_dxmt_local as stage
import validate_dxmt_pipeline_reuse as render
from analyze_resource_ops import read_rows, intervals


def main():
    root = launch.ROOT
    engine, prefix = render.ENGINE, render.PREFIX
    if not engine.is_dir(): raise SystemExit('Create the isolated validation engine first.')
    if any(line.strip().endswith('Overwatch.exe') for line in
           subprocess.check_output(['ps', '-axo', 'comm='], text=True).splitlines()):
        raise SystemExit('Overwatch must be closed for graphics validation.')
    manifest = stage.validate_build()
    diff = subprocess.check_output(['git', '-C', str(root/'runtime/source/dxmt-ow2'), 'diff', '--binary'])
    assert hashlib.sha256(diff).hexdigest() == manifest['patch_sha256']
    env = launch.build_environment('dxmt', engine, prefix, source_build=True, profile='smooth60', pipeline_cache=False)
    subprocess.run([str(engine/'bin/wineserver'), '-w'], env=env, check=True, timeout=30)
    for name in stage.FILES:
        shutil.copy2(stage.INSTALL/name, engine/'lib/wine'/name)
        assert hashlib.sha256((engine/'lib/wine'/name).read_bytes()).hexdigest() == manifest['files'][name]
    (engine/'local-build-manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
    folder = root/'logs/dxmt'/('resource-validation-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
    folder.mkdir()
    config=folder/'dxmt.conf'
    config.write_text((root/'config/dxmt-source60.conf').read_text().replace('[Overwatch.exe]','[python.exe]'))
    env['DXMT_CONFIG_FILE']=launch.windows_path(config)
    report = dict(manifest=manifest, runs={})
    try:
        render_args = ['--frames', '120', '--width', '1920', '--height', '1080', '--settle-ms', '3000']
        for name, script, args in [('resources', 'd3d11_resource_probe_windows.py', []),
                                  ('render', 'd3d11_render_probe_windows.py', render_args),
                                  ('waitable_render', 'd3d11_render_probe_windows.py', render_args+['--waitable'])]:
            target = folder/name; target.mkdir()
            env.update(DXMT_RESOURCE_LOG=launch.windows_path(target/'resource-ops'),
                       DXMT_FRAME_LOG=launch.windows_path(target/'frames'),
                       DXMT_DISPLAY_LOG=str(target/'display'),
                       DXMT_SHADER_CACHE_PATH=str(folder/'shader-cache'))
            with (target/'probe.log').open('w') as output:
                result = subprocess.run([str(engine/'bin/wine'),
                    launch.windows_path(root/'runtime/diagnostics/python-3.13.7-embed/python.exe'),
                    launch.windows_path(root/'scripts'/script), *args],
                    env=env, stdout=output, stderr=subprocess.STDOUT, timeout=120)
            result.check_returncode()
            records = [json.loads(line) for line in (target/'probe.log').read_text(errors='replace').splitlines()
                       if line.startswith('{')]
            passed = next(record for record in records if record.get('result') == 'PASS')
            summaries = [json.loads(p.read_text()) for p in target.glob('resource-ops-*.summary.json')]
            assert summaries, 'Missing resource summaries'
            assert all(s['io_errors'] == s['disk_rows_lost'] == 0 for s in summaries), summaries
            events = intervals(read_rows(list(target.glob('resource-ops-*.events*.csv'))))
            totals = intervals(read_rows(list(target.glob('resource-ops-*.totals*.csv'))), True)
            calls = {}
            for batch in totals: calls[batch['operation']] = calls.get(batch['operation'], 0)+batch['calls']
            if name == 'resources':
                for op in ['create_buffer', 'buffer_allocate', 'buffer_release', 'create_texture',
                           'texture_allocate', 'texture_release', 'map_immediate', 'unmap_immediate',
                           'map_deferred', 'unmap_deferred', 'update_subresource', 'buffer_upload',
                           'texture_upload', 'texture_initialize', 'release_batch', 'heap_allocate']:
                    assert calls.get(op, 0) > 0, (op, calls)
                assert sum(b['bytes'] for b in totals if b['operation'] == 'texture_initialize') >= 64*64*4
                for op in ['mapped_use_immediate','mapped_use_deferred']:
                    held=[s for s in events if s['operation']==op]
                    assert any(s['duration_ns']>=6_000_000 and s['bytes_known']==0 for s in held),(op,held)
                assert calls.get('map_pair_issue',0)==0,calls
            else:
                assert calls.get('present_mutex', 0) >= 100
                if name == 'waitable_render': assert calls.get('present_fence', 0) >= 100
                else: assert calls.get('present_fence', 0) == 0
                assert passed['backbuffer'] == [1920, 1080] and len(passed['verified_pixels']) == 3
            report['runs'][name] = dict(probe=passed, resource_summaries=summaries,
                                       slow_spans=len(events), batches=len(totals), calls=calls)
            (folder/'report.json').write_text(json.dumps(report, indent=2)+'\n')
            print(f'{name}: PASS; resource timing, byte counts, and readback verified', flush=True)
    finally:
        subprocess.run([str(engine/'bin/wineserver'), '-k'], env=env, timeout=15,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run([str(engine/'bin/wineserver'), '-w'], env=env, check=True, timeout=30)
    print(folder, flush=True)


if __name__ == '__main__': main()
