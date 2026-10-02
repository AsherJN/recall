#!/usr/bin/env python3
"""Exercise production trace DLL pinning, Windows teardown, and sparse flushing."""
import argparse
import csv
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, default=ROOT / "runtime/source/dxmt-ow2")
parser.add_argument("--prefix", type=Path, required=True)
parser.add_argument("--engine", type=Path, default=ROOT / "runtime/soju-engine-dxmt-local")
args = parser.parse_args()
prefix = args.prefix.resolve()
if not prefix.is_relative_to(ROOT / "runtime/diagnostics") or not (prefix / "system.reg").is_file():
    raise SystemExit("An existing isolated runtime/diagnostics Wine prefix is required.")
output = ROOT / "logs/dxmt" / ("shader-trace-windows-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
output.mkdir(parents=True, exist_ok=False)
spec = importlib.util.spec_from_file_location("launch_cx26", ROOT / "scripts/launch_cx26.py")
launch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launch)
environment = launch.build_environment("dxmt", args.engine, prefix, profile="smooth60", source_build=True,
                                       pipeline_cache=False)
compiler = ROOT / "runtime/toolchains/llvm-mingw-20251216-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang++"
directory = Path(__file__).resolve().parent
common = [str(compiler), "-std=c++20", "-O2", "-static", "-Wall", "-Wextra", "-Werror"]
library = output / "shader_trace_test.dll"
executable = output / "shader_trace_test.exe"
commands = [common + ["-shared", "-I", str(args.source / "src/d3d11"), "-I", str(args.source / "src/util"),
                       str(directory / "wine_library.cpp"), "-o", str(library)],
            common + [str(directory / "wine_harness.cpp"), "-o", str(executable)]]
for command in commands:
    subprocess.run(command, check=True)
reports = []
try:
    for mode in ("abrupt", "unload", "normal", "quiet"):
        env = environment.copy()
        env["DXMT_SHADER_LOG"] = launch.windows_path(output / mode)
        if mode == "quiet":
            del env["DXMT_SHADER_LOG"]
        begin = time.monotonic()
        with (output / f"{mode}.log").open("w") as log:
            subprocess.run([str(args.engine / "bin/wine"), launch.windows_path(executable), mode,
                            launch.windows_path(library)], env=env, cwd=output,
                           stdout=log, stderr=subprocess.STDOUT, check=True, timeout=12)
        elapsed = time.monotonic() - begin
        paths = list(output.glob(f"{mode}-pipelines-*.csv"))
        if mode == "quiet":
            assert not paths and not list(output.glob("quiet-*.csv"))
            reports.append({"mode": mode, "elapsed_seconds": elapsed, "files": 0})
            continue
        assert len(paths) == 1, paths
        with paths[0].open() as stream:
            rows = list(csv.DictReader(stream))
        summaries = list(output.glob(f"{mode}-summary-*.csv"))
        assert len(summaries) == 1, summaries
        with summaries[0].open() as stream:
            summary = {row["stream"]: row for row in csv.DictReader(stream)}
        pipeline = summary["pipeline"]
        assert len(rows) == int(pipeline["records"]), summary
        assert not any(row["pipeline_id"] == "999" for row in rows)
        assert int(pipeline["pending"]) == 0 and int(pipeline["flush_errors"]) == 0
        if mode == "abrupt":
            assert {row["pipeline_id"] for row in rows} == {"1", "2"}
            assert pipeline["final"] == "0"  # No orderly shutdown created this data.
        elif mode == "normal":
            assert [row["pipeline_id"] for row in rows] == ["1"]
        else:
            assert 1 < len(rows) <= 81
            assert len(rows) + int(pipeline["dropped"]) == 81
            assert pipeline["final"] == "1"
        reports.append({"mode": mode, "elapsed_seconds": elapsed, "records": len(rows), "summary": summary})
finally:
    subprocess.run([str(args.engine / "bin/wineserver"), "-k"], env=environment,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run([str(args.engine / "bin/wineserver"), "-w"], env=environment, check=True, timeout=20)
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
report = {"compiler_commands": commands, "engine": str(args.engine), "prefix": str(prefix),
          "actual_header_sha256": digest(args.source / "src/d3d11/d3d11_shader_trace.hpp"),
          "dll_sha256": digest(library), "exe_sha256": digest(executable), "results": reports,
          "limits": "Actual Windows DLL lifecycle and CRT tested in Wine; no claim that arbitrary game teardown or storage failures are reproduced."}
(output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"output": str(output), "results": reports}, indent=2))
