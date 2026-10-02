#!/usr/bin/env python3
"""Exercise the actual resource logger under sanitizers, then measure hot-path cost."""
import argparse
import csv
import json
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument('--arch', choices=['arm64', 'x86_64'], default='arm64')
parser.add_argument('--output', type=Path)
args = parser.parse_args()
report = {'arch': args.arch, 'cases': {}}
with tempfile.TemporaryDirectory(prefix='resource-trace-', dir=ROOT/'tests/resource_trace') as temp:
    d = Path(temp)
    (d/'thread.hpp').write_text('#pragma once\n#include <thread>\nnamespace dxmt { using thread=std::thread; namespace this_thread { inline bool isInModuleDetachment(){return false;} } }\n')
    (d/'dxmt_resource_log.hpp').write_bytes((ROOT/'runtime/source/dxmt-ow2/src/dxmt/dxmt_resource_log.hpp').read_bytes())
    common = ['/usr/bin/clang++', '-arch', args.arch, '-std=c++20', '-Wall', '-Wextra', '-Werror',
              '-I'+str(d), str(ROOT/'tests/resource_trace/harness.cpp')]
    subprocess.run(common + ['-DDXMT_RESOURCE_SEGMENT_BYTES=4096', '-fsanitize=address,undefined',
                             '-fno-omit-frame-pointer', '-o', str(d/'harness')], check=True)
    for mode in ['disabled', 'normal', 'concurrent', 'rotation', 'missing', 'blocked']:
        target = d/mode
        if mode == 'missing': target = target/'absent'/'ops'
        started = time.monotonic()
        result = subprocess.run([str(d/'harness'), str(target), mode], capture_output=True, text=True, timeout=20)
        assert result.returncode == 0, result.stderr
        elapsed = time.monotonic()-started
        summaries = list(d.glob(mode+'-*.summary.json'))
        if mode in ['disabled', 'missing', 'blocked']:
            assert not summaries
            if mode == 'blocked': assert elapsed < 2.5, elapsed
            report['cases'][mode] = {'pass': True, 'elapsed': elapsed}
            print('PASS:', mode)
            continue
        assert len(summaries) == 1
        summary = json.loads(summaries[0].read_text())
        assert summary['io_errors'] == summary['disk_rows_lost'] == 0, summary
        ops = summary['operations']
        if mode == 'normal':
            # Admission may lose a call on writer contention, but never conceal it.
            calls = sum(a['calls'] for a in ops.values())
            assert calls + summary['dropped_calls'] == 5003, summary
            assert ops['buffer_upload']['bytes'] == ops['buffer_upload']['calls'] * 256
            assert ops['buffer_release']['max_ns'] >= 4000000
            assert ops['release_batch']['max_ns'] >= ops['buffer_release']['max_ns']
            assert ops['map_immediate']['calls'] <= 1  # finish() is idempotent.
        else:
            expected_calls = 8000 if mode == 'rotation' else 80000
            assert ops['buffer_allocate']['calls'] + summary['dropped_calls'] == expected_calls, {
                key: summary[key] for key in ['snapshot', 'shutdown_requested', 'dropped_calls']
            } | {'calls': ops['buffer_allocate']['calls']}
            assert ops['buffer_allocate']['bytes'] == ops['buffer_allocate']['calls'] * 1024
            if mode == 'rotation':
                assert summary['slow_spans_accepted'] + summary['dropped_slow_spans'] == ops['buffer_allocate']['calls']
            else:
                assert summary['slow_spans_accepted'] == summary['dropped_slow_spans'] == 0
            if mode == 'rotation': assert summary['event_rotations'] > 3
        for path in d.glob(mode+'-*.csv'):
            assert path.stat().st_size < 4700
            rows = list(csv.DictReader(path.open()))
            assert all(None not in row and None not in row.values() for row in rows)
        report['cases'][mode] = {'pass': True, 'summary': summary}
        print('PASS:', mode)
    subprocess.run(common + ['-O3', '-o', str(d/'bench')], check=True)
    report['scope_ns'] = {}
    for mode in ['disabled', 'bench']:
        values = []
        for attempt in range(5):
            result = subprocess.run([str(d/'bench'), str(d/f'{mode}{attempt}'), mode],
                                    capture_output=True, text=True, check=True, timeout=10)
            values.append(float(result.stdout.splitlines()[0].split('=')[1]))
        report['scope_ns'][mode] = values
    print(json.dumps(report['scope_ns']))
if args.output:
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2)+'\n')
