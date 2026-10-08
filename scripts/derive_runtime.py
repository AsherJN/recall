#!/usr/bin/env python3
"""Derive a runtime version from an assembled one by replacing only its window driver.

Developer tool. assemble_portable_runtime.py assembles from the Phase 2 install
tree, which is not kept, and recreating it means a full Wine build. When only
winemac.so changes, this gives the same result:
- an APFS clone of the base artifact with the new driver, signed the way the
  assembler signs native components;
- a manifest that records the replacement;
- a new archive and proof beside the base archive.

The driver must come from scripts/build_mouselook_driver.py, which builds it
with the Phase 2 toolchain and packages it as the assembler does (its --base
mode reproduces the shipped driver byte for byte). Every other file stays
byte-identical to the base, which this script verifies.

--components DXMT_WORKSPACE (v1.0) replaces the Wine server, ntdll, win32u and window driver
built by scripts/build_wine_native.py, the DXMT build of scripts/build_portable_dxmt.py
in that workspace and config/dxmt.conf (the contract's renderer profile), after checking
each build against its manifest, patch and base file; native files are signed as the
assembler signs them.

--native winemac (1.0 and later) replaces only the named build_wine_native.py
components in a runtime that already ships earlier builds of the same experiments,
after checking that each was built against the file the derivation chain started from.

--repackage copies the base under a new version without replacing anything.
Archives hold only runtime.json and the files it lists, so a folder that
Finder or anything else added files to still packages exactly the manifest.

--native ntdll --game-mode (1.1 and later) also adds the game app that lets macOS turn
Game Mode on for Overwatch (scripts/game_mode_app.py), made from the base's loader.

--minimum-macos 15.0 (1.1 and later) lowers the minimum macOS stamped in every
Mach-O file that requires a newer one, re-signs it with its original identifier and
entitlements, and checks that, unsigned, it differs from the base only in that
field. The other modes stamp the files they replace with the base's minimum.

--relicense (1.1) replaces the project's MIT license in licenses/ with the Apache 2.0
license and NOTICE from this tree; text files only, so it needs no signing identity.

--controllers (1.2) replaces the controller bus with build_wine_native.py's winebus,
built with SDL2, and adds that SDL2 library (build_portable_dependencies.py --only sdl2,
packaged and signed as the assembler packages a dependency) and its license.

--microphone (1.3) re-signs the Wine loader and server with the microphone entitlement
and makes the game app again from that loader; unsigned, every file stays byte-identical.

--metalfx DXMT_WORKSPACE (1.3) replaces the base's DXMT with the build_portable_dxmt.py build
in that workspace (MetalFX upscaling: dxmt-metalfx-upscaling.patch), replaces Wine's d3d12.dll
with DXMT's stand-in and adds DXMT's signed DLSS stand-in (nvngx.dll), its NVAPI stand-in
(nvapi64.dll) and NVAPI's MIT license. Launches disable all three unless upscaling is on.
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
import tempfile

import game_mode_app
import sign_pe

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / 'runtime/phase-2/artifacts'
DRIVER = 'lib/wine/x86_64-unix/winemac.so'
BUILD = ROOT / 'runtime/build/winemac-mouselook/current'
PATCH = ROOT / 'patches/wine-mouselook.patch'


def sha(path):
    with Path(path).open('rb') as f:
        return hashlib.file_digest(f, 'sha256').hexdigest()


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


LC_VERSION_MIN_MACOSX, LC_BUILD_VERSION, PLATFORM_MACOS = 0x24, 0x32, 1


def parse_macos(text):
    """'15.0' -> the Mach-O encoding of a version (xxxx.yy.zz in nibbles)."""
    if not re.fullmatch(r'\d{1,4}(\.\d{1,3}){0,2}', text):
        raise ValueError('Invalid macOS version: ' + text)
    major, minor, patch = ([int(p) for p in text.split('.')] + [0, 0])[:3]
    if minor > 255 or patch > 255:
        raise ValueError('Invalid macOS version: ' + text)
    return major << 16 | minor << 8 | patch


def format_macos(value):
    text = f'{value >> 16}.{value >> 8 & 0xff}'
    return text + (f'.{value & 0xff}' if value & 0xff else '')


def minimum_field(read):
    """(offset, version) of the minimum-macOS field of a 64-bit Mach-O, or None for any other
    file. READ(n) returns the next n bytes of the file from its start."""
    header = read(32)
    if header[:4] == b'\xca\xfe\xba\xbe' and int.from_bytes(header[4:8], 'big') < 20:
        raise ValueError('Universal Mach-O files are not supported')
    if header[:4] in (b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xce', b'\xfe\xed\xfa\xcf'):
        raise ValueError('Only 64-bit little-endian Mach-O files are supported')
    if header[:4] != b'\xcf\xfa\xed\xfe':
        return None
    commands = header + read(int.from_bytes(header[20:24], 'little'))
    offset = 32
    for _ in range(int.from_bytes(header[16:20], 'little')):
        cmd, size = (int.from_bytes(commands[offset + i:offset + i + 4], 'little') for i in (0, 4))
        if cmd == LC_BUILD_VERSION:  # cmd, cmdsize, platform, minos, sdk, ntools
            if int.from_bytes(commands[offset + 8:offset + 12], 'little') != PLATFORM_MACOS:
                raise ValueError('Mach-O file built for another platform')
            return offset + 12, int.from_bytes(commands[offset + 12:offset + 16], 'little')
        if cmd == LC_VERSION_MIN_MACOSX:  # cmd, cmdsize, version, sdk
            return offset + 8, int.from_bytes(commands[offset + 8:offset + 12], 'little')
        offset += size
    raise ValueError('Mach-O file without a minimum macOS')


def file_minimum(path):
    with Path(path).open('rb') as f:
        return minimum_field(f.read)


def restamp(path, minimum):
    """Lower a Mach-O file's minimum macOS to MINIMUM in place (it must be re-signed);
    return the version it required before, or None when nothing changed."""
    field = file_minimum(path)
    if not field or field[1] <= minimum:
        return None
    with Path(path).open('r+b') as f:
        f.seek(field[0])
        f.write(minimum.to_bytes(4, 'little'))
    return field[1]


def signing_of(path):
    """Identifier and entitlements of a native file signed as the assembler signs them."""
    info = subprocess.run(['codesign', '-dvv', str(path)], capture_output=True, text=True).stderr
    identifier = re.search(r'^Identifier=(.+)$', info, re.M)
    if not identifier or 'Authority=Developer ID Application' not in info or '(runtime)' not in info:
        raise ValueError(f'{Path(path).name} is not signed with Developer ID and the hardened runtime')
    xml = subprocess.run(['codesign', '-d', '--xml', '--entitlements', '-', str(path)], capture_output=True).stdout
    return identifier.group(1), plistlib.loads(xml) if xml.strip() else None


def sign_like(target, original, identity):
    """Sign TARGET as ORIGINAL is signed: same identifier, entitlements and hardened runtime."""
    identifier, entitlements = signing_of(original)
    args = ['codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', identity, '--identifier', identifier]
    with tempfile.TemporaryDirectory() as folder:
        if entitlements is not None:
            plist = Path(folder) / 'entitlements.plist'
            plist.write_bytes(plistlib.dumps(entitlements))
            args += ['--entitlements', plist]
        run(*args, target, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run('codesign', '--verify', '--strict', target)
    if signing_of(target) != (identifier, entitlements):
        raise ValueError(f'{Path(target).name} is signed differently from the base file')


def same_apart_from_minimum(original, restamped):
    """True when the two files, unsigned, differ only in the minimum-macOS field."""
    with tempfile.TemporaryDirectory() as folder:
        copies = [Path(folder) / 'a', Path(folder) / 'b']
        for source, copy in zip((original, restamped), copies):
            shutil.copy2(source, copy)
            run('codesign', '--remove-signature', copy)
        a, b = (c.read_bytes() for c in copies)
    offset = file_minimum(original)[0]
    return len(a) == len(b) and a[:offset] == b[:offset] and a[offset + 4:] == b[offset + 4:]


def archive_minimum(archive):
    """The newest minimum macOS any Mach-O file in a runtime archive requires, and the
    minimum its manifest declares."""
    newest, declared = 0, None
    with tarfile.open(archive, 'r|gz') as tar:
        for member in tar:
            if not member.isfile():
                continue
            f = tar.extractfile(member)
            if member.name == 'runtime.json':
                declared = json.load(f).get('minimum_macos')
                continue
            field = minimum_field(f.read)
            if field:
                newest = max(newest, field[1])
    return newest, declared


def check_driver(path):
    """Linkage and payload rules of assemble_portable_runtime.py for a lib/wine module."""
    links = subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()[1:]
    for dep in (line.strip().split(' (')[0] for line in links):
        if not dep.startswith(('/usr/lib/', '/System/Library/', '@rpath/', '@loader_path/')):
            raise ValueError('Unexpected dependency in driver: ' + dep)
    rpaths = re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset',
                        subprocess.check_output(['otool', '-l', str(path)], text=True))
    if rpaths != ['@loader_path', '@loader_path/../..']:
        raise ValueError('Driver rpaths differ from the assembler: ' + ', '.join(rpaths))
    data = path.read_bytes()
    for value in (str(ROOT), '/opt/homebrew/', '/Users/'):
        for encoding in ('utf-8', 'utf-16-le'):
            if value.encode(encoding) in data:
                raise ValueError('Development path in driver: ' + value)


def tree(root):
    entries = {}
    for p in sorted(root.rglob('*')):
        key = str(p.relative_to(root))
        if p.is_symlink():
            entries[key] = ('link', os.readlink(p))
        elif p.is_file():
            entries[key] = ('file', sha(p))
    return entries


def check_archive(archive):
    """Refuse an archive whose files are not exactly runtime.json and what it lists; return the manifest."""
    with tarfile.open(archive) as tar:
        members = tar.getmembers()
        manifest = json.load(tar.extractfile('runtime.json'))
    present = {m.name for m in members if not m.isdir()}
    listed = set(manifest['files'])
    unlisted, missing = sorted(present - listed - {'runtime.json'}), sorted(listed - present)
    if unlisted or missing:
        raise ValueError(f'{archive}: files not in its manifest {unlisted}, listed files missing {missing}')
    return manifest


def write_archive(runtime):
    """Archive every folder (some upstream ones are empty), runtime.json and the files it lists."""
    names = ['runtime.json', *json.loads((runtime / 'runtime.json').read_text())['files']]
    folders = {str(p.relative_to(runtime)) for p in runtime.rglob('*') if p.is_dir() and not p.is_symlink()}
    archive = Path(str(runtime) + '.tar.gz')
    with tarfile.open(archive, 'w:gz', compresslevel=3) as tar:
        for name in sorted(folders | set(names)):  # a folder sorts before its contents
            tar.add(runtime / name, arcname=name, recursive=False)
    check_archive(archive)
    return archive


def repackage(base_version, version):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}', version):
        raise ValueError('Invalid runtime version')
    base, dest = ARTIFACTS / base_version, ARTIFACTS / version
    if dest.exists() or Path(str(dest) + '.tar.gz').exists():
        raise ValueError('Use a new version; existing artifact is never overwritten')
    manifest = json.loads((base / 'runtime.json').read_text())
    if manifest['version'] != base_version:
        raise ValueError('The base artifact names a different version')

    run('/bin/cp', '-Rc', base, dest)
    manifest['version'] = version
    manifest['repackaged_from'] = {'version': base_version, 'archive_sha256': sha(str(base) + '.tar.gz')}
    (dest / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')

    before, after = tree(base), tree(dest)
    changed = sorted(k for k in manifest['files'] if k not in after or before.get(k) != after.get(k))
    if changed:
        raise ValueError('Listed files differ from the base runtime: ' + ', '.join(changed))
    for extra in sorted(set(after) - set(manifest['files']) - {'runtime.json'}):
        print('Not archived (not in the manifest): ' + extra)

    archive = write_archive(dest)
    base_proof = json.loads(Path(str(base) + '.tar.json').read_text())
    proof = dict(base_proof, version=version, archive_sha256=sha(archive), archive_bytes=archive.stat().st_size,
                 repackaged_from=base_version)
    archive.with_suffix('.json').write_text(json.dumps(proof, indent=2) + '\n')
    print(json.dumps(proof, indent=2))


def derive(base_version, version, identity):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}', version):
        raise ValueError('Invalid runtime version')
    base, dest = ARTIFACTS / base_version, ARTIFACTS / version
    if dest.exists() or Path(str(dest) + '.tar.gz').exists():
        raise ValueError('Use a new version; existing artifact is never overwritten')
    build = json.loads((BUILD / 'manifest.json').read_text())
    driver = BUILD / 'winemac.so'
    if build['driver_sha256'] != sha(driver) or build['patch_sha256'] != sha(PATCH):
        raise ValueError('Rebuild the driver: its build manifest does not match the driver or the patch')
    manifest = json.loads((base / 'runtime.json').read_text())
    if manifest['version'] != base_version or manifest['files'][DRIVER]['sha256'] != build['base_driver_sha256']:
        raise ValueError('The driver was built against a different base runtime')

    run('/bin/cp', '-Rc', base, dest)  # APFS clone: only replaced files take space
    target = dest / DRIVER
    target.unlink()
    shutil.copy2(driver, target)
    check_driver(target)
    restamp(target, parse_macos(manifest.get('minimum_macos', '26.0')))
    run('codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', identity, target,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run('codesign', '--verify', '--strict', target)

    manifest['version'] = version
    manifest['files'][DRIVER] = {'sha256': sha(target), 'bytes': target.stat().st_size}
    manifest['derived_from'] = {
        'version': base_version, 'archive_sha256': sha(str(base) + '.tar.gz'),
        'replaced': {DRIVER: {'build_sha256': build['driver_sha256'], 'built_by': 'scripts/build_mouselook_driver.py',
                              'patch': 'patches/wine-mouselook.patch', 'patch_sha256': build['patch_sha256'],
                              'base_sources': build['base_sources']}}}
    (dest / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')

    before, after = tree(base), tree(dest)
    changed = sorted(k for k in before.keys() | after.keys() if before.get(k) != after.get(k))
    if changed != sorted([DRIVER, 'runtime.json']):
        raise ValueError('Unexpected differences from the base runtime: ' + ', '.join(changed))

    archive = write_archive(dest)
    base_proof = json.loads(Path(str(base) + '.tar.json').read_text())
    proof = dict(base_proof, version=version, archive_sha256=sha(archive), archive_bytes=archive.stat().st_size,
                 unpacked_file_bytes=sum(v.get('bytes', 0) for v in manifest['files'].values()),
                 files=len(manifest['files']), derived_from=base_version, replaced=[DRIVER])
    archive.with_suffix('.json').write_text(json.dumps(proof, indent=2) + '\n')
    print(json.dumps(proof, indent=2))


NATIVE = ROOT / 'runtime/build/wine-native'
NATIVE_FILES = {'wineserver': 'bin/wineserver', 'ntdll': 'lib/wine/x86_64-unix/ntdll.so',
                'win32u': 'lib/wine/x86_64-unix/win32u.so', 'winemac': 'lib/wine/x86_64-unix/winemac.so'}
DXMT_FILES = {'lib/wine/x86_64-windows/d3d11.dll': 'x86_64-windows/d3d11.dll',
              'lib/wine/x86_64-windows/dxgi.dll': 'x86_64-windows/dxgi.dll',
              'lib/wine/x86_64-windows/d3d10core.dll': 'x86_64-windows/d3d10core.dll',
              'lib/wine/x86_64-windows/winemetal.dll': 'x86_64-windows/winemetal.dll',
              'lib/wine/x86_64-unix/winemetal.so': 'x86_64-unix/winemetal.so'}
PROFILE = 'config/dxmt.conf'
MICROPHONE = 'com.apple.security.device.audio-input'
ENTITLEMENTS = ['com.apple.security.cs.allow-jit', 'com.apple.security.cs.allow-unsigned-executable-memory',
                'com.apple.security.cs.disable-executable-page-protection', 'com.apple.security.cs.disable-library-validation',
                MICROPHONE]


def check_native(path, shipped):
    """A replacement Mach-O keeps the shipped file's rpaths and links only system or runtime libraries."""
    def rpaths_of(p):
        return re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset',
                          subprocess.check_output(['otool', '-l', str(p)], text=True))
    links = subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()[1:]
    for dep in (line.strip().split(' (')[0] for line in links):
        if not dep.startswith(('/usr/lib/', '/System/Library/', '@rpath/', '@loader_path/')):
            raise ValueError(f'Unexpected dependency in {path.name}: {dep}')
    if rpaths_of(path) != rpaths_of(shipped):
        raise ValueError(f'{path.name} rpaths differ from the shipped file')


