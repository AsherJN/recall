#!/usr/bin/env python3
"""Select the private v1 fullscreen resolution in the local source prefix.

This sets game preferences only. It neither controls a game window nor establishes
actual render size; opt-in window/geometry traces verify what the game requests.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import shutil
import tempfile

from launch_cx26 import ROOT, running_experiment_servers
from candidate_contract import launch_preferences

SETTINGS = ROOT / "runtime/prefix-dxmt-local/drive_c/users/Sikarugir/Documents/Overwatch/Settings/Settings_v0.ini"
REQUEST = launch_preferences(1080)


def update_preferences(text, height=1080, frame_cap=None):
    """frame_cap: None leaves the game's own FrameRateCap untouched; an int (30..600) sets it
    with UseCustomFrameRates on. 600 is the game's highest supported limit."""
    if height not in (1080,1200):raise ValueError('Choose 1080 or 1200')
    request = REQUEST | dict(WindowedHeight=str(height),FullScreenHeight=str(height))
    if frame_cap is not None:
        if not 30 <= int(frame_cap) <= 600: raise ValueError('Frame cap must be between 30 and 600')
        request = request | dict(FrameRateCap=str(int(frame_cap)), UseCustomFrameRates="1")
    lines = text.splitlines(keepends=True)
    starts = [i for i, line in enumerate(lines) if line.strip() == "[Render.13]"]
    if len(starts) != 1:
        raise ValueError("Expected one existing Render.13 settings section.")
    start = starts[0] + 1
    end = next((i for i in range(start, len(lines)) if lines[i].lstrip().startswith("[")), len(lines))
    newline = "\r\n" if "\r\n" in text else "\n"
    before = {}
    additions = []
    for key, value in request.items():
        matches = [i for i in range(start, end)
                   if re.match(r"^\s*" + re.escape(key) + r"\s*=", lines[i])]
        if len(matches) > 1:
            raise ValueError(f"Duplicate setting {key}; refusing an ambiguous edit.")
        if matches:
            index = matches[0]
            old = lines[index].split("=", 1)[1].strip().strip('"')
            before[key] = old
            if old != value:
                lines[index] = f'{key} = "{value}"{newline}'
        else:
            before[key] = None
            additions.append(f'{key} = "{value}"{newline}')
    if additions:
        if end > 0 and not lines[end - 1].endswith(("\n", "\r")):
            lines[end - 1] += newline
        lines[end:end] = additions
    changes = {key: dict(before=before[key], after=value)
               for key, value in request.items() if before[key] != value}
    return "".join(lines), changes


def current_frame_cap(text):
    """The FrameRateCap value in the Render section, or None."""
    match = re.search(r'^\s*FrameRateCap\s*=\s*"?(\d+)"?', text, re.MULTILINE)
    return int(match.group(1)) if match else None


def apply_preferences(settings, backup_folder, height, frame_cap=None):
    """Caller must close this prefix first; write atomically with a recoverable original."""
    with settings.open(newline='') as stream:before=stream.read()
    after,changes=update_preferences(before,height,frame_cap)
    if not changes:return dict(changes={},requested_client=[1920,height],frame_rate_cap=current_frame_cap(before))
    backup_folder.mkdir(parents=True,exist_ok=True)
    stamp=datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    backup=backup_folder/f'settings-before-v1-{stamp}.ini'
    shutil.copy2(settings,backup)
    temp=settings.with_name('.v1-resolution-'+stamp)
    try:
        with temp.open('x',newline='') as stream:stream.write(after)
        shutil.copymode(settings,temp)
        os.replace(temp,settings)
    finally:temp.unlink(missing_ok=True)
    return dict(changes=changes,requested_client=[1920,height],backup=str(backup),frame_rate_cap=current_frame_cap(after))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true",
                        help="Back up and write the preferences; refuses while experiment Wine is running.")
    args = parser.parse_args()
    if not SETTINGS.is_file():
        raise SystemExit("The local source-build Overwatch settings file is missing.")
    if not SETTINGS.resolve().is_relative_to(ROOT / "runtime/prefix-dxmt-local"):
        raise SystemExit("The source settings path resolves outside the experiment prefix.")
    with SETTINGS.open(newline="") as stream:
        before = stream.read()
    try:
        after, changes = update_preferences(before)
    except ValueError as error:
        raise SystemExit(str(error)) from error
    print(json.dumps(dict(mode="fullscreen", requested_client=[1920, 1080],
                          render_resolution_verified=False, changes=changes), indent=2))
    if not args.apply:
        print("Preview only. --apply requires experiment Wine clients to be closed.")
        return
    if running_experiment_servers():
        raise SystemExit("Close the experiment's Wine clients before applying saved game preferences.")
    if not changes:
        print("These display preferences are already set; no file was changed.")
        return
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    folder = ROOT / "logs/dxmt"
    folder.mkdir(parents=True, exist_ok=True)
    backup = folder / f"settings-before-windowed1080-{stamp}.ini"
    shutil.copy2(SETTINGS, backup)
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", newline="",
                                         dir=SETTINGS.parent, prefix=".windowed1080-", delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(after)
        shutil.copymode(SETTINGS, temporary)
        os.replace(temporary, SETTINGS)
        temporary = None
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)
    manifest = dict(settings=str(SETTINGS.relative_to(ROOT)), backup=str(backup.relative_to(ROOT)),
                    requested_client=[1920, 1080], render_resolution_verified=False, changes=changes)
    (folder / f"windowed1080-{stamp}.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"Saved normal-display preferences; backup: {backup}")


if __name__ == "__main__":
    main()
