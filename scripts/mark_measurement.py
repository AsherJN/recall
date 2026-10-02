#!/usr/bin/env python3
"""Add an explicit phase timestamp to a measured run without touching the game."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import subprocess

import measure_resources as resources

ROOT = Path(__file__).resolve().parent.parent
EVENTS = ("practice_entered", "workshop_entered", "quickplay_entered", "match_ended",
          "menu_entered", "game_closed")
MARKER_MAX_BYTES = 256 * 1024


def discover_artifacts(folder):
    """List current/rotated streams and summaries; never parse bulky logs here."""
    prefixes = ("resources", "frames-", "display-", "shaders-", "pipeline-cache-",
                "geometry-", "windows-", "session-")
    return sorted(path.name for path in Path(folder).iterdir()
                  if path.is_file() and path.name.startswith(prefixes)
                  and path.suffix in (".csv", ".json", ".jsonl"))


def selected_session(explicit=None):
    if explicit is None:
        active = json.loads((ROOT / "logs/dxmt/active-measurement.json").read_text())
        folder = Path(active["resources"]).parent
    else:
        folder = Path(explicit)
    folder = folder.resolve()
    if not folder.is_relative_to((ROOT / "logs/dxmt").resolve()):
        raise ValueError("The session must be inside this experiment's measured logs")
    status = json.loads((folder / "session-status.json").read_text())
    if explicit is None:
        if not active.get("startup_confirmed") or status.get("status") not in ("starting", "running"):
            raise ValueError("The active resource collector is not running")
        if not status.get("collector_identity") or not resources.session_alive(status["collector_identity"]):
            raise ValueError("The active collector identity is stale")
        if status.get("session") != active.get("session") or not resources.session_alive(status["session"]):
            raise ValueError("The active Wine session identity is stale")
    return folder, status


def add_marker(folder, status, event):
    if event not in EVENTS:
        raise ValueError("Unknown phase marker")
    record = dict(**resources.timestamp(), schema_version=1, event=event,
                  source="explicit_user_marker", session=status["session"],
                  last_observed_games=status.get("games", []),
                  resource_status_time=status.get("time"))
    data = (json.dumps(record, separators=(",", ":")) + "\n").encode()
    fd = os.open(Path(folder) / "session-markers.jsonl",
                 os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if os.fstat(fd).st_size + len(data) > MARKER_MAX_BYTES:
            raise ValueError("Phase marker file reached its 256 KiB limit")
        while data:
            written = os.write(fd, data)
            if not written:
                raise OSError("Incomplete marker write")
            data = data[written:]
    finally:
        os.close(fd)
    return record


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("event", choices=EVENTS)
    parser.add_argument("--session", type=Path,
                        help="Explicit measured folder, including a finished run; default validates the active bottle.")
    args = parser.parse_args()
    try:
        folder, status = selected_session(args.session)
        record = add_marker(folder, status, args.event)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        raise SystemExit(f"Marker was not saved ({type(exc).__name__}). Use --session for a finished run.")
    print(f"{record['event']}: {record['time']} — {folder}")


if __name__ == "__main__":
    main()
