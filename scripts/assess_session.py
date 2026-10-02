#!/usr/bin/env python3
"""Create a bounded, clock-aware post-game report. Never infer gameplay from FPS."""
import argparse
import csv
import datetime
import gzip
import json
from pathlib import Path
import re
import statistics
import time

from analyze_process_stalls import process_bins, display_hitches, correlate
from analyze_resource_ops import intervals, overlap
from summarize_display import distribution

ROOT=Path(__file__).resolve().parent.parent

def csv_rows(paths):
    result=[]
    for path in paths:
        opener=gzip.open if path.suffix=='.gz' else open
        with opener(path,'rt',newline='') as stream:
            for row in csv.DictReader(stream):
                if None in row or None in row.values():
                    raise ValueError(f'Incomplete CSV: {path.name}')
                result.append(dict(row,source_file=path.name))
    return result

def json_rows(paths):
    result=[]
    for path in paths:
        with path.open() as stream:
            result.extend(json.loads(line) for line in stream if line.strip())
    return result

def measured_windows(markers, lower, upper):
    starts={'practice_entered':'practice','workshop_entered':'workshop','quickplay_entered':'quickplay'}
    result=[];active=None
    for row in sorted(markers,key=lambda r:r['time']):
        point=datetime.datetime.fromisoformat(row['time']).timestamp()
        if active:
            name,began=active
            if min(point,upper)>max(began,lower):
                result.append((name,max(began,lower),min(point,upper)))
            active=None
        if row['event'] in starts: active=(starts[row['event']],point)
    if active and upper>max(lower,active[1]):result.append((active[0],max(lower,active[1]),upper))
    return result

def assess(folder,pid,windows_pid=None,start=None,end=None):
    display_files=sorted(p for p in folder.glob(f'display-{pid}*.csv*')
                         if re.fullmatch(fr'display-{pid}(?:\.\d+)?\.csv(?:\.gz)?',p.name))
    display=csv_rows(display_files)
    pairs,coverage=display_hitches(display,pid,minimum_ms=0)
    if not pairs: raise ValueError('No consecutive valid display callbacks for this process')
    lower=start if start is not None else min(h['start_utc_s'] for h in pairs)
    upper=end if end is not None else max(h['end_utc_s'] for h in pairs)+.000001
    if upper<=lower:raise ValueError('Empty or reversed assessment interval')
    canvas=json_rows(folder.glob(f'canvas-{pid}.jsonl'))
    identities={r['windows_pid'] for r in canvas if r.get('native_pid')==pid and r.get('windows_pid')}
    if windows_pid is None and len(identities)==1:windows_pid=identities.pop()
    elif windows_pid is not None and identities and identities!={windows_pid}:
        raise ValueError('Requested Windows PID disagrees with the native bridge identity')
    process_files=sorted(folder.glob('resources*.process*.csv*'))
    bins,rejects=process_bins(csv_rows(process_files),pid)
    runtime=json_rows(folder.glob(f'pipeline-cache-{pid}*.jsonl'))
    captures=[]
    for p in (folder/'hitch-stacks').glob('*.json'):
        row=json.loads(p.read_text())
        if row.get('pid')==pid and 'capture_start_unix_us' in row:
            captures.append(dict(row,start_utc_s=row['capture_start_unix_us']/1e6,
                                 end_utc_s=row['capture_end_unix_us']/1e6))
    spans=[];summaries={};geometry=[];pipeline_waits=[]
    if windows_pid is not None:
        events=sorted(folder.glob(f'resource-ops-{windows_pid}-*.events*.csv*'))
        spans=intervals(csv_rows(events))
        summaries={p.name:json.loads(p.read_text()) for p in folder.glob(f'resource-ops-{windows_pid}-*.summary.json')}
        geometry=csv_rows(folder.glob(f'geometry-{windows_pid}-*.csv'))
        pipeline_waits=csv_rows(folder.glob(f'shaders-pipelines-{windows_pid}*.csv'))
    selected=[h for h in pairs if lower<=h['start_utc_s'] and h['end_utc_s']<upper]
    hitches=[h for h in selected if h['duration_ms']>50]
    joined=correlate(bins,hitches,runtime)
    for hitch in joined:
        stable=not hitch.get('clock_step_overlap')
        direct=[s for s in spans if stable and overlap(s,hitch)]
        hitch['resource_api_spans']=[s for s in direct if not s['operation'].startswith('mapped_use_')]
        hitch['mapped_application_intervals']=[s for s in direct if s['operation'].startswith('mapped_use_')]
        hitch['profiler_overlap']=any(overlap(hitch,s) for s in captures)
        hitch['initial_pipeline_waits']=[r for r in pipeline_waits if stable and r.get('phase')=='initialWait'
            and float(r['start_unix_us'])/1e6<hitch['end_utc_s']
            and (float(r['start_unix_us'])+float(r['duration_us']))/1e6>hitch['start_utc_s']]
    def stats(rows,a,b):
        clean=[h for h in rows if not any(overlap(h,c) for c in captures)]
        return dict(requested_seconds=b-a,paired_seconds=sum(h['duration_ms']/1000 for h in rows),
                    display_intervals=distribution([h['duration_ms']/1000 for h in rows]),
                    over_50ms=sum(h['duration_ms']>50 for h in rows),over_100ms=sum(h['duration_ms']>100 for h in rows),
                    profiler_overlap_intervals=len(rows)-len(clean),
                    outside_profiler=dict(display_intervals=distribution([h['duration_ms']/1000 for h in clean]),
                      over_50ms=sum(h['duration_ms']>50 for h in clean),over_100ms=sum(h['duration_ms']>100 for h in clean)))
    markers=json_rows(folder.glob('session-markers.jsonl'))
    phases=[dict(phase=name,start_utc_s=a,end_utc_s=b,**stats([h for h in selected if a<=h['start_utc_s'] and h['end_utc_s']<b],a,b))
            for name,a,b in measured_windows(markers,lower,upper)]
    dropped=max((int(r.get('dropped_events',0)) for r in display),default=0)
    unavailable=sum(r.get('event')=='presented' and r.get('presented_state')!='valid' for r in display)
    paging=sum(any(b['delta']['vm_swapins'] or b['delta']['vm_swapouts'] for b in h['bins']) for h in joined)
    new_compile=sum(any(r.get('known_at_launch') is False or r.get('known_at_launch')==0
                        for r in h['overlapping_pipeline_creates']) for h in joined)
    actions=[]
    if new_compile: actions.append(f'{new_compile} hitches overlap creation of pipelines unknown at launch; preserve learning and assess the next prepared archive.')
    if paging: actions.append(f'{paging} hitches overlap system paging; inspect captured native stacks and mapped application intervals. Paging association alone does not identify the responsible app.')
    unexplained=sum(not h['overlapping_pipeline_creates'] and not h['resource_api_spans'] and not h['mapped_application_intervals'] for h in joined)
    if unexplained: actions.append(f'{unexplained} hitches have no matching traced operation; use captured stacks/focus and coverage before choosing another code change.')
    if not phases: actions.append('No gameplay phase markers: loading/menus may be included unless an explicit gameplay interval was supplied. Do not judge multiplayer from an unmarked whole-session result.')
    geometry_sizes=sorted({(int(r['present_source_width']),int(r['present_source_height'])) for r in geometry})
    return dict(schema_version=1,native_pid=pid,windows_pid=windows_pid,start_utc_s=lower,end_utc_s=upper,
        statistics=stats(selected,lower,upper),phases=phases,display_coverage=coverage,
        telemetry=dict(dropped_display_events=dropped,unavailable_presented_callbacks=unavailable,
                       rejected_counter_intervals=rejects,resource_summaries=summaries,
                       exact_windows_identity_available=windows_pid is not None),
        game_render_sizes=geometry_sizes,canvas_events=canvas,stack_captures=captures,hitches=joined,actions=actions,
        interpretation='Overlaps are clues, not causal proof. Mapped intervals include arbitrary application work and scheduling. '
          'Missing presentation callbacks are unavailable data, not fabricated freezes. Both full and profiler-excluded results are retained. '
          'Native stacks can be useful; translated Windows/Rosetta unwinding may be incomplete. Quiet-launch performance needs user acceptance.')

