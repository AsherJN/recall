#!/usr/bin/env python3
"""Compile actual variant declarations/hash with host-only type stubs."""
import argparse
from pathlib import Path
import subprocess
import tempfile

parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[2] / "runtime/source/dxmt-ow2")
args = parser.parse_args()
directory = Path(__file__).resolve().parent
source = (args.source / "src/d3d11/d3d11_shader.hpp").read_text()
declarations = source[source.index("struct ShaderVariantVertex {"):source.index("class ThreadpoolWork {")]
hash_definition = source[source.rindex("namespace std {"):]
harness = (directory / "variants.cpp.in").read_text().replace("@VARIANT_DECLARATIONS@", declarations).replace("@VARIANT_HASH@", hash_definition)
with tempfile.TemporaryDirectory(prefix="shader-variants-", dir=directory) as temporary:
    cpp = Path(temporary) / "variants.cpp"
    executable = Path(temporary) / "variants"
    cpp.write_text(harness)
    subprocess.run(["/usr/bin/clang++", "-std=c++20", "-O2", "-Wall", "-Wextra", "-Werror", "-Wno-unused-parameter", str(cpp), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
