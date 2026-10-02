#!/usr/bin/env python3
"""Fresh-process native Metal binary-archive proof and bounded matched-PSO timings."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import secrets
import statistics
import subprocess

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--samples", type=int, default=12)
parser.add_argument("--arch", choices=("arm64", "x86_64"), default="arm64")
args = parser.parse_args()
if not 1 <= args.samples <= 32:
    raise SystemExit("Choose 1–32 samples per mechanism.")
output = ROOT / "logs/dxmt" / ("metal-archive-proof-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
output.mkdir(parents=True, exist_ok=False)
source = Path(__file__).with_name("metal_archive_probe.m")
binary = output / "metal_archive_probe"
command = ["/usr/bin/clang", "-arch", args.arch, "-x", "objective-c", "-fobjc-arc", "-O2",
           "-Wall", "-Wextra", "-Werror", "-framework", "Foundation", "-framework", "Metal",
           str(source), "-o", str(binary)]
subprocess.run(command, check=True)
nonce = secrets.token_hex(8)
(output / "corrupt.binary.metallib").write_bytes(b"deliberately invalid archive for this isolated test\n")
environment = os.environ.copy()
for key in list(environment):
    if key.startswith(("DXMT_", "MTL_")):
        environment.pop(key)
records = []

def run(mode, iteration=None, order=None):
    result = subprocess.run([str(binary), mode, str(output), nonce], env=environment,
                            capture_output=True, text=True, timeout=30)
    with (output / "stderr.log").open("a") as stream:
        stream.write(result.stderr)
    if result.returncode:
        print(result.stdout, result.stderr)
        raise SystemExit(f"{mode} failed with exit {result.returncode}; artifacts: {output}")
    record = json.loads(result.stdout)
    if iteration is not None:
        record.update(iteration=iteration, order=order)
    records.append(record)
    with (output / "results.jsonl").open("a") as stream:
        stream.write(json.dumps(record) + "\n")
    return record

capture = run("capture")
for iteration in range(args.samples):
    for order, mode in enumerate(("archive", "default") if iteration % 2 == 0 else ("default", "archive")):
        run(mode, iteration, order)
run("miss")
run("errors")

def metrics(values):
    values = sorted(values)
    return {"count":len(values), "median_ms":statistics.median(values),
            "p95_ms":values[int(.95 * (len(values) - 1))], "min_ms":min(values), "max_ms":max(values)}

summary = {
    "architecture":args.arch, "nonce":nonce, "device":capture["device"],
    "all_pixel_readbacks_passed":True, "strict_archive_hits":args.samples,
    "unseen_descriptor_strict_miss_and_fallback_passed":True,
    "cache_errors_accounted_with_successful_render_fallback":True,
    "timings":{mode:metrics([record["pipeline_create_ms"] for record in records if record["mode"] == mode])
               for mode in ("archive", "default")},
    "archive_load_plus_first_pipeline_timings":{
        mode:metrics([record["pipeline_create_ms"] + record.get("archive_load_ms", 0)
                      for record in records if record["mode"] == mode])
        for mode in ("archive", "default")},
    "capture":capture, "archive_bytes":(output / "known.binary.metallib").stat().st_size,
    "compiler_command":command,
    "source_sha256":hashlib.sha256(source.read_bytes()).hexdigest(),
    "binary_sha256":hashlib.sha256(binary.read_bytes()).hexdigest(),
    "limits":["One simple PSO, no Overwatch shaders or rendering workload.",
              "Default Metal framework cache kept enabled and never cleared; this is incremental explicit-archive benefit over an already warm framework cache.",
              "Fresh processes alternate A/B order; library compilation and archive loading are measured separately from PSO creation.",
              "Native Metal proof only; does not validate DXMT integration, Wine bridge ownership, mesh shaders, prewarming, or game FPS."]}
(output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps({"output":str(output), "summary":summary}, indent=2))
