#!/usr/bin/env python3
"""Compile the actual DXMT scheduler against host-only thread/Win32 stubs."""

import argparse
from pathlib import Path
import subprocess
import tempfile


parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[2] / "runtime/source/dxmt-ow2")
parser.add_argument("--shutdown-only", action="store_true")
parser.add_argument("--burst-only", action="store_true")
args = parser.parse_args()
test_dir = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="scheduler-", dir=test_dir) as temporary:
    executable = Path(temporary) / "harness"
    subprocess.run([
        "/usr/bin/clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror",
        "-fsanitize=address,undefined", "-fno-omit-frame-pointer",
        "-I", str(test_dir / "stubs"), "-I", str(args.source / "src/dxmt"),
        str(test_dir / "harness.cpp"), "-o", str(executable),
    ], check=True)
    flags = ["--burst-only"] if args.burst_only else (["--shutdown-only"] if args.shutdown_only else [])
    subprocess.run([str(executable)] + flags, check=True, timeout=45)
