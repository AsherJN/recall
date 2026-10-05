#!/usr/bin/env python3
"""Exercise bundled native preparation with newly generated, real Metal recipes."""
import argparse,fcntl,hashlib,json,os,plistlib,secrets,shutil,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
p=argparse.ArgumentParser();p.add_argument('--app',type=Path,required=True);p.add_argument('--output',type=Path,required=True);a=p.parse_args()
out=a.output.resolve();out.mkdir(parents=True,exist_ok=False)
helpers=a.app.resolve()/'Contents/Helpers'
native=ROOT/'runtime/phase-2/dxmt-source/src/winemetal/unix'
nonce=secrets.token_hex(8);red=32+int(nonce,16)%160
commands=[]
for i,green in enumerate((.25,.45,.60)):
    stem='fixture'+('' if not i else '_'+str(i));suffix='' if not i else '_'+str(i)
    metal=out/(stem+'.metal');metal.write_text(f'''#include <metal_stdlib>
using namespace metal;
vertex float4 vertex_{nonce}(uint id [[vertex_id]]) {{ const float2 p[3] = {{float2(-1,-1),float2(3,-1),float2(-1,3)}}; return float4(p[id],0,1); }}
fragment float4 fragment_{nonce}{suffix}() {{ return float4({red/255:.10f},{green},.75,1.0); }}
''')
    commands.extend([['xcrun','metal','-std=metal3.1','-c',str(metal),'-o',str(out/(stem+'.air'))],['xcrun','metallib',str(out/(stem+'.air')),'-o',str(out/(stem+'.metallib'))]])
lib=out/'libfixture.dylib'
commands.append(['/usr/bin/clang','-arch','x86_64','-x','objective-c','-fblocks','-fno-objc-arc','-O2','-dynamiclib',str(native/'pipeline_recipe.c'),str(native/'pipeline_cache.c'),'-framework','Foundation','-framework','Metal','-framework','QuartzCore','-install_name',str(lib),'-o',str(lib)])
commands.append(['/usr/bin/clang','-arch','x86_64','-x','objective-c','-fblocks','-fobjc-arc','-O2','-I',str(native),str(ROOT/'tests/pipeline_cache/manager_render_probe.m'),'-x','none',str(lib),'-framework','Foundation','-framework','Metal','-o',str(out/'fixture')])
with (out/'build.log').open('w') as log:
    for cmd in commands:subprocess.run(cmd,check=True,stdout=log,stderr=subprocess.STDOUT)
root=out/'User Directory With Spaces';cache=root/'cache/pipelines';cache.mkdir(parents=True)
env={k:v for k,v in os.environ.items() if not k.startswith(('DXMT_','MTL_'))}
env.update(DXMT_PIPELINE_CACHE_PATH=str(cache),DXMT_PIPELINE_CACHE_NAMESPACE='ow2-source-v1',DXMT_PIPELINE_CACHE_PREWARM_MS='0',DXMT_PIPELINE_CACHE_PREWARM_LIMIT='1')
r=subprocess.run([str(out/'fixture'),str(out/'fixture.metallib'),nonce,'growth_native'],env=env,capture_output=True,text=True,timeout=40);r.check_returncode()
namespace=next(cache.glob('*/recipes')).parent
for file in (namespace/'recipes').glob('*.json'):
    data=json.loads(file.read_text());data['cost_us']=50000;file.write_text(json.dumps(data))
def learning():return {str(f.relative_to(namespace)):hashlib.sha256(f.read_bytes()).hexdigest() for d in ('recipes','libraries') for f in (namespace/d).iterdir() if f.is_file()}
before=learning()
def run(*game):return subprocess.run([str(helpers/'ow2-pipeline'),str(root),*map(str,game)],capture_output=True,text=True,timeout=180)
with (namespace/'write.lock').open('a') as lock:
    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    locked=run();assert locked.returncode==75,locked
