#!/usr/bin/env python3
"""Read-only experiment status; avoids account data and authentication logs."""
from pathlib import Path
import json
import shutil
import subprocess

root = Path(__file__).resolve().parent.parent
app = root / "Overwatch Experiment.app"
support = app / "Contents/SharedSupport"
drive = support / "prefix/drive_c"
version = support / "wine/version"
report = {
    "macos": subprocess.check_output(["sw_vers", "-productVersion"], text=True).strip(),
    "free_gib": round(shutil.disk_usage(root).free / 1024**3, 1),
    "wine": version.read_text().strip() if version.exists() else "not installed",
    "battlenet_launcher_installed": (drive / "Program Files (x86)/Battle.net/Battle.net Launcher.exe").is_file(),
    "overwatch_executables": [str(p.relative_to(root)) for p in drive.glob("Program Files*/Overwatch/**/Overwatch.exe")],
    "gameplay_verified": False,
}
print(json.dumps(report, indent=2))
