#!/usr/bin/env python3
"""Build-time Metal wrapper: keep the developer's path out of embedded AIR.

Metal retains its canonical input filename even with prefix-map flags. Feeding
the identical shader bytes through stdin gives AIR a neutral source identity.
Compiler options and shader contents are unchanged; `metallib` runs as given.

Xcode 27 installs the Metal toolchain as a separate download. Without it, a
build can reuse outputs made earlier through this wrapper from byte-identical
input: DXMT_METAL_CACHE names a folder of <sha256 of input>.<output suffix>
files. Any other failure, or a cache miss, fails the build. Never shipped to
players.
"""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import sys

args = sys.argv[1:]
output_index = args.index('-o') + 1
output = Path(args[output_index]).resolve()
args[output_index] = str(output)
tool = next(a for i, a in enumerate(args) if not a.startswith('-') and (i == 0 or args[i - 1] not in ('-sdk', '-o')))
if tool == 'metallib':
    source = Path(args[-1]).resolve(strict=True)
    result = subprocess.run(['/usr/bin/xcrun', *args], capture_output=True)
else:
    if args.count('-c') != 1:
        raise SystemExit('Expected one Metal compile input')
    index = args.index('-c') + 1
    source = Path(args[index]).resolve(strict=True)
    args[index:index + 1] = ['-x', 'metal', '-']
    result = subprocess.run(['/usr/bin/xcrun', *args], input=source.read_bytes(), cwd=source.parent,
                            capture_output=True)
if result.returncode == 0:
    sys.stdout.buffer.write(result.stdout)
    sys.stderr.buffer.write(result.stderr)
    raise SystemExit(0)
missing = b'missing Metal Toolchain' in result.stderr or b'unable to find utility' in result.stderr
cache = os.environ.get('DXMT_METAL_CACHE')
if not missing or not cache:
    sys.stderr.buffer.write(result.stderr)
    raise SystemExit(result.returncode or 1)
digest = hashlib.sha256(source.read_bytes()).hexdigest()
cached = Path(cache) / f'{digest}{output.suffix}'
if not cached.is_file():
    raise SystemExit(f'Metal toolchain missing and no cached {output.suffix} for {source.name} ({digest}).\n'
                     'Install it with: xcodebuild -downloadComponent MetalToolchain')
shutil.copyfile(cached, output)
sys.stderr.write(f'portable_metal: reused {cached.name} for {source.name}\n')
