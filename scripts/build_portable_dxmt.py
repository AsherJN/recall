#!/usr/bin/env python3
"""Reconstruct and build the accepted DXMT patch against freshly built Wine tools."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import shutil

import sign_pe

ROOT=Path(__file__).resolve().parents[1]
BASE='c5dc3a0dfe9108e667da43de871324bd298c9c02'
HEADERS='9df86f2341616ef1888ae59919feaa6d4fad693d'
# NVIDIA's NVAPI headers (MIT), a submodule of the base, for DXMT's NVAPI stand-in.
NVAPI='d08488fcc82eef313b0464db37d2955709691e94'
# MetalFX upscaling (1.3): DXMT's DLSS stand-in is signed with Recall's own certificate.
SIGNING=ROOT/'runtime/signing/recall-nvngx'


def run(*args,**kwargs):return subprocess.run([str(a) for a in args],check=True,**kwargs)


def build(work,tools,jobs,signing=SIGNING):
    source=work/'dxmt-source';builddir=work/'dxmt-build';install=work/'dxmt-install'
    if not source.exists():run('git','clone','--no-checkout','https://github.com/NerRobDog/dxmt',source)
    current=subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'],text=True).strip()
    if current!=BASE:run('git','-C',source,'checkout','--detach',BASE)
    run('git','-C',source,'submodule','update','--init','--recursive')
    current=subprocess.check_output(['git','-C',str(source/'include/native/directx'),'rev-parse','HEAD'],text=True).strip()
    if current!=HEADERS:raise ValueError('DirectX header identity mismatch')
    current=subprocess.check_output(['git','-C',str(source/'external/nvapi'),'rev-parse','HEAD'],text=True).strip()
    if current!=NVAPI:raise ValueError('NVAPI header identity mismatch')
    if not (signing/sign_pe.KEY).is_file():raise ValueError(f'No signing certificate in {signing} (scripts/sign_pe.py create-certificate)')
    patch=ROOT/'patches/dxmt-v1-private.patch'
    if hashlib.sha256(patch.read_bytes()).hexdigest()!='5afcbde9512381c37e975450d08f7fd3cef1e8755739f1f5b4ae8f1563de5199':raise ValueError('Accepted renderer patch changed')
    check=subprocess.run(['git','apply','--check',str(patch)],cwd=source,capture_output=True)
    if check.returncode==0:run('git','apply',patch,cwd=source)
    else:run('git','apply','--reverse','--check',patch,cwd=source)
    # v1.0: the play-tested performance work (DXMT replay branch e873a90) on top.
    performance=ROOT/'patches/dxmt-v1-performance.patch'
    if hashlib.sha256(performance.read_bytes()).hexdigest()!='b119feb670a3e2ffe656159118e99a75abc5b9a8097e77096c512a01b81861f2':raise ValueError('Accepted performance patch changed')
    check=subprocess.run(['git','apply','--check',str(performance)],cwd=source,capture_output=True)
    if check.returncode==0:run('git','apply',performance,cwd=source)
    else:run('git','apply','--reverse','--check',performance,cwd=source)
    portable_patch=ROOT/'patches/dxmt-portable-metal.patch'
    check=subprocess.run(['git','apply','--check',str(portable_patch)],cwd=source,capture_output=True)
    if check.returncode==0:run('git','apply',portable_patch,cwd=source)
    else:run('git','apply','--reverse','--check',portable_patch,cwd=source)
    # 1.3: DLSS on MetalFX. Direct3D 12 entry points and NVIDIA's failure codes in the DLSS
    # stand-in, and a d3d12.dll whose device only answers NVIDIA Streamline's setup questions.
    # MetalFX writes the DLSS output with shader-write usage (the 1.2 compression keeps it from
    # render targets the game never writes as UAVs); jittered motion vectors lose the jitter change
    # (a pass macOS compiles at run time); the chosen mode is the floor of the dynamic range; and the
    # stand-in logs what the game passes. Sharpening after MetalFX (d3d11.metalfxSharpness, Recall's
    # Sharpening setting) is a contrast-adaptive pass, also compiled at run time.
    metalfx=ROOT/'patches/dxmt-metalfx-upscaling.patch'
    if hashlib.sha256(metalfx.read_bytes()).hexdigest()!='87ab3e3a74a1c140653d6d66cda6576049472c8999afab68bccc866e48028b17':raise ValueError('Accepted MetalFX patch changed')
    check=subprocess.run(['git','apply','--check',str(metalfx)],cwd=source,capture_output=True)
    if check.returncode==0:run('git','apply',metalfx,cwd=source)
    else:run('git','apply','--reverse','--check',metalfx,cwd=source)
    wrapper=source/'portable_metal.py'
    shutil.copy2(ROOT/'scripts/portable_metal.py',wrapper);wrapper.chmod(0o755)
    env=os.environ.copy();env.pop('DESTDIR',None)
    env['PATH']=':'.join([str(tools/'llvm-mingw-20251216-ucrt-macos-universal/bin'),str(tools/'python/bin'),'/usr/bin','/bin','/usr/sbin','/sbin'])
    meson=tools/'python/bin/meson'
    setup=[meson,'setup',builddir,source,'--cross-file',source/'build-win64.txt','--buildtype=release',
           '--prefix',install,'--strip','-Dnative_llvm_path='+str(tools/'clang+llvm-15.0.7-x86_64-apple-darwin21.0'),
           '-Dwine_build_path='+str(work/'wine-build'),'-Denable_tests=false','-Denable_nvapi=true',
           '-Denable_nvngx=true','-Denable_d3d12=false']
    if (builddir/'meson-private/coredata.dat').exists():setup.append('--reconfigure')
    run(*setup,env=env)
    run(meson,'compile','-C',builddir,'-j',jobs,env=env)
    run(meson,'install','-C',builddir,'--no-rebuild',env=env)
    # NVIDIA's NGX loader loads only a signed core DLL; signing follows winebuild --builtin.
    nvngx=install/'x86_64-windows/nvngx.dll'
    sign_pe.sign(signing,nvngx,nvngx)
    if not sign_pe.check(nvngx,signing):raise ValueError('nvngx.dll signature check failed')
    files={str(p.relative_to(install)):hashlib.sha256(p.read_bytes()).hexdigest()
           for p in install.rglob('*') if p.is_file()}
    (work/'dxmt-build-proof.json').write_text(json.dumps({'base':BASE,'headers':HEADERS,
        'patch_sha256':hashlib.sha256(patch.read_bytes()).hexdigest(),'files':files,
        'performance_patch_sha256':hashlib.sha256(performance.read_bytes()).hexdigest(),
        'metalfx_patch_sha256':hashlib.sha256(metalfx.read_bytes()).hexdigest(),'nvapi':NVAPI,
        'nvngx_certificate_sha256':hashlib.sha256((signing/sign_pe.LEAF).read_bytes()).hexdigest(),
        'portable_metal_patch_sha256':hashlib.sha256(portable_patch.read_bytes()).hexdigest(),
        'portable_metal_wrapper_sha256':hashlib.sha256(wrapper.read_bytes()).hexdigest(),
        'developer_dir':env.get('DEVELOPER_DIR','xcode-select'),'sdkroot':env.get('SDKROOT','default'),
        'metal_cache':'used' if env.get('DXMT_METAL_CACHE') else 'none',
        'wine_build_tools':'fresh Phase 2 source build'},indent=2)+'\n')


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--workspace',type=Path,required=True)
    p.add_argument('--toolchains',type=Path,default=ROOT/'runtime/toolchains');p.add_argument('--jobs',type=int,choices=range(1,5),default=2)
    a=p.parse_args();build(a.workspace.resolve(),a.toolchains.resolve(),a.jobs)
