#!/usr/bin/env python3
"""Exercise the installed candidate in the isolated diagnostic Wine engine."""
import datetime
import hashlib
import json
import re
from pathlib import Path
import subprocess
import sys
import os
import argparse

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
import launch_cx26 as launch
import validate_dxmt_pipeline_reuse as render

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--engine', type=Path, help='Compare this runtime in a private clone of the diagnostic prefix.')
parser.add_argument('--prefix', type=Path, help='Reuse an idle comparison clone under runtime/diagnostics/v1-fullscreen-* to conserve disk space.')
parser.add_argument('--label', default='reference', choices=('reference','portable'))
parser.add_argument('--overlay', action='store_true', help='Exercise the experimental overlay; default is the normal Wine view.')
parser.add_argument('--focus-recovery', action='store_true', help='Three hide/restore cycles with game-style DXGI fullscreen requests.')
args=parser.parse_args()
folder=ROOT/'logs/dxmt'/('v1-fullscreen-'+args.label+'-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
folder.mkdir()
print(folder,flush=True)
engine=args.engine.resolve() if args.engine else render.ENGINE
prefix=render.PREFIX
if args.engine:
    if any(line.strip().endswith('Overwatch.exe') for line in subprocess.check_output(['ps','-axo','comm='],text=True).splitlines()):
        raise SystemExit('Close Overwatch before fullscreen comparison')
    if not prefix.resolve().is_relative_to(ROOT/'runtime/diagnostics'):
        raise SystemExit('Reference prefix must be under runtime/diagnostics')
    prefix=args.prefix.resolve() if args.prefix else ROOT/'runtime/diagnostics'/folder.name
    if prefix.parent != ROOT/'runtime/diagnostics' or not prefix.name.startswith('v1-fullscreen-'):
        raise SystemExit('Only isolated fullscreen comparison clones may be reused')
    if args.prefix:
        if not (prefix/'user.reg').is_file():raise SystemExit('Comparison clone missing')
    else:
        if prefix.exists():raise SystemExit('Diagnostic destination already exists')
        subprocess.run(['/bin/cp','-cR',str(render.PREFIX),str(prefix)],check=True)
    import shutil
    shutil.copy2(engine/'lib/wine/x86_64-windows/winemetal.dll',prefix/'drive_c/windows/system32/winemetal.dll')

# Compile the owned fixture from current source; never reuse a stale helper.
fixture=folder/'fullscreen-fixture.dll.so'
fixture_object=folder/'fullscreen-fixture.o'
subprocess.run(['/usr/bin/clang','-arch','x86_64','-c','-fblocks','-fno-objc-arc',
    '-I',str(ROOT/'runtime/source/wine-v1/dlls/winemac.drv'),
    '-I',str(ROOT/'runtime/source/wine-v1/include'),'-I',str(ROOT/'runtime/build/winemac-v1/include'),
    str(ROOT/'tests/fullscreen/fixture.m'),
    '-o',str(fixture_object)],check=True)
subprocess.run([str(ROOT/'runtime/phase-2/wine-build/tools/winegcc/winegcc'),'-m64','-shared','-nodefaultlibs',
    '--wine-objdir',str(ROOT/'runtime/phase-2/wine-build'),'-I',str(ROOT/'runtime/phase-2/sources/wine/sources/wine/include'),
    str(ROOT/'tests/fullscreen/loader.c'),str(fixture_object),'-framework','AppKit','-framework','QuartzCore',
    '-o',str(folder/'fullscreen-fixture.dll')],check=True)
env=launch.build_environment('dxmt',engine,prefix,source_build=True,profile='smooth60',pipeline_cache=False,overlay=args.overlay)
env['DXMT_SHADER_CACHE_PATH']=str(folder/'shaders')
if args.focus_recovery:env['DXMT_V1_FOCUS_RECOVERY']='1'
if args.engine:
    with (folder/'initialize.log').open('w') as log:
        subprocess.run([str(engine/'bin/wine'),'wineboot.exe','-r'],env=env,stdout=log,stderr=subprocess.STDOUT,check=True,timeout=180)
        subprocess.run([str(engine/'bin/wineserver'),'-w'],env=env,check=True,timeout=60)
    if '"RetinaMode"="Y"' not in (prefix/'user.reg').read_text():
        raise SystemExit('Diagnostic prefix lacks accepted Retina setting')

subprocess.run([str(engine/'bin/wineserver'),'-k'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=15)
subprocess.run([str(engine/'bin/wineserver'),'-w'],env=env,check=True,timeout=30)
reports={}
def build_identity():
    return dict(runtime=str(engine), prefix=str(prefix),
        runtime_files={str(p.relative_to(engine)):hashlib.sha256(p.read_bytes()).hexdigest()
          for p in [engine/'bin/wine',engine/'bin/wineserver']+
          [engine/'lib/wine'/n for n in ('x86_64-windows/d3d11.dll','x86_64-windows/dxgi.dll','x86_64-windows/winemetal.dll','x86_64-unix/winemetal.so','x86_64-unix/ntdll.so','x86_64-unix/win32u.so')]},
        driver_sha256=hashlib.sha256((engine/'lib/wine/x86_64-unix/winemac.so').read_bytes()).hexdigest(),
        fixture_sha256=hashlib.sha256(fixture.read_bytes()).hexdigest(),
        fixture_source_sha256=hashlib.sha256((ROOT/'tests/fullscreen/fixture.m').read_bytes()).hexdigest(),
        overlay=args.overlay,focus_recovery=args.focus_recovery)
identity=build_identity()
def validate_case(case,height,target):
    checkpoints,native=case['checkpoints'],case['native']
    assert len(native)==6,native
    expected_drawables=int(env.get('DXMT_CANVAS_DRAWABLES','3'))
    assert all(row['layers'] and all(layer['maximum_drawables']==expected_drawables for layer in row['layers']) for row in native),(expected_drawables,native)
    expected_fullscreen=[False,True,True,True,True,False] if args.focus_recovery else [False,True,False,True,True,False]
    assert [bool(row['fullscreen']) for row in native]==expected_fullscreen,native
    assert all(row['client']==row['swapchain']==[1920,height] for row in checkpoints)
    cursors=[r for row in checkpoints for r in row.get('cursor_roundtrip',[])]
    assert len(cursors)==18,cursors
    assert all(max(abs(a-b) for a,b in zip(r['wanted'],r['found']))<=1 for r in cursors)
    requests=[row['fullscreen_request'] for row in checkpoints if 'fullscreen_request' in row]
    assert requests==([True,False,True,False,True,False,True,False] if args.focus_recovery else [True,False,True,False]),requests
    rect=lambda value:[float(v) for v in re.findall(r'-?\d+(?:\.\d+)?',value)]
    overlay_expected=env.get('DXMT_CANVAS_OVERLAY')=='1'
    for row in native:
        overlays=row.get('overlays',[])
        if row['fullscreen'] and overlay_expected:
            # The metal view lives in the overlay child window: one direct-flip layer, no layer left in the Wine view tree.
            assert len(overlays)==1 and all(l.get('overlay') for l in row['layers']),row
            assert overlays[0]['ignores_mouse'] and overlays[0]['visible'] and not overlays[0]['key'] and row['key_window'],row
            assert overlays[0]['level']>0 and overlays[0]['on_screen'],row
            shown=rect(overlays[0]['shown']);frame=rect(overlays[0]['frame'])
            assert abs(shown[2]/shown[3]-1920/height)<2e-3,row
            assert abs(shown[0]-(frame[2]-shown[2])/2)<1.01 and abs(shown[1]-(frame[3]-shown[3])/2)<1.01,row
        else:
            assert not overlays and not any(l.get('overlay') for l in row['layers']),row
    for row in native:
        shown=rect(row['views'][0]['shown']);frame=rect(row['root_frame'])
        if row['fullscreen']:
            # The scaled Wine client view keeps the same placement whether or not the overlay hosts the layer.
            assert abs(shown[2]/shown[3]-1920/height)<1e-6,row
            assert abs(shown[0]-(frame[2]-shown[2])/2)<.01,row
            assert abs(shown[1]-(frame[3]-shown[3])/2)<.01,row
        else:assert all(abs(a-b)<.01 for a,b in zip(rect(row['root_bounds']),frame)),row
    clicks=[json.loads(line) for line in (target/'mouse.jsonl').read_text().splitlines()]
    assert len(clicks)==18,clicks
    for i,click in enumerate(clicks):
        fraction=.5 if not args.focus_recovery and i//3==4 else [.1,.5,.9][i%3]
        assert abs(click['x']-1920*fraction)<=1 and abs(click['y']-height*fraction)<=1,click
    import csv
    geometries=[row for path in target.glob('geometry*.csv') for row in csv.DictReader(path.open())]
    assert all([int(row['present_source_width']),int(row['present_source_height'])]==[1920,height] for row in geometries)
    physical=[row for row in geometries if int(row['drawable_width'])>1920]
    assert physical,'Fullscreen never acquired a physical-resolution drawable'
    assert all(abs(int(row['drawable_width'])/int(row['drawable_height'])-1920/height)<.002 for row in physical)
    case['presentation_geometry']=geometries
    if args.focus_recovery:
        # A live GPU alone does not prove restoration: the failed game had
        # hundreds of GPU completions with no valid display timestamp.
        display=[row for path in target.glob('display-*.csv') if re.fullmatch(r'display-\d+(?:\.\d+)?\.csv',path.name)
                 for row in csv.DictReader(path.open()) if row['event']=='presented']
        case['focus_display_checks']=[]
        for checkpoint in native:
            if not checkpoint['event'].startswith('fullscreen_refocused_'):continue
            selected=[r for r in display if checkpoint['unix_s']-.75<=float(r['unix_ms'])/1000<=checkpoint['unix_s']+.25]
            times=sorted(float(r['presented_s']) for r in selected if r['presented_state']=='valid' and float(r['presented_s'])>0)
            valid=len(times)
            span_ms=(times[-1]-times[0])*1000 if valid else 0
            outcome=dict(event=checkpoint['event'],callbacks=len(selected),valid=valid,
                         valid_span_ms=round(span_ms,3),key_window=checkpoint['key_window'])
            case['focus_display_checks'].append(outcome)
            # This uncapped diagnostic can outrun the display and drop frames.
            # Require sustained presentations, not a 90% callback success rate.
            assert checkpoint['key_window'] and valid>=20 and span_ms>=500,outcome
    case['display_path']=display_path(target)
    frames=[row for path in target.glob('frames*.csv') if not re.search(r'events|summary',path.name) for row in csv.DictReader(path.open())]
    assert frames and 'pacing_sleep_us' in frames[0],'frames log lacks the pacing column'
    case['pacing']=dict(boundaries=len(frames),sleeps=sum(int(r['pacing_sleep_us'])>0 for r in frames),
                        max_sleep_us=max(int(r['pacing_sleep_us']) for r in frames))
    case['assertions']=f'PASS: DXGI fullscreen API, fixed client/backbuffer, aspect ratio/bars, restored bounds, {expected_drawables}-drawable layer, 18 cursor roundtrips and 18 Win32 clicks.'
    if args.focus_recovery:case['assertions']+=' Sustained display timestamps after three focus/fullscreen cycles.'
def display_path(target):
    """GPU-end-to-presentedTime of the diagnostic's frames inside the fullscreen spans (informational).

    0.1 ms means Core Animation flipped the drawable directly; several ms means it
    was composited. Not an assertion: the flip path depends on system state.
    """
    import csv,statistics
    rows=[row for path in target.glob('display-*.csv') if re.fullmatch(r'display-\d+\.csv',path.name) for row in csv.DictReader(path.open())]
    canvas=[json.loads(line) for path in target.glob('canvas-*.jsonl') for line in path.read_text().splitlines() if line.strip()]
    spans=[];began=None
    for event in canvas:
        if event['event']=='enter_fullscreen':began=event['unix_ms']/1000
        elif event['event']=='exit_fullscreen' and began:spans.append((began,event['unix_ms']/1000));began=None
    by={}
    for row in rows:by.setdefault(int(row['sequence']),{})[row['event']]=row
    values=[]
    for seq,events in by.items():
        shown,done=events.get('presented'),events.get('gpu_complete')
        if not shown or not done or shown['presented_state']!='valid' or float(shown['presented_s'])<=0 or float(done['gpu_start_s'])<=0:continue
        anchor=float(shown['unix_ms'])/1000-float(shown['event_host_s']);photon=anchor+float(shown['presented_s'])
        if any(b+1<=photon<e-.5 for b,e in spans):values.append((photon-anchor-float(done['gpu_end_s']))*1000)
    if len(values)<20:return dict(note='too few fullscreen presentations')
    values.sort()
    pick=lambda f:round(values[min(len(values)-1,int(round(f*(len(values)-1))))],2)
    return dict(samples=len(values),p10=pick(.1),p50=pick(.5),mean=round(statistics.mean(values),2),p90=pick(.9),
                over_16ms_percent=round(100*sum(v>16 for v in values)/len(values),1),
                interpretation='GPU end to presentedTime in fullscreen; about 0.1 ms is a direct flip, several ms is compositing')
try:
    for height in (1080,1200):
        target=folder/str(height);target.mkdir()
        config=target/'dxmt.conf'
        # Focus recovery uses the candidate's pacing-off policy at both sizes.
        # The legacy 1200 case still covers the optional pacing sleep path.
        pacing='dxgi.presentPacing = True\n' if height==1200 and not args.focus_recovery else ''
        config.write_text(f'[python.exe]\nd3d11.preferredMaxFrameRate = 0\ndxgi.maxFrameLatency = 1\ndxgi.nativeFullscreen = True\ndxgi.sharpPresentation = True\ndxgi.fullscreenCanvasWidth = 1920\ndxgi.fullscreenCanvasHeight = {height}\n{pacing}')
        env.update(DXMT_CONFIG_FILE=launch.windows_path(config),DXMT_CANVAS_LOG=str(target/'canvas'),
                   DXMT_GEOMETRY_LOG=launch.windows_path(target/'geometry'),DXMT_WINDOW_LOG=launch.windows_path(target/'windows'),
                   DXMT_DISPLAY_LOG=str(target/'display'),DXMT_V1_OWNED_FIXTURE=str(target),
                   DXMT_FRAME_LOG=launch.windows_path(target/'frames'),
                   DXMT_V1_GAME_FULLSCREEN='1')
        with (target/'probe.log').open('w') as output:
            result=subprocess.run([str(engine/'bin/wine'),
                launch.windows_path(ROOT/'runtime/diagnostics/python-3.13.7-embed/python.exe'),
                launch.windows_path(ROOT/'scripts/d3d11_render_probe_windows.py'),
                '--width','1920','--height',str(height),'--frames','18000',
                '--canvas-probe',launch.windows_path(target/'checkpoints.jsonl'),
                '--native-fixture',launch.windows_path(fixture)],
                env=env,stdout=output,stderr=subprocess.STDOUT,timeout=180)
        result.check_returncode()
        records=[json.loads(line) for line in (target/'probe.log').read_text(errors='replace').splitlines() if line.startswith('{')]
        passed=next(r for r in records if r.get('result')=='PASS')
        checkpoints=[json.loads(line) for line in (target/'checkpoints.jsonl').read_text().splitlines()]
        native=[json.loads(line) for line in (target/'native-fixture.jsonl').read_text().splitlines()]
        reports[str(height)]=dict(render=passed,checkpoints=checkpoints,native=native)
        (folder/'report.json').write_text(json.dumps(reports,indent=2)+'\n')
        try:
            validate_case(reports[str(height)],height,target)
        except AssertionError as exc:
            reports[str(height)]['failure']=str(exc)
            raise
        finally:
            (folder/'report.json').write_text(json.dumps(reports,indent=2)+'\n')
        print(height,reports[str(height)]['assertions'],flush=True)
        print(height,'display path:',json.dumps(reports[str(height)].get('display_path')),'pacing:',json.dumps(reports[str(height)].get('pacing')),flush=True)
    assert build_identity()==identity,'Runtime changed during fullscreen validation'
    (folder/'build-identity.json').write_text(json.dumps(identity,indent=2)+'\n')
finally:
    env.pop('DYLD_INSERT_LIBRARIES',None)
    subprocess.run([str(engine/'bin/wineserver'),'-k'],env=env,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=15)
    subprocess.run([str(engine/'bin/wineserver'),'-w'],env=env,check=True,timeout=30)
