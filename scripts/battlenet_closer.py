#!/usr/bin/env python3
"""Exit the Battle.net client after Overwatch is running, freeing its CPU and memory.

Measured on 2026-09-12: the idle client and its helper processes used about
1.4 GB of memory and roughly 1.5 CPU cores behind the game on this 16 GB Mac.

Scope: only Battle.net client processes that belong to this experiment's exact
Wine engine and Windows prefix (verified through their mapped executables, the
same check the resource collector uses). The prefix is one of this experiment's,
or the installed app's environment when the mouselook play-test runs a test
engine against it. Overwatch, the update Agent, the Wine
server and any other prefix's client are never signalled. Only process ids,
start times and executable names are read; never command lines or environment.
Wine re-spawns the client after launch, so a parent-pid tree is not reliable.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
INSTALLED_PREFIX = Path.home() / "Library/Application Support/Overwatch2Mac/environment"
CLIENT_SUFFIX = "\\Battle.net.exe"
GAME_SUFFIX = "Overwatch.exe"


def command(*args):
    env = dict(os.environ, LC_ALL="C", TZ="UTC")
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL, timeout=5, env=env)


def process_table(output=None):
    """Return {pid: (start_token, comm)} for client and game candidates only."""
    if output is None:
        output = command("ps", "-axo", "pid=,lstart=,comm=")
    table = {}
    for line in output.splitlines():
        parts = line.strip().split(None, 6)
        if len(parts) != 7:
            continue
        comm = parts[6]
        if not (comm.endswith(CLIENT_SUFFIX) or comm.endswith(GAME_SUFFIX)):
            continue
        try:
            table[int(parts[0])] = (" ".join(parts[1:6]), comm)
        except ValueError:
            continue
    return table


def mapped_files(pid):
    try:
        return command("lsof", "-a", "-p", str(pid), "-d", "txt", "-Fn")
    except (subprocess.SubprocessError, OSError):
        return None


class Session:
    """Membership of candidate processes in one engine/prefix, cached per identity."""

    def __init__(self, engine, prefix, mapped_fn=mapped_files):
        self.engine = str(Path(engine).resolve()) + "/"
        self.prefix = str(Path(prefix).resolve()) + "/"
        self.mapped_fn = mapped_fn
        self.cache = {}

    def member(self, pid, start_token):
        key = (pid, start_token)
        if key not in self.cache:
            mapped = self.mapped_fn(pid)
            self.cache[key] = None if mapped is None else (self.engine in mapped and self.prefix in mapped)
        return self.cache[key]

    def classify(self, table):
        clients, games, unknown = [], [], 0
        for pid, (start_token, comm) in sorted(table.items()):
            member = self.member(pid, start_token)
            if member is None:
                unknown += 1
            elif member and comm.endswith(CLIENT_SUFFIX):
                clients.append(pid)
            elif member and comm.endswith(GAME_SUFFIX):
                games.append(pid)
        return clients, games, unknown


def plan(clients, games, game_seen_at, client_seen_at, now, grace_seconds, client_timeout=120.0):
    """Return ('wait'|'close'|'give_up', reason, game_seen_at, client_seen_at)."""
    if clients:
        client_seen_at = now
    elif client_seen_at is not None and now - client_seen_at > client_timeout and not games:
        return "give_up", "client_exited_before_game", game_seen_at, client_seen_at
    if not games:
        return "wait", "no_game_yet", None, client_seen_at
    if game_seen_at is None:
        game_seen_at = now
    if now - game_seen_at < grace_seconds:
        return "wait", "grace_period", game_seen_at, client_seen_at
    if not clients:
        return "give_up", "no_client_left", game_seen_at, client_seen_at
    return "close", "game_running", game_seen_at, client_seen_at


def close_clients(clients, kill=os.kill):
    signalled = []
    for pid in clients:
        try:
            kill(pid, signal.SIGTERM)
            signalled.append(pid)
        except (ProcessLookupError, PermissionError):
            continue
    return signalled


def run(session, *, grace_seconds=25.0, timeout_seconds=1800.0, poll_seconds=2.0,
        table_fn=process_table, kill=os.kill, monotonic=time.monotonic, sleep=time.sleep,
        log=None, dry_run=False):
    started = monotonic()
    game_seen_at = client_seen_at = None
    record = dict(engine=session.engine, prefix=session.prefix, grace_seconds=grace_seconds,
                  status="waiting", polls=0, dry_run=dry_run,
                  started=datetime.datetime.now(datetime.timezone.utc).isoformat())
    while monotonic() - started < timeout_seconds:
        record["polls"] += 1
        try:
            clients, games, unknown = session.classify(table_fn())
        except (subprocess.SubprocessError, OSError):
            sleep(poll_seconds)
            continue
        action, reason, game_seen_at, client_seen_at = plan(
            clients, games, game_seen_at, client_seen_at, monotonic(), grace_seconds)
        record.update(last_clients=clients, last_games=games, unknown_membership=unknown, last_action=reason)
        if dry_run:
            record["status"] = f"dry_run_{action}"
            break
        if action == "give_up":
            record["status"] = reason
            break
        if action == "close":
            live_clients, live_games, _ = session.classify(table_fn())
            if not live_games:
                record["status"] = "game_exited_before_close"
                break
            signalled = close_clients(live_clients, kill)
            sleep(3)
            remaining = [pid for pid in session.classify(table_fn())[0] if pid in signalled]
            record.update(status="closed", signalled=signalled, remaining_after_3s=remaining, games=live_games,
                          closed=datetime.datetime.now(datetime.timezone.utc).isoformat())
            break
        sleep(poll_seconds)
    else:
        record["status"] = "timeout_without_game"
    if log:
        log.parent.mkdir(parents=True, exist_ok=True)
        log.write_text(json.dumps(record, indent=2) + "\n")
    return record


def accepts(engine, prefix):
    """Only this experiment's engines, with its own prefixes or the installed app's environment."""
    runtime, prefix = ROOT / "runtime", prefix.resolve()
    return engine.resolve().is_relative_to(runtime) and (
        prefix.is_relative_to(runtime) or prefix == INSTALLED_PREFIX.resolve())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, required=True, help="Wine engine directory of this launch.")
    parser.add_argument("--prefix", type=Path, required=True, help="Windows prefix directory of this launch.")
    parser.add_argument("--grace-seconds", type=float, default=25.0,
                        help="Delay after Overwatch first appears before the client is closed.")
    parser.add_argument("--timeout-seconds", type=float, default=1800.0)
    parser.add_argument("--log", type=Path)
    parser.add_argument("--dry-run", action="store_true", help="Classify once and report the plan without signalling.")
    args = parser.parse_args()
    if not accepts(args.engine, args.prefix):
        raise SystemExit("The engine must be this experiment's, and the prefix this experiment's or the installed app's.")
    session = Session(args.engine, args.prefix)
    record = run(session, grace_seconds=args.grace_seconds, timeout_seconds=args.timeout_seconds,
                 log=args.log, dry_run=args.dry_run)
    print(json.dumps(record))
    return 0


if __name__ == "__main__":
    sys.exit(main())
