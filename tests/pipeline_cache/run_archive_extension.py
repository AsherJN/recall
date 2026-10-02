#!/usr/bin/env python3
"""Reproduce native Metal archive extension behavior with three generated libraries."""
import argparse
import datetime
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--fixture-dir", type=Path, required=True,
                    help="Artifact directory from run_manager_render.py containing three fixture metallibs.")
args = parser.parse_args()
fixture = args.fixture_dir.resolve()
if not fixture.is_relative_to(ROOT / "logs/dxmt"):
    raise SystemExit("Use this experiment's generated logs/dxmt fixtures.")
nonce = re.search(r"vertex_([0-9a-f]+)\(", (fixture / "fixture.metal").read_text()).group(1)
for suffix in ("", "_1", "_2"):
    if not (fixture / f"fixture{suffix}.metallib").is_file():
        raise SystemExit("All three generated library fixtures are required.")
output = ROOT / "logs/dxmt" / ("metal-archive-extension-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
output.mkdir(parents=True, exist_ok=False)
binary = output / "probe"
subprocess.run(["/usr/bin/clang", "-arch", "x86_64", "-x", "objective-c", "-fobjc-arc", "-O2",
                "-framework", "Foundation", "-framework", "Metal",
                str(Path(__file__).with_name("archive_extend_probe.m")), "-o", str(binary)], check=True)
reports = []

def run(label, mode, suffix="_2", seed=None, prior=False, third=False):
    env = os.environ.copy()
    for key in list(env):
        if key.startswith(("DXMT_", "MTL_")):
            env.pop(key)
    env["DXMT_PROBE_ARCHIVE_MODE"] = mode
    if prior:
        env["DXMT_PROBE_PRIOR_LIBRARY"] = str(fixture / "fixture_1.metallib")
    if third:
        env["DXMT_PROBE_THIRD_LIBRARY"] = str(fixture / "fixture.metallib")
    result = subprocess.run([str(binary), str(fixture / f"fixture{suffix}.metallib"),
                             str(seed or output / "absent.metallib"), nonce, suffix,
                             str(output / f"{label}.metallib")], env=env, capture_output=True, text=True, timeout=30)
    (output / f"{label}.stderr.log").write_text(result.stderr)
    if result.returncode:
        raise SystemExit(f"{label}: {result.stderr}")
    report = {"case":label, **json.loads(result.stdout)}
    reports.append(report)
    return report

assert run("seed", "fresh", suffix="_1")["serialized"]
seed = output / "seed.metallib"
assert run("fresh_two", "fresh", prior=True)["serialized"]
assert run("fresh_three", "fresh", prior=True, third=True)["serialized"]
for mode in ("seeded", "seeded_prior", "seeded_prior_add"):
    run(mode, mode, seed=seed, prior=mode != "seeded")
for suffix in ("", "_1", "_2"):
    report = run("verify" + (suffix or "_0"), "verify", suffix=suffix, seed=output / "fresh_three.metallib")
    assert report["strict_hit"] and report["pixels_passed"]
report = {"fixture":str(fixture), "nonce":nonce, "results":reports,
          "interpretation":"Seeded-extension failures are observed driver/compiler behavior, not required forever. Fresh collection and strict persisted lookup must succeed."}
(output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"output":str(output), "results":[{"case":r["case"], "serialized":r.get("serialized"),
                     "strict_hit":r.get("strict_hit"), "error_code":r.get("error_code")} for r in reports]}, indent=2))