def package_like_assembler(path):
    """assemble_portable_runtime.py's treatment of a built DXMT module: debug info
    stripped, and for the Unix library the assembler's rpaths."""
    if path.suffix == '.dll':
        run(ROOT / 'runtime/toolchains/llvm-mingw-20251216-ucrt-macos-universal/bin/llvm-strip', '--strip-debug', path,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return
    run('/usr/bin/strip', '-S', '-x', path, stderr=subprocess.DEVNULL)
    old = re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset',
                     subprocess.check_output(['otool', '-l', str(path)], text=True))
    desired = ['@loader_path', '@loader_path/../..']
    for entry in old:
        if entry not in desired:
            run('install_name_tool', '-delete_rpath', entry, path, stderr=subprocess.DEVNULL)
    for entry in desired:
        if entry not in old:
            run('install_name_tool', '-add_rpath', entry, path, stderr=subprocess.DEVNULL)


def check_paths(path):
    """No development or account paths; the pinned LLVM-MinGW CI path is public (as in the assembler)."""
    data = path.read_bytes()
    for value in (str(ROOT), str(Path.home()), '/opt/homebrew/'):
        for encoding in ('utf-8', 'utf-16-le'):
            if value.encode(encoding) in data:
                raise ValueError(f'Development path in {path.name}: {value}')
    for encoding in ('utf-8', 'utf-16-le'):
        needle, upstream, start = '/Users/'.encode(encoding), '/Users/runner/work/llvm-mingw/'.encode(encoding), 0
        while (start := data.find(needle, start)) >= 0:
            if not data.startswith(upstream, start):
                raise ValueError(f'Unrecognized home path in {path.name}')
            start += len(needle)


