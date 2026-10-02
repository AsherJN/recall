#!/usr/bin/env python3
"""Exercise the actual native manager/codec across fresh processes and real Metal draws."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import secrets
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, default=ROOT / "runtime/source/dxmt-ow2")
parser.add_argument("--arch", choices=("arm64", "x86_64"), default="x86_64")
parser.add_argument("--sanitize", action="store_true", help="Enable AddressSanitizer and UndefinedBehaviorSanitizer.")
args = parser.parse_args()
output = ROOT / "logs/dxmt" / ("pipeline-manager-proof-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
output.mkdir(parents=True, exist_ok=False)
directory = Path(__file__).resolve().parent
native = args.source / "src/winemetal/unix"
production_hashes = {name:hashlib.sha256((native / name).read_bytes()).hexdigest()
                     for name in ("pipeline_recipe.c", "pipeline_recipe.h", "pipeline_cache.c", "pipeline_cache.h")}
nonce = secrets.token_hex(8)
red = 32 + int(nonce, 16) % 160
metal, air, metallib = (output / name for name in ("fixture.metal", "fixture.air", "fixture.metallib"))
metal.write_text(f'''#include <metal_stdlib>
using namespace metal;
vertex float4 vertex_{nonce}(uint id [[vertex_id]]) {{
  const float2 p[3] = {{float2(-1,-1),float2(3,-1),float2(-1,3)}};
  return float4(p[id],0,1);
}}
fragment float4 fragment_{nonce}() {{ return float4({red / 255:.10f},0.25,0.75,1.0); }}
fragment float4 fragment_{nonce}_1() {{ return float4({red / 255:.10f},0.45,0.75,1.0); }}
fragment float4 fragment_{nonce}_2() {{ return float4({red / 255:.10f},0.60,0.75,1.0); }}
''')
library = output / "libpipeline_test.dylib"
commands = [
    ["xcrun", "-sdk", "macosx", "metal", "-std=metal3.1", "-c", str(metal), "-o", str(air)],
    ["xcrun", "-sdk", "macosx", "metallib", str(air), "-o", str(metallib)],
    ["/usr/bin/clang", "-arch", args.arch, "-x", "objective-c", "-fblocks", "-fno-objc-arc", "-O2", "-dynamiclib",
     str(native / "pipeline_recipe.c"), str(native / "pipeline_cache.c"), "-framework", "Foundation",
     "-framework", "Metal", "-framework", "QuartzCore", "-install_name", str(library), "-o", str(library)],
    ["/usr/bin/clang", "-arch", args.arch, "-x", "objective-c", "-fblocks", "-fobjc-arc", "-O2",
     "-I", str(native), "-Wall", "-Wextra", "-Werror", "-c", str(directory / "manager_render_probe.m"),
     "-o", str(output / "probe.o")],
    ["/usr/bin/clang", "-arch", args.arch, str(output / "probe.o"), str(library),
     "-framework", "Foundation", "-framework", "Metal", "-o", str(output / "probe")],
]
for index, green in ((1, 0.45), (2, 0.60)):
    extra_metal, extra_air, extra_library = (output / f"fixture_{index}.{extension}" for extension in ("metal", "air", "metallib"))
    extra_metal.write_text(f'''#include <metal_stdlib>
using namespace metal;
vertex float4 vertex_{nonce}(uint id [[vertex_id]]) {{
  const float2 p[3] = {{float2(-1,-1),float2(3,-1),float2(-1,3)}};
  return float4(p[id],0,1);
}}
fragment float4 fragment_{nonce}_{index}() {{ return float4({red / 255:.10f},{green:.2f},0.75,1.0); }}
''')
    commands[2:2] = [
        ["xcrun", "-sdk", "macosx", "metal", "-std=metal3.1", "-c", str(extra_metal), "-o", str(extra_air)],
        ["xcrun", "-sdk", "macosx", "metallib", str(extra_air), "-o", str(extra_library)],
    ]
if args.sanitize:
    for command in commands:
        if command[0] == "/usr/bin/clang":
            command[1:1] = ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
with (output / "build.log").open("w") as log:
    for command in commands:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
environment = os.environ.copy()
for key in list(environment):
    if key.startswith(("DXMT_", "MTL_")):
        environment.pop(key)
if args.sanitize:
    # Production deliberately retains managers and pins their native module
    # until process exit; address/undefined-behavior checks remain enabled.
    environment["ASAN_OPTIONS"] = "detect_leaks=0"
reports = []
cache = output / "cache"

def run(mode, cache_path=cache, budget=500, enabled=True, limit=4):
    env = environment.copy()
    env.update(DXMT_PIPELINE_CACHE_NAMESPACE="standalone-manager-v1",
               DXMT_PIPELINE_CACHE_PREWARM_MS=str(budget), DXMT_PIPELINE_CACHE_PREWARM_LIMIT=str(limit),
               DXMT_PIPELINE_CACHE_LOG=str(output / mode))
    if enabled:
        env["DXMT_PIPELINE_CACHE_PATH"] = str(cache_path)
    result = subprocess.run([str(output / "probe"), str(metallib), nonce, mode], env=env,
                            capture_output=True, text=True, timeout=12)
    (output / f"{mode}.stderr.log").write_text(result.stderr)
    if result.returncode:
        print(result.stdout, result.stderr)
        raise SystemExit(f"actual manager {mode} failed; artifacts {output}")
    report = json.loads(result.stdout)
    (output / f"{mode}.result.json").write_text(json.dumps(report, indent=2) + "\n")
    traces = list(output.glob(f"{mode}-*.jsonl"))
    if enabled:
        assert len(traces) == 1, traces
        events = [json.loads(line) for line in traces[0].read_text().splitlines()]
        summaries = [event for event in events if event["event"] == "summary"]
        assert summaries, events
        report["summary"] = summary = summaries[-1]
        report["events"] = events
        assert report["same_pso_identity"] and summary["startup_done"], report
        # Diagnostic records use the same nonblocking queue and may legitimately
        # drop on contention. Required persisted data and actual cache outcomes
        # are asserted below; a dropped telemetry row is not a render failure.
        assert summary["unsupported"] == 0, report
        assert summary["persist_failures"] == 0, report
        assert summary["hits"] >= 1
        if mode.startswith("growth_"):
            assert report["recipe_count"] == 3, report
            prewarmed = 0 if mode == "growth_learn" else 3 if mode in ("growth_verified", "growth_batch_fresh", "growth_batch_verified") else 1
            assert summary["prewarmed"] == prewarmed, report
            assert summary["runtime_creates"] == 3 - prewarmed, report
            assert summary["hits"] == 3 + prewarmed and summary["misses"] == 3 - prewarmed, report
            expected_adds = 0 if mode in ("growth_learn", "growth_verified", "growth_batch_verified") else 3 if mode == "growth_batch_fresh" else 1
            assert summary["archive_adds"] == expected_adds, report
            if mode in ("growth_verified", "growth_batch_verified"):
                assert summary["archive_lookup_hits"] == 3 and summary["archive_lookup_misses"] == 0, report
        elif mode in ("cold", "budget_zero", "corrupt_recipe", "corrupt_library", "mismatched_recipe"):
            assert summary["prewarmed"] == 0 and summary["archive_adds"] == 0, report
            assert summary["misses"] == 1 and summary["hits"] == 1, report
        else:
            assert summary["prewarmed"] == 1, report
            assert summary["archive_adds"] == (0 if mode in ("archive_loaded", "repaired_archive") else 1), report
            assert summary["misses"] == 0 and summary["hits"] == 2, report
        if mode in ("archive_loaded", "repaired_archive"):
            assert summary["archive_lookup_hits"] == 1 and summary["runtime_creates"] == 0, report
        if mode in ("corrupt_library", "mismatched_recipe"):
            assert summary["prewarm_failures"] >= 1, report
        if mode == "cold":
            assert len(list(cache_path.glob("*/recipes/*.json"))) == 1
            assert len(list(cache_path.glob("*/libraries/*.air"))) == 1
            assert not list(cache_path.glob("*/archives/*.metallib")), "learning populated a binary archive"
    else:
        assert not traces and not report["enabled"], report
    reports.append(report)
    (output / "partial-results.json").write_text(json.dumps(reports, indent=2) + "\n")
    return report

run("cold", budget=500)
run("warm", budget=500)
run("archive_loaded", budget=500)
run("budget_zero", budget=0)
for mode, glob in (("corrupt_library", "*/libraries/*.air"), ("corrupt_recipe", "*/recipes/*.json"),
                   ("corrupt_archive", "*/archives/*.metallib")):
    cloned = output / (mode + "-cache")
    shutil.copytree(cache, cloned)
    paths = list(cloned.glob(glob))
    assert paths, (mode, glob)
    for path in paths:
        path.write_bytes(b"deliberately corrupt isolated cache entry\n")
    run(mode, cache_path=cloned, budget=500)
    if mode == "corrupt_archive":
        run("repaired_archive", cache_path=cloned, budget=500)
# Valid JSON and descriptor fields must still be rejected when their content
# does not match the filename key, even though ranking only examines metadata.
mismatched_cache = output / "mismatched-recipe-cache"
shutil.copytree(cache, mismatched_cache)
for path in mismatched_cache.glob("*/recipes/*.json"):
    entry = json.loads(path.read_text())
    entry["recipe"]["sample_count"] = 2
    entry["cost_us"] = 60000000
    path.write_text(json.dumps(entry) + "\n")
run("mismatched_recipe", cache_path=mismatched_cache, budget=500)
run("disabled", enabled=False)
growth_cache = output / "growth-cache"
run("growth_learn", cache_path=growth_cache, budget=0, limit=1)
batch_cache = output / "growth-batch-cache"
shutil.copytree(growth_cache, batch_cache)
run("growth_batch_fresh", cache_path=batch_cache, budget=500, limit=3)
run("growth_batch_verified", cache_path=batch_cache, budget=500, limit=3)
missing_cache = output / "growth-missing-library-cache"
shutil.copytree(growth_cache, missing_cache)
learned = [(path, json.loads(path.read_text())) for path in missing_cache.glob("*/recipes/*.json")]
assert len(learned) == 3
highest_path, highest = max(learned, key=lambda item:item[1]["cost_us"])
missing_library = highest["recipe"]["vertex"]["library"]
assert highest["recipe"]["fragment"]["library"] == missing_library
assert sum(entry["recipe"]["vertex"]["library"] == missing_library for _, entry in learned) == 1
removed = highest_path.parent.parent / "libraries" / (missing_library + ".air")
removed.unlink()  # Only the deliberately cloned test cache under this run's output.
missing_result = run("growth_missing_library", cache_path=missing_cache, budget=500, limit=1)
assert missing_result["summary"]["prewarm_failures"] == 1, missing_result
prepared_after_missing = {event["key"] for event in missing_result["events"] if event["event"] == "prewarm" and event["success"]}
assert len(prepared_after_missing) == 1 and highest_path.stem not in prepared_after_missing
prepared_keys = set()
for iteration in range(1, 4):
    result = run(f"growth_warm_{iteration}", cache_path=growth_cache, budget=500, limit=1)
    prewarmed_keys = {event["key"] for event in result["events"] if event["event"] == "prewarm" and event["success"]}
    assert len(prewarmed_keys) == 1 and not prepared_keys.intersection(prewarmed_keys), result
    prepared_keys.update(prewarmed_keys)
    manifests = list(growth_cache.glob("*/archive.json"))
    assert len(manifests) == 1
    manifest = json.loads(manifests[0].read_text())
    assert set(manifest["prepared_keys"]) == prepared_keys, manifest
    assert manifest["schema"] == 2 and len(manifest["archives"]) == iteration, manifest
run("growth_verified", cache_path=growth_cache, budget=500, limit=3)
after_hashes = {name:hashlib.sha256((native / name).read_bytes()).hexdigest() for name in production_hashes}
report = {"architecture":args.arch, "sanitized":args.sanitize, "nonce":nonce, "results":reports, "compiler_commands":commands,
          "production_source_sha256":production_hashes, "source_changed_during_run":production_hashes != after_hashes,
          "limits":["Real production codec/manager and GPU readback, standalone native process; no Wine bridge or game performance claim.",
                    "One-recipe recovery and three-recipe archive progression; mesh/tessellation and large-scale resource contention remain outside this check.",
                    "Startup budget limits when new work begins; in-flight Metal calls are not cancelable."]}
(output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"output":str(output), "source_changed_during_run":report["source_changed_during_run"],
                  "passed_modes":[r["mode"] for r in reports],
                  "final_growth":{key:reports[-1]["summary"][key] for key in
                      ("prewarmed", "hits", "runtime_creates", "archive_lookup_hits", "archive_adds")}}, indent=2))
