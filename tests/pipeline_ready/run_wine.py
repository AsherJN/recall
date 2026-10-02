#!/usr/bin/env python3
"""Benchmark the production one-shot helper in an existing isolated Wine prefix."""
import argparse
import csv
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, default=ROOT / "runtime/source/dxmt-ow2")
parser.add_argument("--prefix", type=Path, required=True)
parser.add_argument("--engine", type=Path, default=ROOT / "runtime/soju-engine-dxmt-local")
parser.add_argument("--output", type=Path)
args = parser.parse_args()
prefix = args.prefix.resolve()
if not prefix.is_relative_to(ROOT / "runtime/diagnostics") or not (prefix / "system.reg").is_file():
    raise SystemExit("An existing isolated runtime/diagnostics Wine prefix is required.")
output = args.output or ROOT / "logs/dxmt" / ("pipeline-ready-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
output.mkdir(parents=True, exist_ok=False)
spec = importlib.util.spec_from_file_location("launch_cx26", ROOT / "scripts/launch_cx26.py")
launch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(launch)
env = launch.build_environment("dxmt", args.engine, prefix, profile="smooth60", source_build=True,
                               pipeline_cache=False)
compiler = ROOT / "runtime/toolchains/llvm-mingw-20251216-ucrt-macos-universal/bin/x86_64-w64-mingw32-clang++"
source = Path(__file__).with_name("wine_benchmark.cpp")
binary = output / "pipeline_ready_benchmark.exe"
command = [str(compiler), "-std=c++20", "-O2", "-static", "-Wall", "-Wextra", "-Werror",
           "-I", str(args.source / "src/d3d11"), "-I", str(args.source / "src/util"),
           str(source), "-o", str(binary)]
subprocess.run(command, check=True)
try:
    with (output / "results.csv").open("w") as stream, (output / "wine.log").open("w") as errors:
        subprocess.run([str(args.engine / "bin/wine"), launch.windows_path(binary)], env=env,
                       cwd=output, stdout=stream, stderr=errors, check=True, timeout=75)
finally:
    # WINEPREFIX scopes these commands to this diagnostic prefix only.
    subprocess.run([str(args.engine / "bin/wineserver"), "-k"], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run([str(args.engine / "bin/wineserver"), "-w"], env=env, check=True, timeout=20)
with (output / "results.csv").open() as stream:
    rows = list(csv.DictReader(stream))
assert len(rows) == 192, len(rows)

def metrics(values):
    values = sorted(values)
    return dict(count=len(values), median_us=statistics.median(values),
                p95_us=values[int(.95 * (len(values) - 1))], max_us=max(values), min_us=min(values))

summary = {"measurement": "Wait-return minus immediately-before-publication timestamp; includes signal-call and OS scheduling time.",
           "limits": ["Synthetic console comparison, no Metal or gameplay load.",
                      "Zero-delay trials can complete before the caller blocks; reported separately.",
                      "Does not estimate FPS improvement or eliminate actual pipeline compilation time."],
           "mechanisms": {}}
for mode in ("std_atomic_wait", "pipeline_ready_srw_cv"):
    selected = [row for row in rows if row["mechanism"] == mode]
    summary["mechanisms"][mode] = {"all": metrics([float(row["signal_to_return_us"]) for row in selected]),
        "nonzero_delay": metrics([float(row["signal_to_return_us"]) for row in selected if int(row["ready_delay_ms"]) > 0]),
        "per_delay": {delay: metrics([float(row["signal_to_return_us"]) for row in selected if row["ready_delay_ms"] == delay])
                      for delay in sorted({row["ready_delay_ms"] for row in selected}, key=int)}}
digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
provenance = {"compiler_command": command, "engine": str(args.engine), "prefix": str(prefix),
              "source_sha256": digest(source), "helper_sha256": digest(args.source / "src/d3d11/d3d11_pipeline_ready.hpp"),
              "thread_sha256": digest(args.source / "src/util/thread.hpp"), "binary_sha256": digest(binary),
              "staged_d3d11_sha256": digest(args.engine / "lib/wine/x86_64-windows/d3d11.dll"),
              "same_static_libcxx": True, "native_test_stubs": False, "interleaved": True,
              "repeats_per_mechanism_delay": 12}
(output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
(output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
print(json.dumps({"output": str(output), "summary": summary}, indent=2))