def write_report(folder,result):
    output=folder/f"v1-assessment-{result['native_pid']}";output.mkdir(exist_ok=True)
    stats=result['statistics'];d=stats['display_intervals']
    text=(f"V1 session assessment — process {result['native_pid']}\n\n"
          f"Observed interval: {stats['requested_seconds']:.1f} s; paired display coverage: {stats['paired_seconds']:.1f} s.\n"
          f"Median display interval: {d['median_ms']} ms; p99: {d['p99_ms']} ms; maximum: {d['max_ms']} ms.\n"
          f"Over 50 ms: {stats['over_50ms']}; over 100 ms: {stats['over_100ms']}.\n"
          f"Intervals overlapping a profiler: {stats['profiler_overlap_intervals']}.\n"
          f"Game render sizes: {result['game_render_sizes'] or 'unavailable'}.\n\n")
    for p in result['phases']:
        text+=f"{p['phase']}: {p['requested_seconds']:.1f} s, {p['over_50ms']} over 50 ms, {p['over_100ms']} over 100 ms.\n"
    text+='\n'+'\n'.join('- '+a for a in result['actions'])+'\n\n'+result['interpretation']+'\n'
    for name,content in [('report.json',json.dumps(result,indent=2,allow_nan=False)+'\n'),('REPORT.txt',text)]:
        temp=output/(name+'.tmp');temp.write_text(content);temp.replace(output/name)
    return output

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--session',type=Path,required=True);parser.add_argument('--pid',type=int,required=True)
    parser.add_argument('--windows-pid',type=int);parser.add_argument('--start');parser.add_argument('--end')
    parser.add_argument('--after-exit',action='store_true')
    args=parser.parse_args();folder=args.session.resolve()
    if not folder.is_relative_to(ROOT/'logs/dxmt'):parser.error('Session must be inside this experiment')
    if args.after_exit:
        time.sleep(3)
        deadline=time.monotonic()+48
        while (folder/'hitch-stacks/active.json').exists() and time.monotonic()<deadline:
            time.sleep(1)
        if (folder/'hitch-stacks/active.json').exists():
            print('Automatic report deferred: profiler completion is not confirmed.');return
        from prepare_dxmt_pipelines import game_running
        if game_running():print('Automatic report deferred: another game is running.');return
    stamp=lambda s:datetime.datetime.fromisoformat(s).timestamp() if s else None
    result=assess(folder,args.pid,args.windows_pid,stamp(args.start),stamp(args.end))
    print(write_report(folder,result))

if __name__=='__main__':main()
