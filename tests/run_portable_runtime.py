#!/usr/bin/env python3
"""Qualify an actual archive outside the checkout, including a GPU pixel check.

No accounts, game files or installed developer runtimes are copied. This is
functional setup/renderer evidence, never a gameplay performance benchmark.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT=Path(__file__).resolve().parents[1]


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--archive',type=Path,required=True)
    p.add_argument('--sha256',required=True)
    p.add_argument('--version',required=True)
    p.add_argument('--worker',type=Path,required=True)
    p.add_argument('--root',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    a=p.parse_args();root=a.root.resolve();out=a.output.resolve();worker=a.worker.resolve()
    if root.is_relative_to(ROOT) or ' ' not in str(root):
        p.error('Qualification root must be outside the checkout and contain spaces')
    if (root/'environment').exists():
        p.error('Use a fresh qualification root; existing environment is never adopted')
    out.mkdir(parents=True,exist_ok=True)
    binary=out/'portable-runtime-probe.exe'
    compiler=ROOT/'runtime/toolchains/llvm-mingw-20251216-ucrt-macos-universal/bin/x86_64-w64-mingw32-gcc'
    subprocess.run([str(compiler),'-O2','-g0',str(ROOT/'tests/portable_runtime_probe.c'),'-o',str(binary),
                    '-ld3d11','-ld3dcompiler','-ldxgi','-luser32'],check=True)
    directory_probe=out/'portable-directory-probe.exe'
    subprocess.run([str(compiler),'-O2','-g0','-Wall','-Wextra','-Werror',
                    str(ROOT/'tests/portable_directory_probe.c'),'-o',str(directory_probe)],check=True)
    events=[]
    def setup(command,*args):
        result=subprocess.run([str(worker),command,'--root',str(root),*map(str,args)],capture_output=True,text=True,timeout=300)
        events.extend(json.loads(line) for line in result.stdout.splitlines())
        (out/'setup-events.json').write_text(json.dumps(events,indent=2)+'\n')
        if result.returncode:raise RuntimeError('Setup failed: '+result.stdout)
    setup('install-runtime','--archive',a.archive.resolve(),'--sha256',a.sha256,'--version',a.version)
    setup('prepare')
    engine=root/'runtimes'/a.version
    env={'PATH':'/usr/bin:/bin:/usr/sbin:/sbin','HOME':str(root/'home'),'USER':'player',
         'TMPDIR':str(root/'tmp'),'WINEPREFIX':str(root/'environment'),'WINEARCH':'win64',
         'WINESERVER':str(engine/'bin/wineserver'),'WINELOADER':str(engine/'bin/wine'),
         'WINEDEBUG':'-all,err+all','WINEMSYNC':'1','WINEESYNC':'0','ROSETTA_ADVERTISE_AVX':'1',
         'WINE_SIMULATE_WRITECOPY':'1','CX_ACTIVE_GRAPHICS_BACKEND':'dxmt','CX_GRAPHICS_BACKEND':'dxmt',
         'CX_APPLEGPTK_LIBD3DSHARED_PATH':str(engine/'lib/external/libd3dshared.dylib'),
         'WINEDLLOVERRIDES':'d3d11,dxgi,d3d10core,winemetal=b;d3d12=',
         'DXMT_CANVAS_OVERLAY':'0','DXMT_CANVAS_DRAWABLES':'3','DXMT_LOG_LEVEL':'error',
         'DXMT_LOG_PATH':'none','DXMT_USE_DEFAULT_METAL_CACHE':'1',
         'DXMT_SHADER_CACHE_PATH':str(root/'cache/shaders')}
    try:
        with (out/'directory-probe.log').open('w') as log:
            directory_result=subprocess.run([str(engine/'bin/wine'),str(directory_probe)],env=env,cwd=root,
                                            stdout=log,stderr=subprocess.STDOUT,timeout=30)
        if directory_result.returncode:
            raise RuntimeError('Windows/native directory ABI qualification failed')
        with (out/'probe.log').open('w') as log:
            result=subprocess.run([str(engine/'bin/wine'),str(binary)],env=env,cwd=root,
                                  stdout=log,stderr=subprocess.STDOUT,timeout=120)
        lines=(out/'probe.log').read_text(errors='replace').splitlines()
        records=[json.loads(line) for line in lines if line.startswith('{"window_created"')]
        proof={'version':a.version,'archive_sha256':a.sha256,'outside_checkout':True,'path_contains_spaces':True,
               'fresh_environment':True,'probe_source_sha256':hashlib.sha256((ROOT/'tests/portable_runtime_probe.c').read_bytes()).hexdigest(),
               'exit_code':result.returncode,'renderer':records,'gameplay_performance_claim':False,
               'directory_boolean_probe_passed':True,
               'directory_probe_source_sha256':hashlib.sha256((ROOT/'tests/portable_directory_probe.c').read_bytes()).hexdigest()}
        (out/'result.json').write_text(json.dumps(proof,indent=2)+'\n')
        if result.returncode or len(records)!=1 or not records[0]['shader_readback']:
            raise RuntimeError('Renderer qualification failed; inspect the private probe log')
        print(json.dumps(proof,indent=2))
    finally:
        setup('stop')


if __name__=='__main__': main()
