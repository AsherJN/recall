#!/usr/bin/env python3
"""Stage a completed local build in new APFS-cloned engine and prefix directories."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile

from launch_cx26 import ROOT, stop_clients

INSTALL = ROOT / "runtime/build/dxmt-local/install"
BASE_ENGINE = ROOT / "runtime/soju-engine-dxmt-ow2-v0.2"
BASE_PREFIX = ROOT / "runtime/prefix-dxmt-ow2-v0.2"
ENGINE = ROOT / "runtime/soju-engine-dxmt-local"
PREFIX = ROOT / "runtime/prefix-dxmt-local"
FILES = ["x86_64-windows/" + n for n in ("d3d11.dll", "dxgi.dll", "d3d10core.dll", "winemetal.dll")]
FILES += ["x86_64-unix/winemetal.so"]


def validate_build():
    path = INSTALL / "build-manifest.json"
    if not path.is_file():
        raise SystemExit("No completed local build. Run Build DXMT - Local Optimizations.command first.")
    manifest = json.loads(path.read_text())
    for name in FILES:
        path = INSTALL / name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != manifest["files"].get(name):
            raise SystemExit("Build output missing or changed: " + name)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    manifest = validate_build()
    if args.check:
        print("Completed local build hashes verified; no files changed.")
        return
    if ENGINE.exists() or PREFIX.exists():
        raise SystemExit("Local staging already exists. Preserve/review it before staging another build.")
    if shutil.disk_usage(ROOT).free < 5 * 2**30:
        raise SystemExit("Less than 5 GiB free. Cannot safely stage the build.")
    stop_clients()  # Refuses any running Overwatch before touching environments.
    with tempfile.TemporaryDirectory(prefix="dxmt-stage-", dir=ROOT / "runtime") as folder:
        stage = Path(folder)
        staged_engine, staged_prefix = stage / "engine", stage / "prefix"
        for original, target in ((BASE_ENGINE, staged_engine), (BASE_PREFIX, staged_prefix)):
            subprocess.run(["/bin/cp", "-cR", str(original), str(target)], check=True)
        for name in FILES:
            shutil.copy2(INSTALL / name, staged_engine / "lib/wine" / name)
        shutil.copy2(INSTALL / "x86_64-windows/winemetal.dll", staged_prefix / "drive_c/windows/system32/winemetal.dll")
        # The fork's 32-bit bridge/API layout is unchanged; retain its existing
        # 32-bit DLLs. Native winemetal.so contains the changed cache implementation.
        (staged_engine / "local-build-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        # Publish engine last: its manifest is the launch-readiness marker.
        os.rename(staged_prefix, PREFIX)
        os.rename(staged_engine, ENGINE)
    print("Local source build staged in a separate engine and Windows environment.")
    print("Use Launch Battle.net - Source Build.command. Original DXMT and D3DMetal remain available.")


if __name__ == "__main__":
    main()
