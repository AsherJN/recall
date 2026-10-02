"""Controlled child workload; validates counters without launching the game."""
import csv
import json
from pathlib import Path
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from process_probe import NativeProbe, ProcessRecorder, digest, SOURCE, BUILD
from analyze_process_stalls import process_bins

out = ROOT / 'logs/dxmt/stall-investigation-20260912'
child_code = '''
import sys,time,json
print('ready',flush=True)
sys.stdin.read(1)
began=time.process_time()
time.sleep(.5)
memory=bytearray(32*1024*1024)
for index in range(0,len(memory),4096):memory[index]=7
for repeat in range(3):
 end=time.monotonic()+.45
 while time.monotonic()<end:pass
 time.sleep(.45)
print(json.dumps(dict(cpu_seconds=time.process_time()-began)),flush=True)
sys.stdin.read(1)
'''
probe = NativeProbe()
path = out / ('live-probe-' + time.strftime('%H%M%S') + '.csv')
child = subprocess.Popen([sys.executable, '-c', child_code], stdin=subprocess.PIPE,
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
recorder = None
try:
    assert child.stdout.readline().strip() == 'ready'
    baseline = probe.sample(child.pid)
    recorder = ProcessRecorder(path, probe)
    recorder.set_targets([dict(pid=child.pid, native_start_abstime=baseline['start_abstime'])])
    cpu, wall = time.process_time(), time.monotonic()
    recorder.start()
    child.stdin.write('x'); child.stdin.flush()
    expected = json.loads(child.stdout.readline())
    time.sleep(.2)
    end = probe.sample(child.pid, baseline['start_abstime'])
    recorder.close()
    own_cpu, wall = time.process_time() - cpu, time.monotonic() - wall
    child.stdin.write('x'); child.stdin.flush()
    child.wait(timeout=3)
    assert child.returncode == 0
    try:
        probe.sample(child.pid, baseline['start_abstime'])
        raise AssertionError('Exited process was accepted')
    except OSError:
        pass
    with path.open() as stream:
        rows = list(csv.DictReader(stream))
    bins, rejected = process_bins(rows, child.pid)
    cpu_seconds = (end['user_ns'] + end['system_ns'] - baseline['user_ns'] - baseline['system_ns']) / 1e9
    result = dict(path=str(path), status=recorder.status(), expected_child=expected,
                  measured_child_cpu_seconds=cpu_seconds, measurement_wall_seconds=wall,
                  observer_cpu_percent_one_core=own_cpu / wall * 100,
                  valid_bins=len(bins), rejected_bins=rejected,
                  faults_delta=end['faults_u32'] - baseline['faults_u32'],
                  footprint_increase_mib=(end['footprint_bytes']-baseline['footprint_bytes']) / 2**20,
                  native_query_us=dict(median=statistics.median(int(r['query_duration_ns']) / 1e3 for r in rows),
                                       maximum=max(int(r['query_duration_ns']) / 1e3 for r in rows)),
                  busiest_bin_cpu_percent=max(b['game_cpu_percent'] for b in bins),
                  idle_bins=sum(b['game_cpu_percent'] < 5 for b in bins),
                  source_sha256=digest(SOURCE), library_sha256=digest(BUILD / 'libprocess_probe.dylib'))
    assert abs(cpu_seconds - expected['cpu_seconds']) < .025, result
    assert result['faults_delta'] > 1000, result
    assert result['footprint_increase_mib'] > 20, result
    assert result['observer_cpu_percent_one_core'] < 2, result
    assert result['busiest_bin_cpu_percent'] > 75 and result['idle_bins'] > 5, result
    assert len(rows) >= 25 and not rejected and recorder.errors == 0, result
    (out / 'live-probe-validation.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
finally:
    if recorder:
        recorder.close()
    if child.poll() is None:
        child.terminate()
        child.wait(timeout=3)
