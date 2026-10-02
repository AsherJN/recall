#!/usr/bin/env python3
"""Production standalone preparation: preservation, >128 coverage, strict verification and failure safety."""
import argparse
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
TESTS = Path(__file__).resolve().parent
NATIVE = ROOT / 'runtime/source/dxmt-ow2/src/winemetal/unix'
SPEC = importlib.util.spec_from_file_location('prepare_dxmt_pipelines', ROOT / 'scripts/prepare_dxmt_pipelines.py')
PREP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREP)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--build-helper', action='store_true')
args = parser.parse_args()
if args.build_helper: PREP.build_helper()
PREP.validate_helper()
output = ROOT / 'logs/dxmt' / ('offline-prepare-proof-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
output.mkdir(parents=True)
nonce = secrets.token_hex(8)
red = 32 + int(nonce, 16) % 160
source_hashes = PREP.source_hashes()
lib = output / 'libgame_manager.dylib'
commands = []
for index, green in enumerate((.25, .45, .60)):
    stem = 'fixture' if not index else f'fixture_{index}'
    metal, air, metallib = (output / f'{stem}.{ext}' for ext in ('metal', 'air', 'metallib'))
    suffix = '' if not index else f'_{index}'
    metal.write_text(f'''#include <metal_stdlib>
using namespace metal;
vertex float4 vertex_{nonce}(uint id [[vertex_id]]) {{ const float2 p[3] = {{float2(-1,-1),float2(3,-1),float2(-1,3)}}; return float4(p[id],0,1); }}
fragment float4 fragment_{nonce}{suffix}() {{ return float4({red/255:.10f},{green},.75,1.0); }}
''')
    commands += [['xcrun','-sdk','macosx','metal','-std=metal3.1','-c',str(metal),'-o',str(air)],
                 ['xcrun','-sdk','macosx','metallib',str(air),'-o',str(metallib)]]
commands.append(['/usr/bin/clang','-arch','x86_64','-x','objective-c','-fblocks','-fno-objc-arc','-O2','-dynamiclib',
                 str(NATIVE/'pipeline_recipe.c'),str(NATIVE/'pipeline_cache.c'),'-framework','Foundation','-framework','Metal',
                 '-framework','QuartzCore','-install_name',str(lib),'-o',str(lib)])
for name, source in (('game','manager_render_probe.m'),('variants','offline_variant_probe.m')):
    commands += [['/usr/bin/clang','-arch','x86_64','-x','objective-c','-fblocks','-fobjc-arc','-O2','-I',str(NATIVE),
                  '-Wall','-Wextra','-Werror','-c',str(TESTS/source),'-o',str(output/f'{name}.o')],
                 ['/usr/bin/clang','-arch','x86_64',str(output/f'{name}.o'),str(lib),'-framework','Foundation',
                  '-framework','Metal','-o',str(output/name)]]
with (output/'build.log').open('w') as log:
    for command in commands: subprocess.run(command,check=True,stdout=log,stderr=subprocess.STDOUT)
base_env = {k:v for k,v in os.environ.items() if not k.startswith(('DXMT_','MTL_'))}
namespace = 'offline-prepare-proof-v1'
cache = output/'cache'
reports = []

def run_game(label, target=cache, budget=0, limit=1, defaults=False):
    env = base_env | {'DXMT_PIPELINE_CACHE_PATH':str(target),'DXMT_PIPELINE_CACHE_NAMESPACE':namespace,
                      'DXMT_PIPELINE_CACHE_LOG':str(output/label)}
    if not defaults: env.update(DXMT_PIPELINE_CACHE_PREWARM_MS=str(budget),DXMT_PIPELINE_CACHE_PREWARM_LIMIT=str(limit))
    result = subprocess.run([str(output/'game'),str(output/'fixture.metallib'),nonce,'growth_'+label],
                            env=env,capture_output=True,text=True,timeout=30)
    (output/f'{label}.stderr.log').write_text(result.stderr)
    result.check_returncode()
    data = json.loads(result.stdout)
    events = [json.loads(line) for path in output.glob(label+'-*.jsonl') for line in path.read_text().splitlines()]
    data['summary'] = [x for x in events if x['event']=='summary'][-1]
    data['startup'] = [x for x in events if x['event']=='startup_load'][-1]
    data['runtime'] = [x for x in events if x['event']=='runtime']
    reports.append({'case':label,**data})
    (output/'partial-results.json').write_text(json.dumps(reports,indent=2)+'\n')
    return data

def helper(label, target=cache, verify=False, limit=4096):
    dest=output/label;dest.mkdir()
    data=PREP.run_helper(target,dest,'verify' if verify else 'prepare',namespace=namespace,limit=limit,budget=30000)
    reports.append({'case':label,**data})
    (output/'partial-results.json').write_text(json.dumps(reports,indent=2)+'\n')
    return data

def catalog(target=cache):
    directories=list(target.glob('*/recipes'));assert len(directories)==1
    return directories[0].parent

def digest_tree(directory):
    return {str(p.relative_to(directory)):hashlib.sha256(p.read_bytes()).hexdigest()
            for p in directory.rglob('*') if p.is_file() and p.name != 'write.lock'}

def clone(name, source=cache):
    target=output/name;subprocess.run(['/bin/cp','-cR',str(source),str(target)],check=True);return target

learn=run_game('learn')
assert learn['summary']['prewarmed']==0 and learn['recipe_count']==3
for path in (catalog()/'recipes').glob('*.json'):
    entry=json.loads(path.read_text());entry['cost_us']=30000;path.write_text(json.dumps(entry))
seed=run_game('seed',budget=2000,limit=1)
assert seed['summary']['prewarmed']==1 and seed['summary']['prepared_keys']==1
old_keys=PREP.archive_keys(catalog());assert len(old_keys)==1
learned_hashes={k:v for k,v in digest_tree(catalog()).items() if k.startswith(('recipes/','libraries/'))}
prepared=helper('compact_three')
assert prepared['prepared']==3 and prepared['archive_failures']==0 and prepared['archive_batches']==1,prepared
assert old_keys.issubset(PREP.archive_keys(catalog())) and len(PREP.archive_keys(catalog()))==3
assert all(digest_tree(catalog())[k]==v for k,v in learned_hashes.items())
before_verify=digest_tree(catalog())
verified=helper('verify_three',verify=True)
assert digest_tree(catalog())==before_verify, 'verification changed immutable cache'
assert verified['prepared']==3 and verified['failures']==verified['archive_failures']==0 and verified['verify_only']

for failure in ('missing_recipe','missing_library','corrupt_archive'):
    target=clone(failure)
    directory=catalog(target)
    if failure=='missing_recipe': (directory/'recipes'/f'{next(iter(old_keys))}.json').unlink()
    elif failure=='missing_library':
        recipe=json.loads((directory/'recipes'/f'{next(iter(old_keys))}.json').read_text())['recipe']
        (directory/'libraries'/f"{recipe['vertex']['library']}.air").unlink()
    else:
        manifest=json.loads((directory/'archive.json').read_text())
        (directory/'archives'/f"{manifest['archives'][0]['sha256']}.metallib").write_bytes(b'corrupt isolated fixture')
    before=(directory/'archive.json').read_bytes()
    prior_tree=digest_tree(directory)
    failed_verify=helper(failure+'_verify',target,verify=True)
    assert failed_verify['prepared'] != 3 or failed_verify['failures'] or failed_verify['archive_failures'], failed_verify
    assert digest_tree(directory)==prior_tree, 'strict failure mutated cache'
    result=helper(failure+'_prepare',target)
    assert result['archive_failures']>0,result
    if failure!='corrupt_archive': assert (directory/'archive.json').read_bytes()==before,'lost old coverage was published'
    # Corrupt input may be repaired inside the disposable clone; the Python
    # publisher rejects its reported archive failures and never publishes it.

variant_result=subprocess.run([str(output/'variants'),str(output/'fixture.metallib'),nonce,str(catalog()),'256'],
                               env=base_env,capture_output=True,text=True,check=True)
reports.append({'case':'legal_codec_variants',**json.loads(variant_result.stdout)})
assert len(list((catalog()/'recipes').glob('*.json')))==259
larger=helper('beyond_128')
assert larger['prepared']==259 and larger['archive_failures']==0 and larger['archive_batches']==1,larger
verified=helper('verify_259',verify=True)
assert verified['prepared']==259 and verified['failures']==verified['archive_failures']==0,verified
runtime=run_game('runtime_archives',budget=1000,limit=0)
assert runtime['summary']['prewarmed']==0 and runtime['summary']['archive_lookup_hits']==3,runtime
assert runtime['runtime'] and any(r.get('known_at_launch') is True and r.get('archive_result')==1 for r in runtime['runtime']),runtime
early=run_game('early_inventory')
unknown=[r for r in early['runtime'] if r.get('lookup_reason')==4]
assert all(r.get('known_at_launch') is None for r in unknown),early
reports[-1]['unknown_inventory_rows']=len(unknown)
normal=run_game('normal_defaults',defaults=True)
assert normal['startup']['prewarm_limit']==128 and 0 <= normal['startup']['budget_remaining_ms'] <= 10000,normal
assert normal['summary']['prewarmed']==128 and not normal['summary']['offline_prepare'],normal
report={'production_source_sha256':source_hashes,'source_changed_during_run':PREP.source_hashes()!=source_hashes,
        'helper_manifest':json.loads((PREP.HELPER/'manifest.json').read_text()),'results':reports,
        'limits':['Standalone native Metal verification, no game performance claim.','Production codec identities with legal mutability variants; same shader functions intentionally reused for bounded compilation.']}
(output/'report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps({'output':str(output),'source_changed_during_run':report['source_changed_during_run'],
                  'passed_cases':[r['case'] for r in reports]},indent=2))
