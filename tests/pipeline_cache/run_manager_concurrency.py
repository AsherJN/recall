#!/usr/bin/env python3
"""Actual x86_64 manager: concurrent retained PSOs, shutdown fallback and writer lease."""
import datetime,hashlib,json,os,secrets,select,subprocess
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
HERE=Path(__file__).resolve().parent
NATIVE=ROOT/'runtime/source/dxmt-ow2/src/winemetal/unix'
OUT=ROOT/'logs/dxmt'/('pipeline-concurrency-proof-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
OUT.mkdir()
names=('pipeline_recipe.c','pipeline_recipe.h','pipeline_cache.c','pipeline_cache.h')
hashes={n:hashlib.sha256((NATIVE/n).read_bytes()).hexdigest() for n in names}
nonce=secrets.token_hex(8);red=32+int(nonce,16)%160
metal=OUT/'fixture.metal';air=OUT/'fixture.air';metallib=OUT/'fixture.metallib';library=OUT/'libconcurrency.dylib';binary=OUT/'concurrency'
metal.write_text(f'''#include <metal_stdlib>
using namespace metal;
vertex float4 vertex_{nonce}(uint id [[vertex_id]]) {{ const float2 p[3]={{float2(-1,-1),float2(3,-1),float2(-1,3)}};return float4(p[id],0,1); }}
fragment float4 fragment_{nonce}() {{return float4({red/255:.10f},0.25,0.75,1);}}
fragment float4 alternate_{nonce}() {{return float4({red/255:.10f},0.60,0.75,1);}}
''')
flags=['/usr/bin/clang','-arch','x86_64','-x','objective-c','-fblocks','-fno-objc-arc','-O1','-fsanitize=address,undefined','-fno-omit-frame-pointer']
commands=[['xcrun','-sdk','macosx','metal','-std=metal3.1','-c',str(metal),'-o',str(air)],
 ['xcrun','-sdk','macosx','metallib',str(air),'-o',str(metallib)],
 flags+['-dynamiclib',str(NATIVE/'pipeline_recipe.c'),str(NATIVE/'pipeline_cache.c'),'-framework','Foundation','-framework','Metal','-framework','QuartzCore','-install_name',str(library),'-o',str(library)],
 flags+['-Wall','-Wextra','-Werror','-I',str(NATIVE),'-c',str(HERE/'manager_concurrency_probe.m'),'-o',str(OUT/'probe.o')],
 ['/usr/bin/clang','-arch','x86_64','-fsanitize=address,undefined',str(OUT/'probe.o'),str(library),'-framework','Foundation','-framework','Metal','-o',str(binary)]]
with (OUT/'build.log').open('w') as log:
 for c in commands:subprocess.run(c,check=True,stdout=log,stderr=subprocess.STDOUT)
env={k:v for k,v in os.environ.items() if not k.startswith(('DXMT_','MTL_'))}
env.update(ASAN_OPTIONS='detect_leaks=0',DXMT_PIPELINE_CACHE_NAMESPACE='concurrency-proof-v1',DXMT_PIPELINE_CACHE_PREWARM_MS='500',DXMT_PIPELINE_CACHE_PREWARM_LIMIT='4')
def environment(mode,cache):return dict(env,DXMT_PIPELINE_CACHE_PATH=str(cache),DXMT_PIPELINE_CACHE_LOG=str(OUT/mode))
def events(mode):
 files=list(OUT.glob(mode+'-*.jsonl'));assert len(files)==1,files
 return [json.loads(x) for x in files[0].read_text().splitlines()]
r=subprocess.run([str(binary),str(metallib),nonce,'concurrent'],env=environment('concurrent',OUT/'concurrent-cache'),capture_output=True,text=True,timeout=25)
(OUT/'concurrent.stderr').write_text(r.stderr)
assert r.returncode==0,(r.stdout,r.stderr)
concurrent=json.loads(r.stdout)
lease_cache=OUT/'lease-cache'
# Prepare two immutable archive batches across processes. The later owner and
# reader therefore exercise an NSArray with multiple retained archive objects.
for seed_mode in ('lease_seed','lease_first_archive'):
 seed_env=environment(seed_mode,lease_cache)
 seed_env['DXMT_PIPELINE_CACHE_PREWARM_LIMIT']='1'
 seed_result=subprocess.run([str(binary),str(metallib),nonce,'lease'],env=seed_env,capture_output=True,text=True,timeout=12)
 (OUT/(seed_mode+'.stderr')).write_text(seed_result.stderr)
 assert seed_result.returncode==0,(seed_result.stdout,seed_result.stderr)
assert len(list(lease_cache.glob('*/archives/*.metallib')))==1, 'first bounded startup did not create one archive batch'
owner=subprocess.Popen([str(binary),str(metallib),nonce,'owner'],env=environment('owner',lease_cache),stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
try:
 assert select.select([owner.stdout],[],[],20)[0], 'owner startup exceeded bounded test deadline'
 assert owner.stdout.readline().strip()=='READY','owner did not reach steady writer lease'
 def snapshot():return {str(p.relative_to(lease_cache)):hashlib.sha256(p.read_bytes()).hexdigest() for p in lease_cache.rglob('*') if p.is_file()}
 before=snapshot()
 assert len(list(lease_cache.glob('*/archives/*.metallib')))==2, 'second startup did not preserve and extend immutable batches'
 r=subprocess.run([str(binary),str(metallib),nonce,'lease'],env=environment('lease',lease_cache),capture_output=True,text=True,timeout=12)
 (OUT/'lease.stderr').write_text(r.stderr)
 assert r.returncode==0,(r.stdout,r.stderr)
 lease=json.loads(r.stdout)
 after=snapshot();assert before==after,'read-only second process changed cache files'
 owner.stdout.flush();out,error=owner.communicate('\n',timeout=5)
 (OUT/'owner.stderr').write_text(error);assert owner.returncode==0,(out,error)
finally:
 if owner.poll() is None:owner.kill();owner.wait()
owner_events=events('owner');lease_events=events('lease')
owner_summary=[e for e in owner_events if e['event']=='summary'][-1]
lease_summary=[e for e in lease_events if e['event']=='summary'][-1]
assert owner_summary['write_owner'] and not lease_summary['write_owner'],(owner_summary,lease_summary)
assert lease_summary['prewarmed']==2 and lease_summary['archive_adds']==0,lease_summary
assert lease_summary['archive_lookup_hits']>=2,lease_summary
report={'architecture':'x86_64','sanitizers':['address','undefined'],'source_hashes':hashes,'sources_unchanged':hashes=={n:hashlib.sha256((NATIVE/n).read_bytes()).hexdigest() for n in names},'concurrent':concurrent,'lease':lease,'owner_summary':owner_summary,'lease_summary':lease_summary,'readonly_cache_unchanged':before==after,'immutable_archive_batches':2,'compiler_commands':commands,'limits':['Standalone production native dylib and real Metal rendering, no Wine or game performance claim.','Try-lock contention may intentionally fall back to ordinary creation; correct pixels and retained ownership are required, not a 100% cache-hit rate.','Leak checks disabled because production manager/pin intentionally have process lifetime; address/undefined checks enabled.']}
(OUT/'report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'artifact':str(OUT/'report.json'),'concurrent':concurrent,'readonly_cache_unchanged':before==after,'owner_write_lease':owner_summary['write_owner'],'reader_write_lease':lease_summary['write_owner'],'reader_prewarmed':lease_summary['prewarmed'],'immutable_archive_batches':2,'reader_strict_archive_hits':lease_summary['archive_lookup_hits'],'sources_unchanged':report['sources_unchanged']},indent=2))
