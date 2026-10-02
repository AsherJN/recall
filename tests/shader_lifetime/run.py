#!/usr/bin/env python3
"""Exercise actual DXMT method bodies with deterministic allocation/Metal stubs.

This is a host-only C++ regression harness, not a DXMT or Xcode build.
"""

import argparse
import csv
import os
from pathlib import Path
import subprocess
import tempfile


def body(source: str, signature: str) -> str:
    start = source.index("{", source.index(signature))
    depth = 1
    end = start + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[2] / "runtime/source/dxmt-ow2")
args = parser.parse_args()
test_dir = Path(__file__).resolve().parent
cache = (args.source / "src/d3d11/d3d11_pipeline_cache.cpp").read_text()
shader = (args.source / "src/d3d11/d3d11_shader.cpp").read_text()
trace = (args.source / "src/d3d11/d3d11_shader_trace.hpp").read_text()
trace = "\n".join(line for line in trace.splitlines() if not line.startswith('#include "') and line != "#pragma once")
harness = (test_dir / "harness.cpp.in").read_text()
harness = harness.replace("@CACHE_DESTRUCTOR@", body(cache, "~CachedSM50Shader()"))
harness = harness.replace("@COMPILE_WORK@", body(shader, "RunThreadpoolWork()"))
harness = harness.replace("@SHADER_TRACE@", trace)
with tempfile.TemporaryDirectory(prefix="shader-lifetime-", dir=test_dir) as temporary:
    directory = Path(temporary)
    cpp, executable = directory / "harness.cpp", directory / "harness"
    cpp.write_text(harness)
    subprocess.run(["/usr/bin/clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror", str(cpp), "-o", str(executable)], check=True)
    environment = dict(os.environ, DXMT_SHADER_LOG=str(directory / "trace"))
    subprocess.run([str(executable)], check=True, env=environment)
    with (directory / "trace-42.csv").open() as stream:
        rows = list(csv.DictReader(stream))
    expected = [
        ("hit", "ready"), ("library_rejected", "ready"), ("function_rejected", "ready"),
        ("missing", "ready"), ("missing", "ir_failed"), ("missing", "ir_failed"),
        ("missing", "translate_failed"), ("missing", "library_failed"),
        ("missing", "library_failed"), ("missing", "function_failed"),
    ]
    assert [(row["cache"], row["result"]) for row in rows] == expected
    for row in rows:
        assert len(row["shader_sha1"]) == len(row["variant_sha1"]) == 40
        for field in row:
            if field.endswith("_us"):
                assert int(row[field]) >= 0
    print("PASS keyed shader trace: cache classification and all completion/error paths")
    disabled_environment = dict(os.environ)
    disabled_environment.pop("DXMT_SHADER_LOG", None)
    previous_files = {path.name: path.stat().st_size for path in directory.iterdir()}
    subprocess.run([str(executable)], check=True, env=disabled_environment, stdout=subprocess.DEVNULL)
    assert previous_files == {path.name: path.stat().st_size for path in directory.iterdir()}
    print("PASS shader tracing disabled: no files created or changed")
