#!/usr/bin/env python3
"""Exercise actual trace sink: sparse abrupt exit, bounded blocked I/O and races."""
import csv
import os
from pathlib import Path
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
trace = (ROOT / 'runtime/source/dxmt-ow2/src/d3d11/d3d11_shader_trace.hpp').read_text()
trace = '\n'.join(line for line in trace.splitlines() if not line.startswith('#include "') and line != '#pragma once')
harness = (HERE / 'harness.cpp.in').read_text().replace('@SHADER_TRACE@', trace)


def rows(path):
    with path.open() as stream:
        return list(csv.DictReader(stream))


with tempfile.TemporaryDirectory(prefix='trace-', dir=HERE) as temp:
    directory = Path(temp)
    source, executable = directory / 'test.cpp', directory / 'test'
    source.write_text(harness)
    subprocess.run(['/usr/bin/clang++', '-std=c++20', '-Wall', '-Wextra', '-Werror', '-pthread',
                    '-fsanitize=address,undefined', '-fno-omit-frame-pointer', str(source), '-o', str(executable)], check=True)
    env = dict(os.environ, ASAN_OPTIONS='detect_leaks=0') # Sink intentionally lives for process lifetime.
    for mode in ('disabled', 'abrupt', 'atexit', 'concurrent', 'blocked'):
        prefix = directory / mode
        current = dict(env)
        current.pop('DXMT_SHADER_LOG', None)
        if mode != 'disabled':
            current['DXMT_SHADER_LOG'] = str(prefix)
        before = set(directory.iterdir())
        fifo_result = []
        if mode == 'blocked':
            fifo = Path(str(prefix) + '-42.csv')
            os.mkfifo(fifo)
            process = subprocess.Popen([str(executable), mode], env=current, text=True,
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            first = process.stdout.readline()
            assert first.startswith('UNBLOCK '), first
            def drain():
                with fifo.open() as stream:
                    fifo_result.extend(csv.DictReader(stream))
            reader = threading.Thread(target=drain)
            reader.start()
            process.stdin.write('released\n')
            process.stdin.flush()
            output, error = process.communicate(timeout=10)
            reader.join(timeout=5)
            assert not reader.is_alive(), 'writer never released FIFO'
            assert process.returncode == 0, (output, error)
            print(first.strip())
        else:
            subprocess.run([str(executable), mode], env=current, check=True, timeout=10)
        if mode == 'disabled':
            assert before == set(directory.iterdir()), 'quiet run created files'
            print('PASS disabled: no diagnostic files')
            continue
        summary = {row['stream']: row for row in rows(Path(str(prefix) + '-summary-42.csv'))}
        shader = fifo_result if mode == 'blocked' else rows(Path(str(prefix) + '-42.csv'))
        pipeline = rows(Path(str(prefix) + '-pipelines-42.csv'))
        for name, records in [('shader', shader), ('pipeline', pipeline)]:
            item = summary[name]
            assert int(item['records']) == len(records), item
            assert int(item['pending']) == 0, item
            assert int(item['flush_errors']) == 0, item
            assert int(item['records']) + int(item['dropped']) == int(item['submitted']), item
            assert int(item['final']) == (mode != 'abrupt'), item
        if mode == 'abrupt':
            assert len(shader) == 2 and len(pipeline) == 3
            wait = next(row for row in pipeline if row['phase'] == 'wait')
            assert int(wait['ready_published_monotonic_us']) > 0
            assert int(wait['wait_return_monotonic_us']) - int(wait['ready_published_monotonic_us']) == int(wait['ready_to_return_us'])
            assert int(wait['ready_to_return_us']) > 1000
        elif mode == 'atexit':
            assert len(shader) == len(pipeline) == 1
        elif mode == 'concurrent':
            assert all(int(item['submitted']) == 16000 for item in summary.values())
            assert all(int(item['dropped_limit']) == 0 for item in summary.values())
        else:
            assert len(shader) + len(pipeline) <= 2048
            assert all(int(item['submitted']) == 100005 for item in summary.values())
            assert all(int(item['dropped_limit']) == 5 for item in summary.values())
            assert all(int(item['dropped_queue']) > 90000 for item in summary.values())
        print(f'PASS {mode}: exact persisted/drop accounting, bounded storage and safe lifetime')
