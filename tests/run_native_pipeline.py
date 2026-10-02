#!/usr/bin/env python3
"""Exercise bundled native preparation with newly generated, real Metal recipes."""
import argparse,fcntl,hashlib,json,os,secrets,subprocess
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
def run():return subprocess.run([str(helpers/'ow2-pipeline'),str(root)],capture_output=True,text=True,timeout=180)
with (namespace/'write.lock').open('a') as lock:
    fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    locked=run();assert locked.returncode==75,locked
prepared=run();assert prepared.returncode==0,prepared
assert 'Prepared and verified 3' in prepared.stdout,prepared
assert learning()==before
manifest=json.loads((namespace/'archive.json').read_text());assert len(manifest['prepared_keys'])==3
repeat=run();assert repeat.returncode==0 and 'up to date' in repeat.stdout,repeat
assert learning()==before
assert list((root/'pipeline-staging/cache').glob('*/recipes')),'Prior cache not retained'
(out/'result.json').write_text(json.dumps({'real_render':json.loads(r.stdout),'prepared':prepared.stdout.strip(),'repeat':repeat.stdout.strip(),'lock_exit':locked.returncode,'learned_inputs_unchanged':True,'previous_cache_retained':True},indent=2)+'\n')
print('PASS: native preparation, fresh-process verification, repeat launch, writer lock and prior-cache retention')
