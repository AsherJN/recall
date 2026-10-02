#!/usr/bin/env python3
"""Compile the actual codec with real Metal descriptors and deterministic libraries."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[2]
HERE=Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='recipe-',dir=HERE) as temp:
    binary=Path(temp)/'recipe-test'
    subprocess.run(['/usr/bin/clang','-x','objective-c','-fblocks','-fno-objc-arc','-Wall','-Wextra','-Werror',
                    '-Wno-deprecated-declarations','-fsanitize=address,undefined','-fno-omit-frame-pointer',
                    '-I',str(ROOT/'runtime/source/dxmt-ow2/src/winemetal/unix'),
                    '-I',str(ROOT/'runtime/source/dxmt-ow2/src/winemetal'),
                    str(HERE/'harness.m'),str(ROOT/'runtime/source/dxmt-ow2/src/winemetal/unix/pipeline_recipe.c'),
                    '-framework','Foundation','-framework','Metal','-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True,env=dict(os.environ,ASAN_OPTIONS='detect_leaks=0'),timeout=30)
