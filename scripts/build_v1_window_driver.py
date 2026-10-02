#!/usr/bin/env python3
"""Build only the private native Wine window driver, with the local CLI tools."""
import argparse
import difflib
import hashlib
import json
import os
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parent.parent
SOURCE=ROOT/'runtime/source/wine-v1'
BUILD=ROOT/'runtime/build/winemac-v1'
ENGINE=ROOT/'runtime/soju-engine-dxmt-local'
NATIVE=SOURCE/'dlls/winemac.drv'
REFERENCE=ROOT/'runtime/source-reference/crossover-26.3'

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def hashes():return {p.name:digest(p) for p in NATIVE.iterdir() if p.suffix in ('.h','.c','.m') or p.name=='Makefile.in'}
def run(command,env,log):subprocess.run([str(x) for x in command],env=env,cwd=BUILD,stdout=log,stderr=subprocess.STDOUT,check=True)
def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--configure',action='store_true');args=parser.parse_args()
    BUILD.mkdir(parents=True,exist_ok=True)
    env=os.environ.copy();env['PATH']=str(ROOT/'runtime/toolchains/bison/bin')+':'+str(ROOT/'runtime/toolchains/llvm-mingw-20251216-ucrt-macos-universal/bin')+':'+env['PATH']
    before=hashes()
    with (BUILD/'v1-build.log').open('w') as log:
        if args.configure or not (BUILD/'Makefile').exists():
            run(['/usr/bin/arch','-x86_64',SOURCE/'configure','--enable-archs=i386,x86_64','--without-x','--disable-tests',
                 '--without-freetype','--without-gnutls','--without-gstreamer','CC=/usr/bin/clang -arch x86_64','CXX=/usr/bin/clang++ -arch x86_64'],env,log)
        for name in ['ntdll','win32u']:
            target=BUILD/f'dlls/{name}/{name}.so';target.parent.mkdir(parents=True,exist_ok=True)
            expected=ENGINE/f'lib/wine/x86_64-unix/{name}.so'
            if target.is_symlink():
                if target.resolve()!=expected.resolve():raise RuntimeError('Unexpected link dependency')
            elif target.exists():raise RuntimeError('Refusing to replace an independently built dependency')
            else:target.symlink_to(expected)
        run(['make','-j2','-o','dlls/ntdll/ntdll.so','-o','dlls/win32u/win32u.so','dlls/winemac.drv/winemac.so'],env,log)
        driver=BUILD/'dlls/winemac.drv/winemac.so'
        run(['/usr/bin/codesign','--force','--sign','-',driver],env,log)
        run(['/usr/bin/codesign','--verify','--strict',driver],env,log)
    if before!=hashes():raise RuntimeError('Window driver source changed during compilation')
    patch=[]
    for name in sorted(before):
        original=REFERENCE/name
        if not original.exists() and name not in ['cocoa_v1.h','cocoa_v1.m']:
            continue
        old=original.read_text().splitlines(keepends=True) if original.exists() else []
        new=(NATIVE/name).read_text().splitlines(keepends=True)
        patch.extend(difflib.unified_diff(old,new,fromfile='a/dlls/winemac.drv/'+name if old else '/dev/null',tofile='b/dlls/winemac.drv/'+name))
    patch_path=ROOT/'patches/wine-v1-canvas.patch';patch_path.write_text(''.join(patch))
    manifest=dict(source_provenance=json.loads((SOURCE/'LOCAL_PROVENANCE.json').read_text()),
        sources=before,driver_sha256=digest(driver),patch_sha256=digest(patch_path),
        dependencies={name:digest(ENGINE/f'lib/wine/x86_64-unix/{name}.so') for name in ['ntdll','win32u']},
        scope='Native Mac driver only; retains installed Wine Windows components, ntdll and win32u.')
    (BUILD/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print(json.dumps(dict(driver=str(driver),sha256=manifest['driver_sha256'],patch=str(patch_path)),indent=2))
if __name__=='__main__':main()
