#!/usr/bin/env python3
"""Does macOS Game Mode engage for a process shaped like Recall's Wine game process?

Builds tests/game_mode/probe.m (x86_64, under Rosetta like the game) in several
identities. The control is a normal game app opened through Launch Services; the
others are started as plain child processes, the way the worker starts Wine.
Each variant takes over the screen for about 15 seconds: ask the owner first.
"""
import argparse
import datetime
import json
import plistlib
from pathlib import Path
import re
import shutil
import subprocess
import time

ROOT=Path(__file__).resolve().parents[2]
GAME_KEYS={'LSApplicationCategoryType':'public.app-category.action-games','LSSupportsGameMode':True,'GCSupportsGameMode':True}
# kind: 'bundle' (Info.plist in an .app) or 'embedded' (Info.plist in the executable, as Wine's loader has)
VARIANTS={
    'control-open':dict(kind='bundle',keys=True,launch='open',summary='normal game app opened by Launch Services (validates the probe)'),
    'bundle-exec':dict(kind='bundle',keys=True,launch='exec',summary='approach 2: game .app started as a child process'),
    'bundle-exec-uielement':dict(kind='bundle',keys=True,uielement=True,launch='exec',summary='approach 2, starting as a UI element like Wine'),
    'embedded-uielement':dict(kind='embedded',keys=True,uielement=True,launch='exec',summary="approach 1: keys in the executable's plist, starts as UI element like Wine"),
    'embedded':dict(kind='embedded',keys=True,launch='exec',summary="approach 1 without LSUIElement"),
    'embedded-none':dict(kind='embedded',keys=False,uielement=True,launch='exec',summary="today's Wine loader identity (negative control)"),
}
LOG_PATTERN=re.compile(r'Found game|gaming session|Game mode status|labelReason')

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('variants',nargs='*',help='Default: all of '+', '.join(VARIANTS))
parser.add_argument('--seconds',type=float,default=14)
parser.add_argument('--arch',default='x86_64',choices=('x86_64','arm64'))
args=parser.parse_args()
args.variants=args.variants or list(VARIANTS)
if unknown:=set(args.variants)-set(VARIANTS):parser.error('unknown variant: '+', '.join(sorted(unknown)))

gamepolicyctl=subprocess.check_output(['/usr/bin/xcrun','--find','gamepolicyctl'],text=True).strip()
folder=ROOT/'logs/game-mode'/datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
folder.mkdir(parents=True)
print(folder,flush=True)

def build(output,plist=None):
    command=['/usr/bin/clang','-arch',args.arch,'-O2','-fobjc-arc','-mmacosx-version-min=15.0',str(ROOT/'tests/game_mode/probe.m'),
        '-framework','AppKit','-framework','Metal','-framework','QuartzCore','-o',str(output)]
    if plist:command[1:1]=['-Wl,-sectcreate,__TEXT,__info_plist,'+str(plist)]
    subprocess.run(command,check=True)

def info(name,variant):
    plist={'CFBundleIdentifier':'org.recall.gamemode-probe.'+name,'CFBundleExecutable':'probe','CFBundleName':'Game Mode Probe',
        'CFBundlePackageType':'APPL','CFBundleInfoDictionaryVersion':'6.0','CFBundleVersion':'1','CFBundleShortVersionString':'1.0',
        'NSPrincipalClass':'NSApplication','LSMinimumSystemVersion':'15.0'}
    if variant.get('keys'):plist.update(GAME_KEYS)
    if variant.get('uielement'):plist['LSUIElement']='1'
    return plist

def gamepolicyd_lines(start,end,pid):
    text=subprocess.run(['/usr/bin/log','show','--style','compact','--start',start,'--end',end,
        '--predicate','process == "gamepolicyd"'],capture_output=True,text=True).stdout
    ours=re.compile(r'[(:]%d[)\]]|pid=%d\b'%(pid,pid))
    keep=[line for line in text.splitlines() if LOG_PATTERN.search(line) or (pid and ours.search(line))]
    identities=sorted({m.group(0) for line in keep if ours.search(line) for m in re.finditer(r'(anon|app)<[^>]*>',line)})
    return keep,identities

results=[]
for name in args.variants:
    variant=VARIANTS[name]
    work=folder/name
    work.mkdir()
    plist=info(name,variant)
    if variant['kind']=='bundle':
        app=work/'Game Mode Probe.app'
        (app/'Contents/MacOS').mkdir(parents=True)
        (app/'Contents/Info.plist').write_bytes(plistlib.dumps(plist))
        build(app/'Contents/MacOS/probe')
        subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(app)],check=True,capture_output=True)
        executable=app/'Contents/MacOS/probe'
    else:
        (work/'Info.plist').write_bytes(plistlib.dumps(plist))
        executable=work/'probe'
        build(executable,work/'Info.plist')
        subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(executable)],check=True,capture_output=True)
    log=work/'probe.jsonl'
    probe_args=['--log',str(log),'--gamepolicyctl',gamepolicyctl,'--seconds',str(args.seconds)]
    start=datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    if variant['launch']=='open':
        subprocess.run(['/usr/bin/open','-W','-n',str(app),'--args',*probe_args],check=True,timeout=args.seconds+60)
    else:
        subprocess.run([str(executable),*probe_args],check=True,timeout=args.seconds+60)
    time.sleep(3)
    end=datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S')
    events=[json.loads(line) for line in log.read_text().splitlines() if line.strip()]
    started=next((e for e in events if e.get('event')=='start'),{})
    checks=[e for e in events if e.get('event')=='check']
    lines,identities=gamepolicyd_lines(start,end,started.get('pid',0))
    (work/'gamepolicyd.log').write_text('\n'.join(lines)+'\n')
    found=[line.split('Found game ',1)[1] for line in lines if 'Found game' in line and str(started.get('pid'))in line]
    result={'variant':name,'summary':variant['summary'],'launch':variant['launch'],'info_plist':plist,
        'probe_saw':{k:started.get(k) for k in ('bundle_identifier','bundle_path','category','supports_game_mode','running_app_bundle_identifier')},
        'runningboard_identity':identities,'found_game':found,
        'game_mode':[c['game_mode'] for c in checks],
        'fullscreen':[c['fullscreen'] for c in checks],'frontmost':[c['frontmost'] for c in checks],
        'frames':checks[-1]['frames'] if checks else 0,
        'engaged':any(c['game_mode']=='on' for c in checks)}
    results.append(result)
    print(json.dumps({k:result[k] for k in ('variant','engaged','game_mode','found_game','runningboard_identity','fullscreen','frontmost','frames')}),flush=True)
    time.sleep(8)  # let Game Mode settle off before the next variant

(folder/'results.json').write_text(json.dumps(results,indent=2)+'\n')
for app in folder.glob('*/Game Mode Probe.app'):
    subprocess.run(['/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister','-u',str(app)],capture_output=True)