def derive_components(base_version, version, identity, dxmt_workspace):
    """v1.0: the play-tested Wine components, DXMT build and renderer profile replace the base's."""
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}', version):
        raise ValueError('Invalid runtime version')
    base, dest = ARTIFACTS / base_version, ARTIFACTS / version
    if dest.exists() or Path(str(dest) + '.tar.gz').exists():
        raise ValueError('Use a new version; existing artifact is never overwritten')
    manifest = json.loads((base / 'runtime.json').read_text())
    if manifest['version'] != base_version:
        raise ValueError('The base artifact names a different version')
    sources, replaced = {}, {}
    for component, relative in NATIVE_FILES.items():
        build = json.loads((NATIVE / component / 'current/manifest.json').read_text())
        built = NATIVE / component / 'current' / Path(relative).name
        if build['sha256'] != sha(built) or build['patch_sha256'] != sha(ROOT / build['patch']):
            raise ValueError(f'Rebuild {component}: its build manifest does not match the file or the patch')
        if build['base_sha256'] != manifest['files'][relative]['sha256']:
            raise ValueError(f'{component} was built against a different base runtime')
        sources[relative] = built
        replaced[relative] = {'build_sha256': build['sha256'], 'built_by': f'scripts/build_wine_native.py {component}',
                              'patch': build['patch'], 'patch_sha256': build['patch_sha256']}
    proof = json.loads((dxmt_workspace / 'dxmt-build-proof.json').read_text())
    install = dxmt_workspace / 'dxmt-install'
    for relative, built in DXMT_FILES.items():
        if proof['files'][built] != sha(install / built):
            raise ValueError(f'DXMT build proof does not match {built}')
        sources[relative] = install / built
        replaced[relative] = {'build_sha256': proof['files'][built], 'built_by': 'scripts/build_portable_dxmt.py',
                              'patches': {name: proof[key] for name, key in (
                                  ('patches/dxmt-v1-private.patch', 'patch_sha256'),
                                  ('patches/dxmt-v1-performance.patch', 'performance_patch_sha256'),
                                  ('patches/dxmt-portable-metal.patch', 'portable_metal_patch_sha256'))}}
    for name, key in (('dxmt-v1-private.patch', 'patch_sha256'), ('dxmt-v1-performance.patch', 'performance_patch_sha256'),
                      ('dxmt-portable-metal.patch', 'portable_metal_patch_sha256')):
        if proof[key] != sha(ROOT / 'patches' / name):
            raise ValueError(f'Rebuild DXMT: patches/{name} changed since the build')
    contract = json.loads((ROOT / 'docs/candidate-parity-contract.json').read_text())
    profile = ROOT / contract['renderer_profile']
    if sha(profile) != contract['renderer_profile_sha256']:
        raise ValueError('The renderer profile differs from the candidate contract')
    sources[PROFILE] = profile
    replaced[PROFILE] = {'sha256': sha(profile), 'from': contract['renderer_profile']}

    replace_files(base, dest, base_version, version, identity, manifest, sources, replaced)


