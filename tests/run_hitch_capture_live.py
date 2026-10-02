#!/usr/bin/env python3
"""Validate the production bounded sampler against an owned idle native process."""
import datetime
import json
from pathlib import Path
import subprocess
import sys
import time
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
from hitch_capture import HitchCapture
from process_probe import NativeProbe
folder=ROOT/'logs/dxmt'/('hitch-capture-proof-'+datetime.datetime.now().strftime('%Y%m%d-%H%M%S'))
folder.mkdir()
child=subprocess.Popen([str(ROOT/'runtime/build/v1-stack-proof/probe')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
capture=None
try:
    probe=NativeProbe();identity=probe.sample(child.pid)
    capture=HitchCapture(folder,probe)
    capture.pending.put(dict(pid=child.pid,start_abstime=identity['start_abstime'],number=1,
        reason='owned_fixture_worker_validation',trigger_unix_us=time.time_ns()//1000,
        trigger_monotonic_ns=time.monotonic_ns()))
    deadline=time.monotonic()+48
    while not capture.completed and not capture.failed and time.monotonic()<deadline:time.sleep(.05)
    capture.close()
    assert capture.completed==1,capture.status()
    report=json.loads(next((folder/'hitch-stacks').glob('01-*.json')).read_text())
    text=next((folder/'hitch-stacks').glob('01-*.txt')).read_text()
    assert 'v1_test_wait' in text
    assert not list((folder/'hitch-stacks').glob('*.raw'))
    report.update(stack_bytes=len(text.encode()),expected_function_found=True,
                  translated_stack_proof=str(ROOT/'logs/dxmt/v1-wine-fixture-stack.txt'))
    (folder/'report.json').write_text(json.dumps(report,indent=2)+'\n')
    print(folder,flush=True)
finally:
    if capture:capture.close()
    child.terminate();child.wait(timeout=5)
