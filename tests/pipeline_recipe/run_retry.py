#!/usr/bin/env python3
"""Exercise production retry metadata lifetime/bounds under x86_64 sanitizers."""
from pathlib import Path
import os, subprocess, tempfile
ROOT=Path(__file__).resolve().parents[2]
HERE=Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix='retry-',dir=HERE) as temp:
    binary=Path(temp)/'retry'
    subprocess.run(['/usr/bin/clang','-arch','x86_64','-x','objective-c','-fblocks','-fno-objc-arc',
                    '-Wall','-Wextra','-Werror','-Wno-deprecated-declarations',
                    '-fsanitize=address,undefined','-fno-omit-frame-pointer',
                    '-I',str(ROOT/'runtime/source/dxmt-ow2/src/winemetal/unix'),
                    '-I',str(ROOT/'runtime/source/dxmt-ow2/src/winemetal'),
                    str(HERE/'retry.m'),str(ROOT/'runtime/source/dxmt-ow2/src/winemetal/unix/pipeline_recipe.c'),
                    '-framework','Foundation','-framework','Metal','-o',str(binary)],check=True)
    subprocess.run([str(binary)],check=True,env=dict(os.environ,ASAN_OPTIONS='detect_leaks=0'),timeout=40)
