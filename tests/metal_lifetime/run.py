#!/usr/bin/env python3
"""Execute the production compiler-task wrapper with native Metal and real pools.

Checks dependency/exception cleanup and GPU readback after pool drain. Paired
native microbenchmarks isolate temporary lifetime; they are not gameplay proof.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--iterations', type=int, default=3000)
parser.add_argument('--arch', choices=['arm64', 'x86_64'], default='x86_64')
args = parser.parse_args()
source = ROOT / 'runtime/source/dxmt-ow2/src/d3d11/d3d11_pipeline_cache.cpp'
text = source.read_text()
start = text.index('{', text.index('ThreadpoolWork *run_task('))
end, depth = start + 1, 1
while depth:
    depth += (text[end] == '{') - (text[end] == '}')
    end += 1
body = text[start:end]
assert 'MakeAutoreleasePool' in body
output = ROOT / 'logs/dxmt' / ('metal-task-lifetime-' + datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
output.mkdir()
template = (Path(__file__).with_name('harness.mm.in')).read_text()
executables = {}
for name, method in [('before', '{ return task->RunThreadpoolWork(); }'), ('candidate', body)]:
    generated = output / (name + '.mm')
    generated.write_text(template.replace('@RUN_TASK@', method))
    executable = output / name
    subprocess.run(['/usr/bin/clang++', '-arch', args.arch, '-std=c++20', '-O2',
                    '-Wall', '-Wextra', '-Werror', '-fno-objc-arc', str(generated),
                    '-framework', 'Foundation', '-framework', 'Metal', '-o', str(executable)], check=True)
    executables[name] = executable
checks = subprocess.check_output([str(executables['candidate']), 'checks', '1'], text=True, timeout=30)
print(checks.strip(), flush=True)
rows = []
for name in ['before', 'candidate', 'candidate', 'before']:
    result = subprocess.run([str(executables[name]), 'metal', str(args.iterations)],
                            text=True, capture_output=True, check=True, timeout=90)
    row = dict(case=name, **json.loads(result.stdout))
    rows.append(row)
    print(json.dumps(row), flush=True)
report = dict(source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(), arch=args.arch,
              checks=json.loads(checks), runs=rows,
              limitation='Native Metal task microbenchmark under Rosetta for x86_64; not Wine/gameplay. No shader/output changes.')
(output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(output)
