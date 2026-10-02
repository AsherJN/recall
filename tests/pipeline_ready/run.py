#!/usr/bin/env python3
"""Compile the actual one-shot helper against instrumented native test primitives."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[2] / "runtime/source/dxmt-ow2")
args = parser.parse_args()
test_dir = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="pipeline-ready-", dir=test_dir) as temporary:
    executable = Path(temporary) / "harness"
    subprocess.run([
        "/usr/bin/clang++", "-std=c++20", "-O1", "-g", "-Wall", "-Wextra", "-Werror",
        "-fsanitize=address,undefined", "-fno-omit-frame-pointer", "-pthread",
        "-I", str(test_dir / "stubs"), "-I", str(args.source / "src/d3d11"),
        str(test_dir / "harness.cpp"), "-o", str(executable),
    ], check=True)
    subprocess.run([str(executable)], check=True, timeout=45)
