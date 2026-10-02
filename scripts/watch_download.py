#!/usr/bin/env python3
"""Bounded disk monitor for this experiment's Battle.net download."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
import signal
import subprocess
import time
import os

ROOT = Path(__file__).resolve().parent.parent
GAME = ROOT / 'Overwatch Experiment.app/Contents/SharedSupport/prefix/drive_c/Program Files (x86)/Overwatch'


def process_info(pid):
    return subprocess.run(
        ['ps', '-p', str(pid), '-o', 'lstart=', '-o', 'comm='],
        capture_output=True, text=True, check=False,
    ).stdout.strip()


def belongs_to_experiment(pid):
    output = subprocess.run(
        ['lsof', '-a', '-p', str(pid), '-d', 'txt', '-Fn'],
        capture_output=True, text=True, check=False,
    ).stdout
    engine = str(ROOT / 'Overwatch Experiment.app/Contents/SharedSupport/wine/')
    return any(line.startswith('n' + engine) for line in output.splitlines())


def snapshot():
    allocated = 0
    for p in GAME.rglob('*'):
        try:
            if p.is_file():
                allocated += p.stat().st_blocks * 512
        except FileNotFoundError:
            pass  # The updater may rename a file while it is being measured.
    return {
        'time': datetime.now().astimezone().isoformat(timespec='seconds'),
        'free_gib': round(shutil.disk_usage(ROOT).free / 1024**3, 2),
        'game_allocated_gib': round(allocated / 1024**3, 2),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--agent-pid', type=int)
    parser.add_argument('--once', action='store_true')
    args = parser.parse_args()
    identity = process_info(args.agent_pid) if args.agent_pid else ''
    if not args.once and not (
        args.agent_pid and identity.endswith('/Agent.exe')
        and belongs_to_experiment(args.agent_pid)
    ):
        raise SystemExit('Refusing to monitor an unverified downloader process.')
    deadline = time.monotonic() + 6 * 3600
    while time.monotonic() < deadline:
        report = snapshot()
        if not args.once and process_info(args.agent_pid) != identity:
            report['event'] = 'downloader_exited_or_changed; monitor stopped'
            print(json.dumps(report), flush=True)
            return
        if not args.once and report['free_gib'] < 5:
            # Suspend only the verified updater, never the game or other apps.
            if belongs_to_experiment(args.agent_pid) and process_info(args.agent_pid) == identity:
                os.kill(args.agent_pid, signal.SIGSTOP)
                report['event'] = 'paused_downloader_below_5_GiB_free'
                report['paused_pid'] = args.agent_pid
                (ROOT / 'logs/download-paused.json').write_text(json.dumps(report, indent=2) + '\n')
            print(json.dumps(report), flush=True)
            return
        print(json.dumps(report), flush=True)
        if args.once:
            return
        time.sleep(30)
    print(json.dumps({'event': 'six_hour_monitor_limit_reached'}), flush=True)


if __name__ == '__main__':
    main()
