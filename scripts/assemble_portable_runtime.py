#!/usr/bin/env python3
"""Assemble/sign a versioned runtime from Phase 2 source-build outputs.

Does not copy installed developer runtimes or Windows prefixes. Apple support
files come from the separately verified original package and remain unmodified.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tarfile
from concurrent.futures import ThreadPoolExecutor

ROOT=Path(__file__).resolve().parents[1]
APPLE_SHA='5131e631eee8b542eadf48f4df9fd662d9aeeb59139137e0e6e14047dc434995'
MONO_SOURCE_SHA='128e335396689e466dff5e1aa0770a714dbe3d16397fc4ddbb8a80999c67323b'


def run(*args,**kwargs):return subprocess.run([str(a) for a in args],check=True,**kwargs)
def sha(p):
    with p.open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def macho(p):
    if p.is_symlink() or not p.is_file():return False
    with p.open('rb') as f:return f.read(4) in (b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xbe\xba\xfe\xca')
def links(p):
    text=subprocess.check_output(['otool','-L',str(p)],text=True)
    return [line.strip().split(' (')[0] for line in text.splitlines()[1:]]
def rpaths(p):
    text=subprocess.check_output(['otool','-l',str(p)],text=True)
    return re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset',text)
def copy(source,target):
    target.parent.mkdir(parents=True,exist_ok=True)
    if source.is_symlink():
        link=os.readlink(source)
        resolved=(target.parent/link).resolve()
        if os.path.isabs(link):raise ValueError('Absolute source link: '+str(source))
        target.symlink_to(link)
    else:shutil.copy2(source,target)


def assemble(work,version,identity):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}',version):raise ValueError('Invalid runtime version')
    for name in ['wine-build-proof.json','dxmt-build-proof.json','native-build-proof.json']:
        if not (work/name).is_file():raise ValueError('Complete the source builds first: '+name)
    dest=work/'artifacts'/version
    if dest.exists():raise ValueError('Use a new version; existing artifact is never overwritten')
    dest.mkdir(parents=True)
    wine=work/'install/usr/local'
    for name in ['bin/wine','bin/wineserver']:
        copy(wine/name,dest/name)
    for p in (wine/'lib/wine').rglob('*'):
        # Wine also needs .drv, .sys, .acm, .cpl, .ocx and legacy resources.
        # Exclude only developer import archives, never select by executable suffix.
        if p.is_file() and p.suffix!='.a':
            copy(p,dest/p.relative_to(wine))
    shutil.copytree(wine/'share/wine',dest/'share/wine',symlinks=True)
    for p in (work/'dxmt-install').rglob('*'):
        if p.is_file() and p.suffix in ('.dll','.so'):
            target=dest/'lib/wine'/p.relative_to(work/'dxmt-install')
            target.parent.mkdir(parents=True,exist_ok=True)
            if target.exists() or target.is_symlink():target.unlink()
            copy(p,target)
    copy(ROOT/'config/dxmt-source60-1200.conf',dest/'config/dxmt.conf')
    original=work/'apple-original'
    apple=original/'redist/lib/external/libd3dshared.dylib'
    if sha(apple)!=APPLE_SHA:raise ValueError('Apple support library changed')
    run('codesign','--verify','--strict','-R=anchor apple',apple)
    copy(apple,dest/'lib/external/libd3dshared.dylib')
    for name in ['License.rtf','Read Me.rtf','Acknowledgements.rtf']:
        copy(original/name,dest/'licenses/apple'/name)
    copy(work/'sources/wine/sources/wine/COPYING.LIB',dest/'licenses/Wine-LGPL-2.1')
    copy(ROOT/'licenses/PROJECT-MIT',dest/'licenses/PROJECT-MIT')
    for p in (ROOT/'licenses').iterdir():
        if p.is_file() and p.name!='PROJECT-MIT':copy(p,dest/'licenses'/p.name)
    compiler=ROOT/'runtime/toolchains/llvm-mingw-20251216-ucrt-macos-universal'
    copy(compiler/'LICENSE.TXT',dest/'licenses/compiler-runtime/LLVM-MinGW-LICENSE.txt')
    for architecture in ('x86_64','i686'):
        copy(compiler/(architecture+'-w64-mingw32/share/mingw32/COPYING'),
             dest/('licenses/compiler-runtime/MinGW-'+architecture+'-COPYING'))
    soju=work/'sources/soju/soju-3a350b32bf906dd2a509b18c642a5a2676de022a'
    copy(soju/'LICENSE',dest/'licenses/Soju-GPL-3.0')
    copy(work/'dxmt-source/include/native/directx/COPYING.MinGW-w64.txt',dest/'licenses/DirectX-Headers-COPYING')
    mono_source=work/'downloads/wine-mono-10.4.1-src.tar.xz'
    if not mono_source.exists():
        part=Path(str(mono_source)+'.part')
        run('/usr/bin/curl','-fL','--proto','=https','--proto-redir','=https','--retry','2','-o',part,
            'https://github.com/wine-mono/wine-mono/releases/download/wine-mono-10.4.1/wine-mono-10.4.1-src.tar.xz')
        if sha(part)!=MONO_SOURCE_SHA:raise ValueError('Wine Mono source hash mismatch')
        part.rename(mono_source)
    if sha(mono_source)!=MONO_SOURCE_SHA:raise ValueError('Wine Mono source hash mismatch')
    # Preserve upstream notices at their original paths, including transitive
    # projects. Keep the corresponding source archive for release delivery.
    with tarfile.open(mono_source) as tar:
        for entry in tar:
            path=Path(entry.name)
            if path.is_absolute() or '..' in path.parts:raise ValueError('Unsafe Mono source path')
            if entry.isfile() and (path.name.upper().startswith(('COPYING','LICENSE','NOTICE','AUTHORS','THIRDPARTYNOTICES'))
                                  or 'ICSharpCode.SharpZipLib/README' in entry.name):
                target=dest/'licenses/wine-mono'/path
                target.parent.mkdir(parents=True,exist_ok=True)
                target.write_bytes(tar.extractfile(entry).read())
    shutil.copytree(work/'clean-deps/licenses',dest/'licenses/native')
    for name in ['FTL.TXT','GPLv2.TXT']:
        copy(work/'sources/freetype/freetype-2.13.3/docs'/name,dest/'licenses/freetype'/name)
    # Resolve only native libraries referenced by this runtime, plus three
    # explicitly dlopened dependencies. No unused graphical backend is copied.
    available={p.name:p for p in (work/'clean-deps/lib').glob('*.dylib')}
    available['libfreetype.6.dylib']=work/'deps/lib/libfreetype.6.dylib'
    native=[p for p in dest.rglob('*') if macho(p) and p!=dest/'lib/external/libd3dshared.dylib']
    needed={'libgnutls.30.dylib','libfreetype.6.dylib','libMoltenVK.dylib'};chosen={}
    for p in native:
        for dep in links(p):
            if Path(dep).name in available:needed.add(Path(dep).name)
    while needed:
        name=needed.pop()
        if name in chosen:continue
        p=available[name];chosen[name]=sha(p);shutil.copy2(p.resolve(),dest/'lib'/name)
        for dep in links(p):
            base=Path(dep).name
            if base in available and base!=name:needed.add(base)
    native=[p for p in dest.rglob('*') if macho(p) and p!=dest/'lib/external/libd3dshared.dylib']
    strip=ROOT/'runtime/toolchains/llvm-mingw-20251216-ucrt-macos-universal/bin/llvm-strip'
    def strip_debug(p):
        run(strip,'--strip-debug',p,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    # Managed Mono assemblies are PE too; only strip built Wine/DXMT modules.
    pe=[p for p in (dest/'lib/wine').rglob('*') if p.is_file() and not p.is_symlink()
        and p.suffix in ('.exe','.dll','.drv','.sys','.acm','.cpl','.ocx','.ax')]
    with ThreadPoolExecutor(max_workers=4) as pool:list(pool.map(strip_debug,pe))
    for p in native:
        # Include the dependency closure copied above, not just Wine/DXMT.
        # Preserve exported symbols needed by Wine and dlopen.
        run('/usr/bin/strip','-S','-x',p,stderr=subprocess.DEVNULL)
        for dep in links(p):
            if dep.startswith(('/usr/lib/','/System/Library/','@loader_path/','@rpath/','@executable_path/')):continue
            name=Path(dep).name
            if name=='libpcap.dylib':
                run('install_name_tool','-change',dep,'/usr/lib/libpcap.A.dylib',p,stderr=subprocess.DEVNULL)
            elif name in chosen:run('install_name_tool','-change',dep,'@rpath/'+name,p,stderr=subprocess.DEVNULL)
            elif name in ('ntdll.so','win32u.so'):
                run('install_name_tool','-change',dep,'@rpath/'+name,p,stderr=subprocess.DEVNULL)
            else:raise ValueError('Unresolved non-system dependency: '+dep)
        if p.suffix=='.dylib':run('install_name_tool','-id','@rpath/'+p.name,p,stderr=subprocess.DEVNULL)
        desired=['@loader_path']
        if p.parent==dest/'bin':desired+=['@loader_path/../lib','@loader_path/../lib/wine/x86_64-unix']
        elif (dest/'lib/wine') in p.parents:desired+=['@loader_path/../..']
        old=rpaths(p)
        for path in old:
            if path not in desired:run('install_name_tool','-delete_rpath',path,p,stderr=subprocess.DEVNULL)
        for path in desired:
            if path not in old:run('install_name_tool','-add_rpath',path,p,stderr=subprocess.DEVNULL)
    private_paths=[value.encode(encoding) for value in (str(ROOT),str(work),'/opt/homebrew/')
                   for encoding in ('utf-8','utf-16-le')]
    for p in [* (dest/'bin').rglob('*'), * (dest/'lib').rglob('*')]:
        if p.is_file() and not p.is_symlink():
            data=p.read_bytes()
            if any(value in data for value in private_paths):
                raise ValueError('Development path remains in payload: '+str(p.relative_to(dest)))
            for encoding in ('utf-8','utf-16-le'):
                needle='/Users/'.encode(encoding)
                upstream='/Users/runner/work/llvm-mingw/'.encode(encoding)
                start=0
                while (start:=data.find(needle,start))>=0:
                    # Public CI path in the pinned LLVM-MinGW libc++ ABI
                    # library, not this project's developer/account data.
                    if not data.startswith(upstream,start):
                        raise ValueError('Unrecognized home path in payload: '+str(p.relative_to(dest)))
                    start+=len(needle)
    entitlements=work/'wine-entitlements.plist'
    entitlements.write_bytes(plistlib.dumps({name:True for name in [
        'com.apple.security.cs.allow-jit','com.apple.security.cs.allow-unsigned-executable-memory',
        'com.apple.security.cs.disable-executable-page-protection','com.apple.security.cs.disable-library-validation']}))
    for index,p in enumerate(sorted(native)):
        args=['codesign','--force','--options','runtime','--timestamp','--sign',identity]
        if p.name in ('wine','wineserver'):args+=['--entitlements',entitlements]
        run(*args,p,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        run('codesign','--verify','--strict',p,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if index%10==0:print('Signed native components:',index+1,'of',len(native),flush=True)
    run('codesign','--verify','--strict','-R=anchor apple',dest/'lib/external/libd3dshared.dylib')
    if sha(dest/'lib/external/libd3dshared.dylib')!=APPLE_SHA:raise ValueError('Apple component must remain unmodified')
    files={}
    for p in sorted(dest.rglob('*')):
        if p.is_symlink():
            if not p.resolve().is_relative_to(dest.resolve()):raise ValueError('Runtime symlink escapes payload')
            files[str(p.relative_to(dest))]={'symlink':os.readlink(p)}
        elif p.is_file():files[str(p.relative_to(dest))]={'sha256':sha(p),'bytes':p.stat().st_size}
    manifest={'schema':1,'version':version,'minimum_macos':'26.0','files':files,
              'source_builds':{n:json.loads((work/n).read_text()) for n in ['wine-build-proof.json','dxmt-build-proof.json','native-build-proof.json']},
              'native_dependency_inputs':chosen,'apple_component_unmodified':True,
              'development_path_scan_passed':True,
              'wine_mono_corresponding_source_sha256':MONO_SOURCE_SHA,
              'status':'private_phase_2_candidate; consumer release review and QA still required'}
    (dest/'runtime.json').write_text(json.dumps(manifest,indent=2)+'\n')
    archive=Path(str(dest)+'.tar.gz')
    with tarfile.open(archive,'w:gz',compresslevel=3) as tar:
        for p in sorted(dest.rglob('*')):tar.add(p,arcname=str(p.relative_to(dest)),recursive=False)
    proof={'version':version,'archive_sha256':sha(archive),'archive_bytes':archive.stat().st_size,
           'unpacked_file_bytes':sum(v.get('bytes',0) for v in files.values()),'files':len(files),
           'signed_native_components':len(native),'dependency_names':sorted(chosen)}
    archive.with_suffix('.json').write_text(json.dumps(proof,indent=2)+'\n')
    print(json.dumps(proof,indent=2))


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--workspace',type=Path,required=True)
    p.add_argument('--version',required=True);p.add_argument('--identity',required=True)
    a=p.parse_args();assemble(a.workspace.resolve(),a.version,a.identity)