prepared=run();assert prepared.returncode==0,prepared
assert 'Prepared and verified 3' in prepared.stdout,prepared
assert learning()==before
manifest=json.loads((namespace/'archive.json').read_text());assert len(manifest['prepared_keys'])==3
repeat=run();assert repeat.returncode==0 and 'up to date' in repeat.stdout,repeat
# Progress lines for the launcher's "Preparing graphics" details (the worker forwards them).
def steps(result):return [v for v in (json.loads(l) for l in result.stdout.splitlines() if l.startswith('{')) if 'graphics' in v]
first=steps(prepared);assert [v['graphics'] for v in first if v['graphics']!='pipelines']==['learned','checking','preparing','verifying','done'],first
items=[i for v in first if v['graphics']=='pipelines' for i in v['items']]
assert len(items)==3 and all(len(k)==12 and n is True and ms>=0 for k,ms,n in items),items
assert first[0]=={'graphics':'learned','learned':3,'ready':0} and first[-1]=={'graphics':'done','ready':3,'added':3,'warmed':0},first
assert steps(repeat)==[{'graphics':'learned','learned':3,'ready':3},{'graphics':'done','ready':3,'added':0,'warmed':0}],steps(repeat)
assert learning()==before
assert list((root/'pipeline-staging/cache').glob('*/recipes')),'Prior cache not retained'
# The game's folder name hashes macOS's registry ID for the GPU, which changes at
# each restart. Preparation moves earlier folders into the one the game opens now.
(out/'identity.m').write_text('#import <Metal/Metal.h>\nint main(void){@autoreleasepool{id<MTLDevice> d=MTLCreateSystemDefaultDevice();printf("%llu\\n%s\\n%s\\n",d.registryID,NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String,d.name.UTF8String);}return 0;}\n')
subprocess.run(['/usr/bin/clang','-x','objective-c','-fobjc-arc',str(out/'identity.m'),'-framework','Foundation','-framework','Metal','-o',str(out/'identity')],check=True)
rid,system,gpu=subprocess.run([str(out/'identity')],capture_output=True,text=True,check=True).stdout.splitlines()
def folder(registry,macos=system):return cache/hashlib.sha256(f'dxmt-render-cache-v1|ow2-source-v1|{macos}|{registry}|{gpu}'.encode()).hexdigest()
assert namespace==folder(rid),'pipeline_cache.c names its folder differently; update consolidate() in portable_pipeline.swift'
archives=sorted(p.name for p in (namespace/'archives').iterdir())
earlier=folder(int(rid)-41);namespace.rename(earlier)
restart=run();assert restart.returncode==0 and 'moved same_macos, 0 added, 0 removed' in restart.stdout and 'up to date' in restart.stdout,restart
assert steps(restart)[0]=={'graphics':'kept','folders':1,'added':0},steps(restart)
assert not earlier.exists() and sorted(p.name for p in (namespace/'archives').iterdir())==archives and learning()==before
older=folder(rid,'Version 15.0 (Build 24A335)');shutil.copytree(namespace,older)
(namespace/'recipes'/next(iter(json.loads((namespace/'archive.json').read_text())['prepared_keys']))).with_suffix('.json').unlink()
with (older/'write.lock').open('a') as lock:
    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    busy=run();assert busy.returncode==0 and 'in use' in busy.stdout and older.is_dir(),busy
merged=run();assert merged.returncode==0 and 'moved none, 1 added, 1 removed' in merged.stdout,merged
assert not older.exists() and learning()==before
namespace.rename(older)
# Archives from another macOS are dropped, so all three are prepared again.
moved=run();assert moved.returncode==0 and 'moved other_macos' in moved.stdout and 'Prepared and verified 3' in moved.stdout,moved
assert not older.exists() and learning()==before and len(json.loads((namespace/'archive.json').read_text())['prepared_keys'])==3
# With Game Mode the game runs as its own app with its own Metal shader cache, which
# preparation warms once per app, macOS version and GPU (here a test identity).
identifier='org.overwatch2mac.pipeline-test-'+nonce
caches=Path(subprocess.run(['/usr/bin/getconf','DARWIN_USER_CACHE_DIR'],capture_output=True,text=True,check=True).stdout.strip())
game=out/'Game.app';(game/'Contents').mkdir(parents=True);(game/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':identifier}))
try:
    warmed=run(game);assert warmed.returncode==0 and f'Warmed 3 learned pipelines for {identifier}' in warmed.stdout,warmed
    assert [v['graphics'] for v in steps(warmed) if v['graphics']!='pipelines'][:2]==['learned','warming'] and steps(warmed)[-1]['warmed']==3,steps(warmed)
    assert [p for p in (caches/identifier/'com.apple.metal').rglob('*') if p.is_file()],'Nothing in the game app\'s shader cache'
    assert json.loads((root/'cache/warmed.json').read_text())=={'app':identifier,'macos':system,'gpu':gpu}
    rewarm=run(game);assert rewarm.returncode==0 and 'Warmed' not in rewarm.stdout and steps(rewarm)[-1]['warmed']==0,rewarm
    assert learning()==before
finally:shutil.rmtree(caches/identifier,ignore_errors=True)
(out/'result.json').write_text(json.dumps({'real_render':json.loads(r.stdout),'prepared':prepared.stdout.strip(),'progress':first,'repeat':repeat.stdout.strip(),'lock_exit':locked.returncode,'learned_inputs_unchanged':True,'previous_cache_retained':True,
    'after_restart':restart.stdout.strip(),'earlier_folder_in_use':busy.stdout.strip(),'merged':merged.stdout.strip(),'other_macos':moved.stdout.strip(),'warmed':warmed.stdout.strip()},indent=2)+'\n')
print('PASS: native preparation, fresh-process verification, repeat launch, writer lock, prior-cache retention, folders from earlier restarts, progress lines and the game app\'s shader warm-up')
