#!/usr/bin/env python3
"""Actual recipe codec + CLI metallib + real GPU pixel roundtrip."""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess

ROOT = Path(__file__).resolve().parents[2]
parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, default=ROOT / "runtime/source/dxmt-ow2")
parser.add_argument("--arch", choices=("arm64", "x86_64"), default="x86_64")
args = parser.parse_args()
output = ROOT / "logs/dxmt" / ("recipe-render-proof-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
output.mkdir(parents=True, exist_ok=False)
directory = Path(__file__).resolve().parent
native = args.source / "src/winemetal/unix"
codec_hash = hashlib.sha256((native / "pipeline_recipe.c").read_bytes()).hexdigest()
nonce = secrets.token_hex(8)
red = 32 + int(nonce, 16) % 160
metal = output / "fixture.metal"
air, metallib = output / "fixture.air", output / "fixture.metallib"
metal.write_text(f'''#include <metal_stdlib>
using namespace metal;
vertex float4 vertex_{nonce}(uint id [[vertex_id]]) {{
  const float2 p[3] = {{float2(-1,-1),float2(3,-1),float2(-1,3)}};
  return float4(p[id],0,1);
}}
fragment float4 fragment_{nonce}() {{ return float4({red / 255:.10f},0.25,0.75,1.0); }}
''')
commands = [
    ["xcrun", "-sdk", "macosx", "metal", "-std=metal3.1", "-c", str(metal), "-o", str(air)],
    ["xcrun", "-sdk", "macosx", "metallib", str(air), "-o", str(metallib)],
    ["/usr/bin/clang", "-arch", args.arch, "-x", "objective-c", "-fblocks", "-fno-objc-arc", "-O2",
     "-c", str(native / "pipeline_recipe.c"), "-o", str(output / "pipeline_recipe.o")],
    ["/usr/bin/clang", "-arch", args.arch, "-x", "objective-c", "-fblocks", "-fobjc-arc", "-O2",
     "-I", str(native), "-Wall", "-Wextra", "-Werror", "-c", str(directory / "recipe_render_probe.m"),
     "-o", str(output / "probe.o")],
    ["/usr/bin/clang", "-arch", args.arch, str(output / "probe.o"), str(output / "pipeline_recipe.o"),
     "-framework", "Foundation", "-framework", "Metal", "-o", str(output / "probe")],
]
with (output / "build.log").open("w") as log:
    for command in commands:
        subprocess.run(command, check=True, stdout=log, stderr=subprocess.STDOUT)
environment = os.environ.copy()
for key in list(environment):
    if key.startswith(("DXMT_", "MTL_")):
        environment.pop(key)
result = subprocess.run([str(output / "probe"), str(metallib), nonce, str(output)], env=environment,
                        capture_output=True, text=True, timeout=30)
(output / "stderr.log").write_text(result.stderr)
if result.returncode:
    print(result.stdout, result.stderr)
    raise SystemExit(f"recipe-render proof failed: {output}")
report = json.loads(result.stdout)
report.update(architecture=args.arch, compiler_commands=commands, nonce=nonce,
              production_codec_sha256=codec_hash,
              source_changed_during_run=codec_hash != hashlib.sha256((native / "pipeline_recipe.c").read_bytes()).hexdigest(),
              limits="Actual native codec with real GPU; excludes cache manager lifecycle, mesh/tessellation, and gameplay.")
(output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({"output":str(output), "report":report}, indent=2))
