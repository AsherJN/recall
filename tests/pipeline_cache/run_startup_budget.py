#!/usr/bin/env python3
"""Compare real-cache startup under the production 128-state/10-second policy.

Every trial uses an APFS clone; installed caches and runtimes are not modified.
The control restores the old duplicate ranking validation in a generated copy.
"""
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
native = ROOT / 'runtime/source/dxmt-ow2/src/winemetal/unix'
cache = ROOT / 'runtime/dxmt-pipeline-cache-source'
output = ROOT / 'logs/dxmt' / ('startup-budget-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
output.mkdir()
source = (native / 'pipeline_cache.c').read_text()
old_validation = '''      NSDictionary *recipe = dxmt_recipe_decode(dxmt_recipe_encode(entry[@"recipe"]));
      if (!recipe || ![dxmt_recipe_key(recipe) isEqualToString:name.stringByDeletingPathExtension]) continue;
'''
start = source.index('      // Ranking needs only bounded cost metadata.')
end = source.index('      double cost = [entry[@"cost_us"] doubleValue];', start)
control = source[:start] + old_validation + source[end:]
original_archives = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in cache.glob('*/archive.json')}
executables = {}
for name, text in [('before', control), ('candidate', source)]:
    folder = output / name; folder.mkdir()
    generated = folder / 'pipeline_cache.c'; generated.write_text(text)
    library = folder / 'libstartup.dylib'
    executable = folder / 'probe'
    commands = [
        ['/usr/bin/clang', '-arch', 'x86_64', '-x', 'objective-c', '-fblocks', '-fno-objc-arc',
         '-DDXMT_PIPELINE_CACHE_TESTING', '-O2', '-dynamiclib', '-I', str(native), str(generated),
         str(native/'pipeline_recipe.c'), '-framework', 'Foundation', '-framework', 'Metal',
         '-framework', 'QuartzCore', '-install_name', str(library), '-o', str(library)],
        ['/usr/bin/clang', '-arch', 'x86_64', '-fobjc-arc', '-fblocks', '-DDXMT_PIPELINE_CACHE_TESTING',
         '-I', str(native), str(Path(__file__).with_name('startup_budget.m')), str(library),
         '-framework', 'Foundation', '-framework', 'Metal', '-framework', 'QuartzCore', '-o', str(executable)]
    ]
    with (folder/'build.log').open('w') as stream:
        for command in commands:
            subprocess.run(command, check=True, stdout=stream, stderr=subprocess.STDOUT)
    executables[name] = executable
rows = []
for index, name in enumerate(['before', 'candidate', 'candidate', 'before']):
    target = output / f'{index}-{name}'; target.mkdir()
    cloned = target / 'cache'
    subprocess.run(['/bin/cp', '-cR', str(cache), str(cloned)], check=True)
    env = {k:v for k,v in os.environ.items() if not k.startswith(('DXMT_', 'MTL_'))}
    env.update(DXMT_PIPELINE_CACHE_PATH=str(cloned), DXMT_PIPELINE_CACHE_NAMESPACE='ow2-source-v1',
               DXMT_PIPELINE_CACHE_PREWARM_LIMIT='128', DXMT_PIPELINE_CACHE_PREWARM_MS='10000',
               DXMT_PIPELINE_CACHE_PREFER_EXPENSIVE='1', DXMT_PIPELINE_CACHE_LOG=str(target/'pipeline'))
    result = subprocess.run([str(executables[name])], env=env, capture_output=True, text=True, check=True, timeout=45)
    (target/'stderr.log').write_text(result.stderr)
    events = [json.loads(line) for p in target.glob('pipeline-*.jsonl') for line in p.read_text().splitlines()]
    summaries = [r for r in events if r['event'] == 'summary']
    assert summaries and summaries[-1]['startup_done'], events
    summary = summaries[-1]
    row = dict(case=name, **json.loads(result.stdout), prewarmed=summary['prewarmed'],
               failures=summary['prewarm_failures'], archive_failures=summary['archive_failures'],
               rank=next((r for r in events if r['event']=='prewarm_ranked'), None))
    assert row['archive_failures'] == 0, row
    rows.append(row); print(json.dumps(row), flush=True)
    shutil.rmtree(cloned)  # Only this trial's generated clone; preserve installed cache.
assert all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==digest for p,digest in original_archives.items())
(output/'report.json').write_text(json.dumps(dict(source_sha256=hashlib.sha256(source.encode()).hexdigest(),
    runs=rows, original_archive_manifests_unchanged=True,
    limitation='Native x86_64 manager on cloned learned cache, warm filesystem/system Metal cache; not gameplay.'), indent=2)+'\n')
print(output)
