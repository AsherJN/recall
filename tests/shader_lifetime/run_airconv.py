#!/usr/bin/env python3
"""Exercise real converter API control flow with deterministic LLVM stubs."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[2] / "runtime/source/dxmt-ow2")
args = parser.parse_args()
directory = Path(__file__).resolve().parent
source = (args.source / "src/airconv/dxbc_converter.cpp").read_text()


def function(name):
    start = source.index("AIRCONV_API ", source.index(name) - 20)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


names = ["SM50Compile", "SM50CompileTessellationPipelineHull", "SM50CompileTessellationPipelineDomain", "SM50CompileGeometryPipelineVertex", "SM50CompileGeometryPipelineGeometry"]
initialize = function("SM50Initialize(")
ownership_functions = [initialize] + [function(name + "(") for name in names]
allocations = sum(item.count("std::make_unique<SM50ErrorInternal>()") for item in ownership_functions)
transfers = sum(item.count("errorObj.release()") for item in ownership_functions)
if allocations == 6:
    assert transfers == 17, "Not every error transfer releases RAII ownership"
    assert not re.search(r"\(sm50_error_t\)errorObj\s*;", "\n".join(ownership_functions))
    print("PASS source ownership audit: six scoped error allocations, 17 explicit error transfers", flush=True)
else:
    print("Original raw error allocation policy detected; executing regression checks", flush=True)

initialize_prologue = initialize[initialize.index("{") + 1:initialize.index("  CDXBCParser DXBCParser;")]
class_start = source.index("class SM50CompiledBitcodeInternal {")
classes = source[class_start:source.index("namespace dxmt::dxbc {", class_start)]
functions = "\n\n".join(function(name + "(") for name in names + ["SM50DestroyBitcode", "SM50FreeError"])
harness = (directory / "airconv.cpp.in").read_text().replace("@OWNED_TYPES@", classes).replace("@COMPILE_APIS@", functions).replace("@INITIALIZE_PROLOGUE@", initialize_prologue)
with tempfile.TemporaryDirectory(prefix="airconv-lifetime-", dir=directory) as temporary:
    cpp = Path(temporary) / "airconv.cpp"
    executable = Path(temporary) / "airconv"
    cpp.write_text(harness)
    subprocess.run(["/usr/bin/clang++", "-std=c++20", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter", str(cpp), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