def package_dependency(path):
    """assemble_portable_runtime.py's treatment of a native library it copies into lib/: symbols
    stripped, identified as @rpath/<name>, rpath @loader_path, system dependencies only."""
    run('/usr/bin/strip', '-S', '-x', path, stderr=subprocess.DEVNULL)
    links = subprocess.check_output(['otool', '-L', str(path)], text=True).splitlines()[2:]  # [1] is its own id
    for dep in (line.strip().split(' (')[0] for line in links):
        if not dep.startswith(('/usr/lib/', '/System/Library/')):
            raise ValueError(f'Unexpected dependency in {path.name}: {dep}')
    run('install_name_tool', '-id', '@rpath/' + path.name, path, stderr=subprocess.DEVNULL)
    old = re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset',
                     subprocess.check_output(['otool', '-l', str(path)], text=True))
    for entry in old:
        if entry != '@loader_path':
            run('install_name_tool', '-delete_rpath', entry, path, stderr=subprocess.DEVNULL)
    if '@loader_path' not in old:
        run('install_name_tool', '-add_rpath', '@loader_path', path, stderr=subprocess.DEVNULL)


def replace_files(base, dest, base_version, version, identity, manifest, sources, replaced, game_mode=False,
                  additions=None):
    """Clone the base, put each source at its relative path (native files signed as the
    assembler signs them), add the game app if asked and each of ADDITIONS ({relative:
    (source, record)}: a library packaged as the assembler packages a dependency, or a
    text file), record the changes and archive; nothing else may differ."""
    additions = additions or {}
    if game_mode and game_mode_app.BUNDLE in {str(Path(f).parent.parent.parent) for f in manifest['files']}:
        raise ValueError(f'{base_version} already has the game app')
    if any(relative in manifest['files'] for relative in additions):
        raise ValueError(f'{base_version} already has ' + ', '.join(r for r in additions if r in manifest['files']))
    run('/bin/cp', '-Rc', base, dest)  # APFS clone: only replaced files take space
    entitlements = dest.parent / f'{version}-entitlements.plist'
    entitlements.write_bytes(plistlib.dumps({name: True for name in ENTITLEMENTS}))
    try:
        for relative, source in sources.items():
            target = dest / relative
            target.unlink()
            shutil.copy2(source, target)
            if relative in DXMT_FILES:
                package_like_assembler(target)
            if relative == PROFILE or target.suffix == '.dll':
                check_paths(target)
                continue
            check_native(target, base / relative)
            check_paths(target)
            restamp(target, parse_macos(manifest.get('minimum_macos', '26.0')))
            args = ['codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', identity]
            if target.name in ('wine', 'wineserver'):
                args += ['--entitlements', entitlements]
            run(*args, target, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            run('codesign', '--verify', '--strict', target)
    finally:
        entitlements.unlink(missing_ok=True)
    for relative, (source, _) in additions.items():
        target = dest / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        if target.suffix != '.dylib':
            target.chmod(0o644)
            continue
        target.chmod(0o755)
        package_dependency(target)
        check_paths(target)
        restamp(target, parse_macos(manifest.get('minimum_macos', '26.0')))
        run('codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', identity, target,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        run('codesign', '--verify', '--strict', target)
    # Made after the replacements, from the loader the runtime ships (signed as it is).
    added = game_mode_app.make(dest, manifest.get('minimum_macos', '26.0'), identity) if game_mode else []

    manifest['version'] = version
    for relative in [*sources, *added, *additions]:
        manifest['files'][relative] = {'sha256': sha(dest / relative), 'bytes': (dest / relative).stat().st_size}
    manifest['derived_from'] = {'version': base_version, 'archive_sha256': sha(str(base) + '.tar.gz'), 'replaced': replaced}
    if added:
        manifest['derived_from']['added'] = {relative: {'built_by': 'scripts/game_mode_app.py',
                                                        'from': game_mode_app.LOADER} for relative in added}
    if additions:
        manifest['derived_from'].setdefault('added', {}).update({r: record for r, (_, record) in additions.items()})
    added = [*added, *additions]
    (dest / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')

    before, after = tree(base), tree(dest)
    changed = sorted(k for k in before.keys() | after.keys() if before.get(k) != after.get(k))
    if changed != sorted([*sources, *added, 'runtime.json']):
        raise ValueError('Unexpected differences from the base runtime: ' + ', '.join(changed))

    archive = write_archive(dest)
    base_proof = json.loads(Path(str(base) + '.tar.json').read_text())
    for key in ('restamped', 'removed', 'added', 'repackaged_from', 'resigned', 'entitlement_added'):
        base_proof.pop(key, None)  # the base's own records, not this derivation's
    result = dict(base_proof, version=version, archive_sha256=sha(archive), archive_bytes=archive.stat().st_size,
                  unpacked_file_bytes=sum(v.get('bytes', 0) for v in manifest['files'].values()),
                  files=len(manifest['files']), derived_from=base_version, replaced=sorted(sources))
    if added:
        result['added'] = added
    libraries = [Path(r).name for r in additions if r.endswith('.dylib')]
    if libraries and 'dependency_names' in result:
        result['dependency_names'] = sorted({*result['dependency_names'], *libraries})
        result['signed_native_components'] = result.get('signed_native_components', 0) + len(libraries)
    archive.with_suffix('.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


OLD_PROJECT_LICENSE = 'licenses/PROJECT-MIT'
PROJECT_LICENSES = ('licenses/PROJECT-APACHE-2.0', 'licenses/PROJECT-NOTICE')


def relicense(base_version, version):
    """1.1: the project's own license in licenses/ becomes Apache 2.0 with its NOTICE, taken
    from this tree. Text files only, so nothing is signed; nothing else may differ."""
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}', version):
        raise ValueError('Invalid runtime version')
    base, dest = ARTIFACTS / base_version, ARTIFACTS / version
    if dest.exists() or Path(str(dest) + '.tar.gz').exists():
        raise ValueError('Use a new version; existing artifact is never overwritten')
    manifest = json.loads((base / 'runtime.json').read_text())
    if manifest['version'] != base_version:
        raise ValueError('The base artifact names a different version')
    if OLD_PROJECT_LICENSE not in manifest['files'] or any(f in manifest['files'] for f in PROJECT_LICENSES):
        raise ValueError(f'{base_version} does not carry the MIT project license alone')

    run('/bin/cp', '-Rc', base, dest)  # APFS clone: only the license files take space
    (dest / OLD_PROJECT_LICENSE).unlink()
    for relative in PROJECT_LICENSES:
        shutil.copyfile(ROOT / relative, dest / relative)
        (dest / relative).chmod(0o644)

    manifest['version'] = version
    removed = {OLD_PROJECT_LICENSE: manifest['files'].pop(OLD_PROJECT_LICENSE)}
    for relative in PROJECT_LICENSES:
        manifest['files'][relative] = {'sha256': sha(dest / relative), 'bytes': (dest / relative).stat().st_size}
    manifest['derived_from'] = {'version': base_version, 'archive_sha256': sha(str(base) + '.tar.gz'),
                                'removed': removed, 'added': {r: {'from': r} for r in PROJECT_LICENSES}}
    (dest / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')

    before, after = tree(base), tree(dest)
    changed = sorted(k for k in before.keys() | after.keys() if before.get(k) != after.get(k))
    if changed != sorted([OLD_PROJECT_LICENSE, *PROJECT_LICENSES, 'runtime.json']):
        raise ValueError('Unexpected differences from the base runtime: ' + ', '.join(changed))

    archive = write_archive(dest)
    base_proof = json.loads(Path(str(base) + '.tar.json').read_text())
    for key in ('replaced', 'added', 'restamped', 'repackaged_from'):
        base_proof.pop(key, None)
    result = dict(base_proof, version=version, archive_sha256=sha(archive), archive_bytes=archive.stat().st_size,
                  unpacked_file_bytes=sum(v.get('bytes', 0) for v in manifest['files'].values()),
                  files=len(manifest['files']), derived_from=base_version,
                  removed=[OLD_PROJECT_LICENSE], added=list(PROJECT_LICENSES))
    archive.with_suffix('.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


def chain(version):
    """The manifest of VERSION and of each runtime it was derived from, newest first."""
    while version:
        manifest = json.loads((ARTIFACTS / version / 'runtime.json').read_text())
        yield manifest
        version = manifest.get('derived_from', {}).get('version')


def chain_original(version, relative, patch):
    """SHA-256 of the file that builds of this patch start from: RELATIVE in the newest runtime
    of the derivation chain that did not get it from its base unchanged (derivations that left
    it alone, and re-stamps, which change no code, are looked through) or from a build of PATCH."""
    for manifest in chain(version):
        derived = manifest.get('derived_from', {})
        replacement = derived.get('replaced', {}).get(relative)
        if 'restamped' in derived or (derived and replacement is None) or (replacement or {}).get('patch') == patch:
            continue
        return manifest['files'][relative]['sha256']
    raise ValueError(f'No original of {relative} in the chain of {version}')


def chain_replacement(version, relative):
    """How the newest derivation in the chain that replaced RELATIVE did it ({} if none did)."""
    for manifest in chain(version):
        replacement = manifest.get('derived_from', {}).get('replaced', {}).get(relative)
        if replacement is not None:
            return replacement
    return {}


def restamp_runtime(base_version, version, identity, minimum_text):
    """Lower the minimum macOS of every Mach-O file in the base that requires a newer one.
    Each is re-signed as before and, unsigned, differs from the base only in that field."""
    minimum = parse_macos(minimum_text)
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}', version):
        raise ValueError('Invalid runtime version')
    base, dest = ARTIFACTS / base_version, ARTIFACTS / version
    if dest.exists() or Path(str(dest) + '.tar.gz').exists():
        raise ValueError('Use a new version; existing artifact is never overwritten')
    manifest = json.loads((base / 'runtime.json').read_text())
    if manifest['version'] != base_version:
        raise ValueError('The base artifact names a different version')

    run('/bin/cp', '-Rc', base, dest)  # APFS clone: only re-stamped files take space
    restamped = {}
    game_app = [f for f in manifest['files'] if f.startswith(game_mode_app.BUNDLE + '/')]
    for relative in sorted(manifest['files']):
        target = dest / relative
        if target.is_symlink() or not target.is_file() or relative in game_app:
            continue
        required = restamp(target, minimum)
        if required is None:
            continue
        sign_like(target, base / relative, identity)
        if not same_apart_from_minimum(base / relative, target):
            raise ValueError(f'{relative} differs from the base beyond its minimum macOS')
        restamped[relative] = {'base_sha256': manifest['files'][relative]['sha256'], 'minimum_macos': format_macos(required)}
        manifest['files'][relative] = {'sha256': sha(target), 'bytes': target.stat().st_size}
    if game_app:
        # The game app is made again from the re-stamped loader: signing its executable
        # alone would break the bundle's seal, and its Info.plist names the minimum too.
        shutil.rmtree(dest / game_mode_app.BUNDLE)
        if sorted(game_mode_app.make(dest, minimum_text, identity)) != sorted(game_app):
            raise ValueError('The game app was made with other files than the base has')
        for relative in game_app:
            restamped[relative] = {'base_sha256': manifest['files'][relative]['sha256'], 'remade_by': 'scripts/game_mode_app.py'}
            manifest['files'][relative] = {'sha256': sha(dest / relative), 'bytes': (dest / relative).stat().st_size}
    if not restamped:
        raise ValueError(f'Nothing in {base_version} requires a macOS newer than {minimum_text}')

    manifest['version'] = version
    manifest['minimum_macos'] = minimum_text
    manifest['derived_from'] = {'version': base_version, 'archive_sha256': sha(str(base) + '.tar.gz'),
                                'minimum_macos': minimum_text, 'restamped': restamped}
    (dest / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')

    before, after = tree(base), tree(dest)
    changed = sorted(k for k in before.keys() | after.keys() if before.get(k) != after.get(k))
    if changed != sorted([*restamped, 'runtime.json']):
        raise ValueError('Unexpected differences from the base runtime: ' + ', '.join(changed))

    archive = write_archive(dest)
    newest, declared = archive_minimum(archive)
    if newest > minimum or declared != minimum_text:
        raise ValueError(f'{archive.name} still requires macOS {format_macos(newest)}')
    base_proof = json.loads(Path(str(base) + '.tar.json').read_text())
    for key in ('replaced', 'repackaged_from'):
        base_proof.pop(key, None)
    result = dict(base_proof, version=version, archive_sha256=sha(archive), archive_bytes=archive.stat().st_size,
                  unpacked_file_bytes=sum(v.get('bytes', 0) for v in manifest['files'].values()),
                  files=len(manifest['files']), derived_from=base_version, minimum_macos=minimum_text,
                  restamped=sorted(restamped))
    archive.with_suffix('.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


def derive_native(base_version, version, identity, components, game_mode=False):
    """Replace only these build_wine_native.py components in a runtime that already ships
    earlier builds of the same experiments (phase2-20260930.1 and later); with GAME_MODE,
    also add the game app (needs ntdll's game_mode_exec, so ntdll must be among them)."""
    if game_mode and 'ntdll' not in components:
        raise ValueError('--game-mode needs --native ntdll: ntdll starts the game from the game app')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}', version):
        raise ValueError('Invalid runtime version')
    base, dest = ARTIFACTS / base_version, ARTIFACTS / version
    if dest.exists() or Path(str(dest) + '.tar.gz').exists():
        raise ValueError('Use a new version; existing artifact is never overwritten')
    manifest = json.loads((base / 'runtime.json').read_text())
    if manifest['version'] != base_version:
        raise ValueError('The base artifact names a different version')
    sources, replaced = {}, {}
    for component in components:
        if component not in NATIVE_FILES:
            raise ValueError('Unknown native component: ' + component)
        relative = NATIVE_FILES[component]
        build = json.loads((NATIVE / component / 'current/manifest.json').read_text())
        built = NATIVE / component / 'current' / Path(relative).name
        if build['sha256'] != sha(built) or build['patch_sha256'] != sha(ROOT / build['patch']):
            raise ValueError(f'Rebuild {component}: its build manifest does not match the file or the patch')
        earlier = chain_replacement(base_version, relative)
        if earlier.get('patch') != build['patch']:
            raise ValueError(f'{base_version} does not ship an earlier build of the {component} experiment')
        if build['base_sha256'] != chain_original(base_version, relative, build['patch']):
            raise ValueError(f'{component} was built against a different base runtime')
        sources[relative] = built
        replaced[relative] = {'build_sha256': build['sha256'], 'built_by': f'scripts/build_wine_native.py {component}',
                              'patch': build['patch'], 'patch_sha256': build['patch_sha256']}
    replace_files(base, dest, base_version, version, identity, manifest, sources, replaced, game_mode)


WINEBUS = 'lib/wine/x86_64-unix/winebus.so'
SDL2_LIBRARY = 'lib/libSDL2-2.0.0.dylib'
SDL2_LICENSE = 'licenses/native/sdl2/LICENSE.txt'
CLEAN_DEPS = ROOT / 'runtime/phase-2/clean-deps'


def derive_controllers(base_version, version, identity):
    """1.2: winebus built with SDL2 replaces the base's, and that SDL2 library and its license
    are added, so Wine reads Xbox (and every other non-PlayStation) controller."""
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}', version):
        raise ValueError('Invalid runtime version')
    base, dest = ARTIFACTS / base_version, ARTIFACTS / version
    if dest.exists() or Path(str(dest) + '.tar.gz').exists():
        raise ValueError('Use a new version; existing artifact is never overwritten')
    manifest = json.loads((base / 'runtime.json').read_text())
    if manifest['version'] != base_version:
        raise ValueError('The base artifact names a different version')
    build = json.loads((NATIVE / 'winebus/current/manifest.json').read_text())
    built = NATIVE / 'winebus/current/winebus.so'
    library, license_text = CLEAN_DEPS / 'lib/libSDL2-2.0.0.dylib', CLEAN_DEPS / 'licenses/sdl2/LICENSE.txt'
    if build['sha256'] != sha(built) or 'sdl2' not in build:
        raise ValueError('Rebuild winebus: its build manifest does not match the file or lacks SDL2')
    if build['sdl2']['library_sha256'] != sha(library):
        raise ValueError('winebus was built against another SDL2 build than ' + str(library))
    # Builds without a patch start from the shipped file: the chain's original winebus.
    if build['base_sha256'] != chain_original(base_version, WINEBUS, 'sdl2'):
        raise ValueError('winebus was built against a different base runtime')
    replaced = {WINEBUS: {'build_sha256': build['sha256'], 'built_by': 'scripts/build_wine_native.py winebus',
                          'sdl2': build['sdl2']}}
    additions = {SDL2_LIBRARY: (library, {'built_by': 'scripts/build_portable_dependencies.py --only sdl2',
                                          'build_sha256': build['sdl2']['library_sha256'],
                                          'version': build['sdl2']['version']}),
                 SDL2_LICENSE: (license_text, {'from': 'SDL2-' + build['sdl2']['version'] + '/LICENSE.txt'})}
    replace_files(base, dest, base_version, version, identity, manifest, {WINEBUS: built}, replaced,
                  additions=additions)


# MetalFX upscaling (1.3): DXMT's d3d12.dll stand-in replaces Wine's (which launches disable),
# and the DLSS and NVAPI stand-ins are new. NVAPI's headers are a submodule of the DXMT source.
METALFX_REPLACED = {**DXMT_FILES, 'lib/wine/x86_64-windows/d3d12.dll': 'x86_64-windows/d3d12.dll'}
METALFX_NVNGX = 'lib/wine/x86_64-windows/nvngx.dll'
METALFX_ADDED = {METALFX_NVNGX: 'x86_64-windows/nvngx.dll',
                 'lib/wine/x86_64-windows/nvapi64.dll': 'x86_64-windows/nvapi64.dll'}
NVAPI_LICENSE = 'licenses/NVAPI-MIT'
DXMT_PATCHES = {'patches/dxmt-v1-private.patch': 'patch_sha256',
                'patches/dxmt-v1-performance.patch': 'performance_patch_sha256',
                'patches/dxmt-portable-metal.patch': 'portable_metal_patch_sha256',
                'patches/dxmt-metalfx-upscaling.patch': 'metalfx_patch_sha256'}


def derive_metalfx(base_version, version, identity, dxmt_workspace):
    """1.3: MetalFX upscaling. The DXMT build with the MetalFX patch replaces the base's five DXMT
    files, and its d3d12.dll stand-in replaces Wine's; its DLSS and NVAPI stand-ins and NVAPI's
    license are added. DLLs are packaged as the assembler packages DXMT's, except nvngx.dll: its
    Authenticode signature (Recall's certificate, which NVIDIA's loader checks) covers its bytes,
    so it is copied as built and its signature checked."""
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}', version):
        raise ValueError('Invalid runtime version')
    base, dest = ARTIFACTS / base_version, ARTIFACTS / version
    if dest.exists() or Path(str(dest) + '.tar.gz').exists():
        raise ValueError('Use a new version; existing artifact is never overwritten')
    manifest = json.loads((base / 'runtime.json').read_text())
    if manifest['version'] != base_version:
        raise ValueError('The base artifact names a different version')
    proof = json.loads((dxmt_workspace / 'dxmt-build-proof.json').read_text())
    install = dxmt_workspace / 'dxmt-install'
    for patch, key in DXMT_PATCHES.items():
        if proof.get(key) != sha(ROOT / patch):
            raise ValueError(f'Rebuild DXMT: {patch} changed since the build')
    for built in [*METALFX_REPLACED.values(), *METALFX_ADDED.values()]:
        if proof['files'].get(built) != sha(install / built):
            raise ValueError(f'DXMT build proof does not match {built}')
    if not sign_pe.check(install / METALFX_ADDED[METALFX_NVNGX]):
        raise ValueError('nvngx.dll is not signed (build_portable_dxmt.py signs it)')
    license_text = dxmt_workspace / 'dxmt-source/external/nvapi/License.txt'
    if 'SPDX-License-Identifier: MIT' not in license_text.read_text():
        raise ValueError('NVAPI license not found in the DXMT source')
    record = {'built_by': 'scripts/build_portable_dxmt.py', 'patches': {patch: proof[key] for patch, key in DXMT_PATCHES.items()}}
    with tempfile.TemporaryDirectory() as folder:
        sources, replaced, additions = {}, {}, {}
        for relative, built in METALFX_REPLACED.items():
            source = install / built
            if relative not in DXMT_FILES:  # replace_files packages DXMT's own five
                source = Path(folder) / Path(built).name
                shutil.copy2(install / built, source)
                package_like_assembler(source)
            sources[relative] = source
            replaced[relative] = dict(record, build_sha256=proof['files'][built])
        for relative, built in METALFX_ADDED.items():
            source = install / built
            if relative != METALFX_NVNGX:
                source = Path(folder) / Path(built).name
                shutil.copy2(install / built, source)
                package_like_assembler(source)
            check_paths(source)
            additions[relative] = (source, dict(record, build_sha256=proof['files'][built]))
        additions[NVAPI_LICENSE] = (license_text, {'from': 'NVIDIA NVAPI ' + proof['nvapi'] + '/License.txt'})
        replace_files(base, dest, base_version, version, identity, manifest, sources, replaced, additions=additions)
    if sha(dest / METALFX_NVNGX) != proof['files'][METALFX_ADDED[METALFX_NVNGX]] or not sign_pe.check(dest / METALFX_NVNGX):
        raise ValueError('nvngx.dll changed on its way into the runtime')


def unsigned_identical(original, resigned):
    """True when the two files are the same once their signatures are removed."""
    with tempfile.TemporaryDirectory() as folder:
        copies = [Path(folder) / 'a', Path(folder) / 'b']
        for source, copy in zip((original, resigned), copies):
            shutil.copy2(source, copy)
            run('codesign', '--remove-signature', copy)
        return copies[0].read_bytes() == copies[1].read_bytes()


def signature_of(path):
    """Identifier and entitlements of a file signed with the hardened runtime."""
    info = subprocess.run(['codesign', '-dvv', str(path)], capture_output=True, text=True).stderr
    identifier = re.search(r'^Identifier=(.+)$', info, re.M)
    if not identifier or not re.search(r'^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*\bruntime\b', info, re.M):
        raise ValueError(f'{Path(path).name} is not signed with the hardened runtime')
    xml = subprocess.run(['codesign', '-d', '--xml', '--entitlements', '-', str(path)], capture_output=True).stdout
    return identifier.group(1), plistlib.loads(xml) if xml.strip() else None


def derive_microphone(base_version, version, identity):
    """1.3: the hardened runtime gives a process signed without the microphone entitlement
    silence, with no prompt, so Overwatch's voice chat heard nothing. The Wine loader and server
    (every file the assembler signs with Wine's entitlements) are re-signed with it added, as
    CrossOver signs its loader, and the game app is made again from that loader (it carries the
    loader's entitlements). Unsigned, each re-signed file is byte-identical to the base's."""
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,63}', version):
        raise ValueError('Invalid runtime version')
    base, dest = ARTIFACTS / base_version, ARTIFACTS / version
    if dest.exists() or Path(str(dest) + '.tar.gz').exists():
        raise ValueError('Use a new version; existing artifact is never overwritten')
    manifest = json.loads((base / 'runtime.json').read_text())
    if manifest['version'] != base_version:
        raise ValueError('The base artifact names a different version')
    game_app = [f for f in manifest['files'] if f.startswith(game_mode_app.BUNDLE + '/')]
    targets = sorted(f for f in manifest['files'] if Path(f).name in ('wine', 'wineserver') and f not in game_app)
    if not targets:
        raise ValueError(f'{base_version} has no Wine loader or server')
    signatures = {relative: signature_of(base / relative) for relative in targets}
    if any(MICROPHONE in (entitlements or {}) for _, entitlements in signatures.values()):
        raise ValueError(f'{base_version} already has the microphone entitlement')

    run('/bin/cp', '-Rc', base, dest)  # APFS clone: only re-signed files take space
    resigned = {}
    with tempfile.TemporaryDirectory() as folder:
        for relative in targets:
            target = dest / relative
            identifier, entitlements = signatures[relative]
            entitlements = {**(entitlements or {}), MICROPHONE: True}
            plist = Path(folder) / 'entitlements.plist'
            plist.write_bytes(plistlib.dumps(entitlements))
            args = ['codesign', '--force', '--options', 'runtime', '--sign', identity, '--identifier', identifier,
                    '--entitlements', plist]
            if identity != '-':
                args.insert(4, '--timestamp')
            run(*args, target, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            run('codesign', '--verify', '--strict', target)
            if signature_of(target) != (identifier, entitlements):
                raise ValueError(f'{relative} is not signed as intended')
            if not unsigned_identical(base / relative, target):
                raise ValueError(f'{relative} differs from the base beyond its signature')
            resigned[relative] = {'base_sha256': manifest['files'][relative]['sha256'], 'entitlement_added': MICROPHONE}
            manifest['files'][relative] = {'sha256': sha(target), 'bytes': target.stat().st_size}
    if game_app:
        # Signing its executable alone would break the bundle's seal.
        shutil.rmtree(dest / game_mode_app.BUNDLE)
        if sorted(game_mode_app.make(dest, manifest.get('minimum_macos', '26.0'), identity)) != sorted(game_app):
            raise ValueError('The game app was made with other files than the base has')
        for relative in game_app:
            if relative == game_mode_app.EXECUTABLE and not unsigned_identical(base / relative, dest / relative):
                raise ValueError('The game app executable differs from the base beyond its signature')
            resigned[relative] = {'base_sha256': manifest['files'][relative]['sha256'], 'remade_by': 'scripts/game_mode_app.py'}
            manifest['files'][relative] = {'sha256': sha(dest / relative), 'bytes': (dest / relative).stat().st_size}

    manifest['version'] = version
    manifest['derived_from'] = {'version': base_version, 'archive_sha256': sha(str(base) + '.tar.gz'),
                                'entitlement_added': MICROPHONE, 'resigned': resigned}
    (dest / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')

    before, after = tree(base), tree(dest)
    changed = sorted(k for k in before.keys() | after.keys() if before.get(k) != after.get(k))
    if not set(changed) <= {*resigned, 'runtime.json'} or not set(targets) <= set(changed):
        raise ValueError('Unexpected differences from the base runtime: ' + ', '.join(changed))

    archive = write_archive(dest)
    base_proof = json.loads(Path(str(base) + '.tar.json').read_text())
    for key in ('replaced', 'restamped', 'removed', 'added', 'repackaged_from'):
        base_proof.pop(key, None)  # the base's own records, not this derivation's
    result = dict(base_proof, version=version, archive_sha256=sha(archive), archive_bytes=archive.stat().st_size,
                  unpacked_file_bytes=sum(v.get('bytes', 0) for v in manifest['files'].values()),
                  files=len(manifest['files']), derived_from=base_version, resigned=sorted(resigned),
                  entitlement_added=MICROPHONE)
    archive.with_suffix('.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--base-version', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--identity', help='Developer ID Application certificate fingerprint')
    parser.add_argument('--repackage', action='store_true', help='Copy the base under the new version, replacing nothing')
    parser.add_argument('--native', metavar='COMPONENT[,COMPONENT]',
                        help='Replace only these build_wine_native.py components (wineserver, ntdll, win32u, '
                             'winemac) in a runtime that already ships earlier builds of them')
    parser.add_argument('--game-mode', action='store_true',
                        help='With --native ntdll: add the game app that lets macOS turn Game Mode on for Overwatch')
    parser.add_argument('--components', type=Path, metavar='DXMT_WORKSPACE',
                        help='Replace the Wine components from build_wine_native.py, the DXMT build in this '
                             'build_portable_dxmt.py workspace and the renderer profile')
    parser.add_argument('--minimum-macos', metavar='VERSION',
                        help='Lower the minimum macOS of every Mach-O file that requires a newer one '
                             '(e.g. 15.0), re-signing each as before')
    parser.add_argument('--relicense', action='store_true',
                        help="Replace the project's MIT license file with the Apache 2.0 license and NOTICE")
    parser.add_argument('--controllers', action='store_true',
                        help='Replace winebus with the SDL2 build and add the SDL2 library and its license')
    parser.add_argument('--microphone', action='store_true',
                        help='Re-sign the Wine loader and server with the microphone entitlement and remake the game app')
    parser.add_argument('--metalfx', type=Path, metavar='DXMT_WORKSPACE',
                        help="Replace DXMT with this build_portable_dxmt.py workspace's MetalFX build and add its "
                             'd3d12, DLSS and NVAPI stand-ins')
    args = parser.parse_args()
    if args.repackage:
        repackage(args.base_version, args.version)
    elif args.relicense:
        relicense(args.base_version, args.version)
    elif not args.identity:
        parser.error('--identity is required to replace components')
    elif args.controllers:
        derive_controllers(args.base_version, args.version, args.identity)
    elif args.microphone:
        derive_microphone(args.base_version, args.version, args.identity)
    elif args.metalfx:
        derive_metalfx(args.base_version, args.version, args.identity, args.metalfx.resolve())
    elif args.minimum_macos:
        restamp_runtime(args.base_version, args.version, args.identity, args.minimum_macos)
    elif args.native:
        derive_native(args.base_version, args.version, args.identity, args.native.split(','), args.game_mode)
    elif args.components:
        derive_components(args.base_version, args.version, args.identity, args.components.resolve())
    else:
        derive(args.base_version, args.version, args.identity)
