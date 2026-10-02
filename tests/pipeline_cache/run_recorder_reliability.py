#!/usr/bin/env python3
"""Bounded recorder stress with production codec data and isolated native caches."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, default=ROOT / 'runtime/source/dxmt-ow2')
parser.add_argument('--arch', choices=('arm64', 'x86_64'), default='x86_64')
parser.add_argument('--sanitize', action='store_true')
parser.add_argument('--fixture-only', action='store_true', help='Validate large real-codec fixture without compiling the manager.')
args = parser.parse_args()
directory = Path(__file__).resolve().parent
native = args.source / 'src/winemetal/unix'
output = ROOT / 'logs/dxmt' / ('recorder-reliability-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
output.mkdir(parents=True, exist_ok=False)
nonce = secrets.token_hex(8)
red = 32 + int(nonce, 16) % 160
metal, air, metallib = (output / name for name in ('fixture.metal', 'fixture.air', 'fixture.metallib'))
metal.write_text(f'''#include <metal_stdlib>
using namespace metal;
vertex float4 vertex_{nonce}(uint id [[vertex_id]]) {{
  const float2 p[3] = {{float2(-1,-1),float2(3,-1),float2(-1,3)}};
  return float4(p[id],0,1);
}}
fragment float4 fragment_{nonce}() {{ return float4({red / 255:.10f},0.25,0.75,1.0); }}
''')
production = ['pipeline_recipe.c', 'pipeline_recipe.h']
if not args.fixture_only:
    production += ['pipeline_cache.c', 'pipeline_cache.h']
before = {name:hashlib.sha256((native / name).read_bytes()).hexdigest() for name in production}
library = output / 'librecorder_test.dylib'
sources = [str(native / 'pipeline_recipe.c')]
defines = []
if not args.fixture_only:
    sources += [str(native / 'pipeline_cache.c')]
    defines = ['-DDXMT_PIPELINE_CACHE_TESTING=1']
commands = [
    ['xcrun', '-sdk', 'macosx', 'metal', '-std=metal3.1', '-c', str(metal), '-o', str(air)],
    ['xcrun', '-sdk', 'macosx', 'metallib', str(air), '-o', str(metallib)],
    ['/usr/bin/clang', '-arch', args.arch, '-x', 'objective-c', '-fblocks', '-fno-objc-arc', '-O2', '-dynamiclib',
     *defines, *sources, '-framework', 'Foundation', '-framework', 'Metal', '-framework', 'QuartzCore',
     '-install_name', str(library), '-o', str(library)],
    ['/usr/bin/clang', '-arch', args.arch, '-x', 'objective-c', '-fblocks', '-fobjc-arc', '-O2', *defines,
     '-I', str(native), '-Wall', '-Wextra', '-Werror', '-c', str(directory / 'recorder_reliability_probe.m'),
     '-o', str(output / 'probe.o')],
    ['/usr/bin/clang', '-arch', args.arch, str(output / 'probe.o'), str(library),
     '-framework', 'Foundation', '-framework', 'Metal', '-o', str(output / 'probe')],
]
if args.sanitize:
    for command in commands:
        if command[0] == '/usr/bin/clang':
            command[1:1] = ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']
with (output / 'build.log').open('w') as log:
    for command in commands:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
environment = {k:v for k,v in os.environ.items() if not k.startswith(('DXMT_', 'MTL_'))}
if args.sanitize:
    environment['ASAN_OPTIONS'] = 'detect_leaks=0'
results = []
for mode in (['fixture'] if args.fixture_only else ['fixture','burst','capacity','dependencies','limits','byte_budget','hit_retry','io_retry']):
    env = environment.copy()
    env.update(DXMT_PIPELINE_CACHE_PATH=str(output / (mode + '-cache')),
               DXMT_PIPELINE_CACHE_NAMESPACE='recorder-reliability-v1',
               DXMT_PIPELINE_CACHE_PREWARM_MS='0', DXMT_PIPELINE_CACHE_LOG=str(output / mode))
    result = subprocess.run([str(output / 'probe'), str(metallib), nonce, mode],
                            env=env, capture_output=True, text=True, timeout=90)
    (output / (mode + '.stderr.log')).write_text(result.stderr)
    (output / (mode + '.stdout.json')).write_text(result.stdout)
    if result.returncode:
        raise RuntimeError(f'{mode} failed ({result.returncode}); artifacts: {output}\n{result.stderr}')
    decoded = json.loads(result.stdout)
    if mode in ('burst','capacity','dependencies','limits','hit_retry','io_retry'):
        caches=list((output/(mode+'-cache')).glob('*'))
        assert len(caches)==1,caches
        for path in (caches[0]/'recipes').glob('*.json'):
            recipe=json.loads(path.read_text())['recipe']
            for stage in ('vertex','fragment'):
                if recipe[stage] is None: continue
                key=recipe[stage]['library'];data=(caches[0]/'libraries'/(key+'.air')).read_bytes()
                assert hashlib.sha256(data).hexdigest()==key,(mode,path)
        decoded['all_saved_recipe_dependencies_hash_verified']=True
    results.append({'mode':mode, **decoded})
    (output/'partial-results.json').write_text(json.dumps(results,indent=2)+'\n')
    print(mode+': passed',flush=True)
after = {name:hashlib.sha256((native / name).read_bytes()).hexdigest() for name in production}
report = {'architecture':args.arch, 'sanitized':args.sanitize, 'fixture_only':args.fixture_only,
          'production_source_sha256':before, 'source_changed_during_run':before != after,
          'compiler_commands':commands, 'results':results}
(output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps({'output':str(output), 'source_changed_during_run':before != after,
                  'passed_modes':[r['mode'] for r in results]}, indent=2))
