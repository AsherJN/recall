#!/usr/bin/env python3
"""REC-15: audio devices that come and go while a program runs, against a real engine.

Runs audio_probe.c (a program that plays silence the way a game does) under the engine's
Wine in a new scratch Windows environment, while audio_switch.c moves the Mac's default
output between real devices, adds and removes a device (a public aggregate device of a
second output, or of the Mac's speakers or microphone, named org.recall.test.audio-devices.*)
and moves the default microphone. Checks, from the probe's own reports and from Core Audio's list of the devices
the probe's process plays to:
  switch      the default output moves to another device and back: the probe is told and
              its sound follows
  connect     a device arrives and becomes the default, then is removed: the probe is told
              both times and plays on the new device, then on the Mac's again
  stubborn    a program that ignores default changes playing on a device that is removed
              gets AUDCLNT_E_DEVICE_INVALIDATED, as on Windows, and reopens on the default
  microphone  a new default microphone reaches the program as a default capture change
  bluetooth   while the default microphone is a Bluetooth headset's (simulated with
              WINECOREAUDIO_TEST_BLUETOOTH_UID) and the lid is open, Wine's default
              microphone stays the Mac's own
With --control ENGINE, the connect case also runs on an engine without the change, to show
the old behaviour (no notice; the probe keeps playing on the Mac's speakers).

Plays silence only and never opens a microphone. Switches the Mac's default output and input
for a few seconds at a time and restores both at the end. Needs Rosetta, a Mac with
built-in speakers and microphone, and Wine outside the command sandbox; no game, account or
Battle.net. Wine's server for the scratch root is stopped at exit.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
PREFIX = 'org.recall.test.audio-devices.'
SPEAKERS, MICROPHONE = 'BuiltInSpeakerDevice', 'BuiltInMicrophoneDevice'


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('--engine', type=Path, required=True, help='an extracted runtime with the change')
    p.add_argument('--control', type=Path, help='an extracted runtime without it')
    p.add_argument('--root', type=Path, required=True, help='new scratch folder outside the checkout')
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--other-output', help='UID of a second real output device (default: the first one found)')
    a = p.parse_args()
    root, out = a.root.resolve(), a.output.resolve()
    if root.is_relative_to(ROOT) or root.exists():
        p.error('Use a new scratch root outside the checkout; an existing one is never adopted')
    root.mkdir(parents=True)
    out.mkdir(parents=True, exist_ok=True)
    probe, switch = out / 'audio-probe.exe', out / 'audio-switch'
    here = Path(__file__).parent
    subprocess.run(['clang', '-O2', '-Wall', '-Wextra', '-Werror', str(here / 'audio_switch.c'), '-o', str(switch),
                    '-framework', 'CoreAudio', '-framework', 'CoreFoundation'], check=True)
    compiler = ROOT / 'runtime/toolchains/llvm-mingw-20251216-ucrt-macos-universal/bin/x86_64-w64-mingw32-gcc'
    subprocess.run([str(compiler), '-O2', '-g0', '-Wall', '-Wextra', '-Wno-unused-parameter', '-Werror',
                    str(here / 'audio_probe.c'), '-o', str(probe), '-lole32', '-luuid'], check=True)

    def mac(*args):
        r = subprocess.run([str(switch), *args], capture_output=True, text=True, timeout=30)
        return [json.loads(line) for line in r.stdout.splitlines() if line.startswith('{')]

    devices = mac('list')
    uids = {d['uid'] for d in devices}
    if SPEAKERS not in uids or MICROPHONE not in uids:
        p.error('Needs the Mac\'s built-in speakers and microphone')
    other = a.other_output or next((d['uid'] for d in devices if d['out'] and d['uid'] != SPEAKERS
                                    and d['transport'] not in ('grup', 'virt')), None)
    defaults = mac('defaults')[0]
    contract = json.loads((ROOT / 'docs/candidate-parity-contract.json').read_text())['environment']
    results, checks = {}, {}

    def environment(engine, extra=None):
        env = dict(contract, PATH='/usr/bin:/bin:/usr/sbin:/sbin', HOME=str(root / 'home'), USER='player',
                   TMPDIR=str(root / 'tmp'), WINEPREFIX=str(root / 'environment'), WINEARCH='win64',
                   WINESERVER=str(engine / 'bin/wineserver'), WINELOADER=str(engine / 'bin/wine'), WINEDEBUG='-all',
                   CX_APPLEGPTK_LIBD3DSHARED_PATH=str(engine / 'lib/external/libd3dshared.dylib'))
        env.update(extra or {})
        return env

    def case(name, engine, mode, seconds, steps, extra=None):
        """Runs the probe for SECONDS while STEPS ([(at, label, function)]) run; returns its lines."""
        env = environment(engine, extra)
        subprocess.run([str(engine / 'bin/wineserver'), '-w'], env=env, timeout=60)
        log = (out / f'{name}.jsonl').open('w')
        start = time.monotonic()
        proc = subprocess.Popen([str(engine / 'bin/wine'), str(probe), mode, str(seconds)], env=env, cwd=root,
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        lines = []

        def reader():
            for line in proc.stdout:
                if line.startswith('{'):
                    item = json.loads(line)
                    item['at'] = round(time.monotonic() - start, 2)
                    lines.append(item)
                    log.write(json.dumps(item) + '\n')
                    log.flush()
        thread = threading.Thread(target=reader)
        thread.start()
        # Wine starts a process in a few seconds under Rosetta: time steps from its first line.
        while not lines and time.monotonic() - start < 60:
            time.sleep(0.1)
        ready = time.monotonic()
        for at, label, function in steps:
            time.sleep(max(0, ready + at - time.monotonic()))
            # Checks (labels starting "who") don't end a step's window.
            kind = 'check' if label.startswith('who') else 'step'
            record = {'at': round(time.monotonic() - start, 2), kind: label, 'result': function()}
            lines.append(record)
            log.write(json.dumps(record) + '\n')
            log.flush()
        proc.wait(timeout=seconds + 120)
        thread.join()
        log.close()
        results[name] = lines
        return lines

    def who():
        pids = subprocess.run(['pgrep', '-f', 'audio-probe.exe'], capture_output=True, text=True).stdout.split()
        found = []
        for pid in pids:
            found.extend(row for row in mac('who', pid) if row['output'])
        return found

    def playing_after(lines, label):
        """The probe's reports from the step labelled LABEL until the next step."""
        index = next(i for i, line in enumerate(lines) if line.get('step') == label)
        following = []
        for line in lines[index + 1:]:
            if 'step' in line:
                break
            following.append(line)
        return following

    def name_of(uid):
        return next((d['name'] for d in mac('list') if d['uid'] == uid), uid)

    def played_on(lines, label, uid, physical=None, name=None):
        """After the step, the probe reopened on UID's device (NAME, for one removed since), which took
        sound, and Core Audio agrees: its list names the real device under an aggregate (PHYSICAL)."""
        after = playing_after(lines, label)
        opened = [l for l in after if l.get('event') == 'playing']
        took = [l for l in after if l.get('event') == 'report' and l['taken'] > 0]
        seen = [row for l in after if 'check' in l for row in l['result']]
        return (bool(opened) and opened[-1]['name'] == (name or name_of(uid)) and bool(took)
                and bool(seen) and all((physical or uid) in row['output'] for row in seen))

    try:
        mac('cleanup', PREFIX)
        engine, extra_device = a.engine.resolve(), PREFIX + 'output'
        # The added device plays through the second output when there is one, so Core Audio's
        # list of the devices the probe plays to tells it apart from the Mac's speakers.
        under = other or SPEAKERS
        env = environment(engine)
        subprocess.run([str(engine / 'bin/wine'), 'wineboot', '-i'], env=env, cwd=root, timeout=600,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        mac('set-default', 'output', SPEAKERS)
        mac('set-default', 'input', MICROPHONE)

        def step(label, *args):
            return (label, lambda: mac(*args))

        def check(label):
            return (label, who)

        # switch: between two real outputs and back.
        if other:
            lines = case('switch', engine, 'follow', 14, [
                (2, *step('to other', 'set-default', 'output', other)),
                (5, *check('who other')),
                (7, *step('to speakers', 'set-default', 'output', SPEAKERS)),
                (10, *check('who speakers')),
            ])
            told = [l for l in lines if l.get('event') == 'default' and l['flow'] == 'render' and l['role'] == 0]
            checks['switch: told twice (eConsole), other output then speakers'] = (
                [l['name'] for l in told] == [name_of(other), name_of(SPEAKERS)])
            checks['switch: sound follows to the other output'] = played_on(lines, 'to other', other)
            checks['switch: and back to the speakers'] = played_on(lines, 'to speakers', SPEAKERS)

        # connect: a new device arrives, becomes the default, then is removed.
        def connect_steps():
            return [
                (2, *step('connect', 'create', extra_device, 'Recall Test Headphones', under)),
                (3, *step('select', 'set-default', 'output', extra_device)),
                (6, *check('who new')),
                (8, *step('remove', 'destroy', extra_device)),
                (11, *check('who speakers')),
            ]
        lines = case('connect', engine, 'follow', 15, connect_steps())
        events = [(l['event'], l.get('name'), l.get('state')) for l in lines if l.get('event') in ('added', 'state')]
        checks['connect: told a device was added and is active'] = (
            ('added', 'Recall Test Headphones', None) in events and ('state', 'Recall Test Headphones', 1) in events)
        checks['connect: sound moves to the new device'] = played_on(lines, 'select', extra_device, under, 'Recall Test Headphones')
        checks['connect: told it was removed (not present)'] = ('state', 'Recall Test Headphones', 4) in events
        checks['connect: sound returns to the speakers'] = played_on(lines, 'remove', SPEAKERS)
        checks['connect: no failed reopen after the removal'] = not any(
            l.get('event') == 'open_failed' for l in playing_after(lines, 'remove'))

        # stubborn: playing on a device that is removed, ignoring default changes.
        mac('create', extra_device, 'Recall Test Headphones', under)
        mac('set-default', 'output', extra_device)
        lines = case('stubborn', engine, 'stubborn', 10, [
            (3, *step('remove', 'destroy', extra_device)),
            (7, *check('who speakers')),
        ])
        first = next((l for l in lines if l.get('event') == 'playing'), {})
        checks['stubborn: started on the added device'] = first.get('name') == 'Recall Test Headphones'
        checks['stubborn: AUDCLNT_E_DEVICE_INVALIDATED after removal'] = any(
            l.get('event') == 'invalidated' for l in playing_after(lines, 'remove'))
        checks['stubborn: reopening at once works (Wine already lists the new default)'] = not any(
            l.get('event') == 'open_failed' for l in playing_after(lines, 'remove'))
        checks['stubborn: reopens on the speakers'] = played_on(lines, 'remove', SPEAKERS)
        mac('set-default', 'output', SPEAKERS)

        # microphone: a new default microphone is announced (never opened).
        mic = PREFIX + 'input'
        lines = case('microphone', engine, 'follow', 10, [
            (2, *step('connect', 'create', mic, 'Recall Test Headset', MICROPHONE)),
            (3, *step('select', 'set-default', 'input', mic)),
            (6, *step('back', 'set-default', 'input', MICROPHONE)),
        ])
        told = [l['name'] for l in lines if l.get('event') == 'default' and l['flow'] == 'capture' and l['role'] == 2]
        checks['microphone: told of the new default microphone and back'] = told == ['Recall Test Headset', name_of(MICROPHONE)]

        # bluetooth: the same with the new microphone counted as a Bluetooth headset's.
        lines = case('bluetooth', engine, 'follow', 8, [
            (3, *step('select', 'set-default', 'input', mic)),
        ], extra={'WINECOREAUDIO_TEST_BLUETOOTH_UID': mic})
        told = [l for l in lines if l.get('event') == 'default' and l['flow'] == 'capture']
        start_mic = next((l['name'] for l in lines if l.get('event') == 'start_default'), None)
        checks['bluetooth: the Mac\'s microphone stays the default (lid open)'] = (
            not told and start_mic == name_of(MICROPHONE))
        mac('set-default', 'input', MICROPHONE)
        mac('destroy', mic)

        if a.control:
            control = a.control.resolve()
            subprocess.run([str(engine / 'bin/wineserver'), '-k'], env=env, timeout=60)
            lines = case('control-connect', control, 'follow', 15, connect_steps())
            told = [l for l in lines if l.get('event') in ('default', 'added', 'state')]
            after = [l for l in playing_after(lines, 'select') if l.get('event') == 'playing']
            checks['control: the engine without the change says nothing'] = not told
            seen = [row for l in playing_after(lines, 'select') if 'check' in l for row in l['result']]
            checks['control: and keeps playing on the speakers'] = (
                not after and bool(seen) and all(SPEAKERS in row['output'] for row in seen))
    finally:
        mac('cleanup', PREFIX)
        mac('set-default', 'output', defaults['output'])
        mac('set-default', 'input', defaults['input'])
        for engine in filter(None, (a.engine, a.control)):
            subprocess.run([str(engine.resolve() / 'bin/wineserver'), '-k'], env=environment(engine.resolve()),
                           timeout=60, capture_output=True)
        (out / 'checks.json').write_text(json.dumps(checks, indent=2) + '\n')

    for name, ok in checks.items():
        print(('PASS ' if ok else 'FAIL ') + name)
    return 0 if checks and all(checks.values()) else 1


if __name__ == '__main__':
    raise SystemExit(main())
