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
ENTITLEMENTS = ['com.apple.security.cs.allow-jit', 'com.apple.security.cs.allow-unsigned-executable-memory',
                'com.apple.security.cs.disable-executable-page-protection', 'com.apple.security.cs.disable-library-validation']


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


def replace_files(base, dest, base_version, version, identity, manifest, sources, replaced):
    """Clone the base, put each source at its relative path (native files signed as the
    assembler signs them), record the replacements and archive; nothing else may differ."""
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
            args = ['codesign', '--force', '--options', 'runtime', '--timestamp', '--sign', identity]
            if target.name in ('wine', 'wineserver'):
                args += ['--entitlements', entitlements]
            run(*args, target, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            run('codesign', '--verify', '--strict', target)
    finally:
        entitlements.unlink(missing_ok=True)

    manifest['version'] = version
    for relative in sources:
        manifest['files'][relative] = {'sha256': sha(dest / relative), 'bytes': (dest / relative).stat().st_size}
    manifest['derived_from'] = {'version': base_version, 'archive_sha256': sha(str(base) + '.tar.gz'), 'replaced': replaced}
    (dest / 'runtime.json').write_text(json.dumps(manifest, indent=2) + '\n')

    before, after = tree(base), tree(dest)
    changed = sorted(k for k in before.keys() | after.keys() if before.get(k) != after.get(k))
    if changed != sorted([*sources, 'runtime.json']):
        raise ValueError('Unexpected differences from the base runtime: ' + ', '.join(changed))

    archive = write_archive(dest)
    base_proof = json.loads(Path(str(base) + '.tar.json').read_text())
    result = dict(base_proof, version=version, archive_sha256=sha(archive), archive_bytes=archive.stat().st_size,
                  unpacked_file_bytes=sum(v.get('bytes', 0) for v in manifest['files'].values()),
                  files=len(manifest['files']), derived_from=base_version, replaced=sorted(sources))
    archive.with_suffix('.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


def chain_original(version, relative, patch):
    """SHA-256 of a file in the newest runtime of the derivation chain whose copy is not a
    build of this patch: the file that patch's builds start from."""
    while True:
        manifest = json.loads((ARTIFACTS / version / 'runtime.json').read_text())
        derived = manifest.get('derived_from', {})
        if derived.get('replaced', {}).get(relative, {}).get('patch') != patch:
            return manifest['files'][relative]['sha256']
        version = derived['version']


def derive_native(base_version, version, identity, components):
    """Replace only these build_wine_native.py components in a runtime that already ships
    earlier builds of the same experiments (phase2-20260930.1 and later)."""
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
        earlier = manifest.get('derived_from', {}).get('replaced', {}).get(relative, {})
        if earlier.get('patch') != build['patch']:
            raise ValueError(f'{base_version} does not ship an earlier build of the {component} experiment')
        if build['base_sha256'] != chain_original(base_version, relative, build['patch']):
            raise ValueError(f'{component} was built against a different base runtime')
        sources[relative] = built
        replaced[relative] = {'build_sha256': build['sha256'], 'built_by': f'scripts/build_wine_native.py {component}',
                              'patch': build['patch'], 'patch_sha256': build['patch_sha256']}
    replace_files(base, dest, base_version, version, identity, manifest, sources, replaced)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--base-version', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--identity', help='Developer ID Application certificate fingerprint')
    parser.add_argument('--repackage', action='store_true', help='Copy the base under the new version, replacing nothing')
    parser.add_argument('--native', metavar='COMPONENT[,COMPONENT]',
                        help='Replace only these build_wine_native.py components (wineserver, ntdll, win32u, '
                             'winemac) in a runtime that already ships earlier builds of them')
    parser.add_argument('--components', type=Path, metavar='DXMT_WORKSPACE',
                        help='Replace the Wine components from build_wine_native.py, the DXMT build in this '
                             'build_portable_dxmt.py workspace and the renderer profile')
    args = parser.parse_args()
    if args.repackage:
        repackage(args.base_version, args.version)
    elif not args.identity:
        parser.error('--identity is required to replace components')
    elif args.native:
        derive_native(args.base_version, args.version, args.identity, args.native.split(','))
    elif args.components:
        derive_components(args.base_version, args.version, args.identity, args.components.resolve())
    else:
        derive(args.base_version, args.version, args.identity)
