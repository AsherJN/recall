#!/usr/bin/env python3
"""Build the experimental mouselook window driver for the shipped Phase 2 runtime.

Developer tool only. Compiles winemac.so from runtime/source/wine-mouselook with
the exact compiler and linker commands recorded in the Phase 2 Wine Makefile,
links it against the Phase 2 ntdll/win32u, applies the same strip and rpath
treatment as assemble_portable_runtime.py and signs it ad hoc. It never modifies
the Phase 2 tree, the runtime archive or an installed runtime.

--base builds the unmodified Phase 2 driver sources through the same steps and
requires the result to match the shipped driver byte for byte (the Phase 2 link
output, and the archived driver once its Developer ID signature is removed).

The unmodified sources are runtime/source/wine-v1 (CrossOver 26.3 plus
wine-v1-canvas.patch, which is generated from it), not the Phase 2 tree: once a
runtime ships mouselook, build_portable_runtime.py applies wine-mouselook.patch
to the Phase 2 tree as well.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import difflib
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess

ROOT = Path(__file__).resolve().parents[1]
# Resolved: in a worktree runtime/phase-2 is a symlink, and the Makefile's recipes name
# the real paths that compile_component rewrites to the experiment sources.
PHASE2 = (ROOT / 'runtime/phase-2').resolve()
TREE = PHASE2 / 'wine-build'
BASE = PHASE2 / 'sources/wine/sources/wine'
PRISTINE = ROOT / 'runtime/source/wine-v1'
# Phase 2 link output of the unmodified driver (runtime phase2-20260913.8).
PRISTINE_RAW_SHA256 = '04c7498520b5a73d081487f8f98845d35cac67a960c926f7861aa88a057e4a05'
DRIVER = 'dlls/winemac.drv'
SOURCE = ROOT / 'runtime/source/wine-mouselook'
OUT = ROOT / 'runtime/build/winemac-mouselook'
ARCHIVED = PHASE2 / 'artifacts/phase2-20260913.8/lib/wine/x86_64-unix/winemac.so'
PATCH = ROOT / 'patches/wine-mouselook.patch'
# build_portable_runtime.py passes this on the make command line; it is not in the Makefile.
LDFLAGS = '-Wl,-headerpad,0x1000 -L' + str(PHASE2 / 'deps/lib')
EXTENSIONS = ('.c', '.m', '.h', '.rc', '.in')
# The build environment of build_portable_runtime.py. Phase 2 was compiled by the
# Command Line Tools clang (2100.1.1.101) with the macOS 26.5 SDK; Xcode updates
# must not silently change the toolchain of a driver meant to drop into it.
TOOLS = Path('/Library/Developer/CommandLineTools')
ENV = dict(os.environ, MACOSX_DEPLOYMENT_TARGET='26.0', DEVELOPER_DIR=str(TOOLS),
           SDKROOT=str(TOOLS / 'SDKs/MacOSX26.5.sdk'),
           PATH=':'.join([str(ROOT / 'runtime/toolchains/bison/bin'),
                          str(ROOT / 'runtime/toolchains/llvm-mingw-20251216-ucrt-macos-universal/bin'),
                          '/usr/bin', '/bin', '/usr/sbin', '/sbin']))


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def variable(makefile, name):
    match = re.search(r'^' + name + r' = (.*)$', makefile, re.M)
    if not match:
        raise RuntimeError('Phase 2 Makefile lacks ' + name)
    return match.group(1)


def recipe(makefile, target):
    """Return the shell command of the rule for target (joined continuation lines)."""
    match = re.search(r'^' + re.escape(target) + r':[^\n]*(?:\\\n[^\n]*)*\n\t((?:[^\n]*\\\n)*[^\n]*)', makefile, re.M)
    if not match:
        raise RuntimeError('Phase 2 Makefile lacks a rule for ' + target)
    return match.group(1).replace('\\\n', ' ')


def expand(command, output, makefile):
    command = command.replace('$(CC)', variable(makefile, 'CC')).replace('$(CFLAGS)', variable(makefile, 'CFLAGS'))
    command = command.replace('$(LDFLAGS)', LDFLAGS).replace('$@', str(output))
    if '$(' in command:
        raise RuntimeError('Unexpanded make variable in: ' + command)
    return command


def objects(makefile):
    rule = re.search(r'^' + re.escape(DRIVER) + r'/winemac\.so:((?:[^\n]*\\\n)*[^\n]*)', makefile, re.M).group(1)
    return re.findall(re.escape(DRIVER) + r'/(\w+)\.o', rule)


def compile_driver(source, out):
    makefile = (TREE / 'Makefile').read_text()
    objdir = out / 'obj'
    objdir.mkdir(parents=True, exist_ok=True)
    prefix_map = ''
    if source != BASE:
        # Same reproducible-path treatment as the Phase 2 build: no developer paths in the binary.
        prefix_map = ' -ffile-prefix-map=' + str(source) + '=/build/overwatch-2-mac/sources/wine/sources/wine'

    def build(name):
        command = expand(recipe(makefile, f'{DRIVER}/{name}.o'), objdir / f'{name}.o', makefile)
        command = command.replace(str(BASE / DRIVER) + '/', str(source / DRIVER) + '/')
        command = command.replace('-I' + str(BASE / DRIVER) + ' ', '-I' + str(source / DRIVER) + ' ')
        result = subprocess.run(command + prefix_map, shell=True, cwd=TREE, env=ENV, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(f'{name}.o failed to compile:\n' + result.stderr)
        # Upstream deprecation noise is identical to Phase 2; show new warnings only.
        own = [line for line in result.stderr.splitlines() if 'warning:' in line and 'deprecated' not in line]
        if own and source == SOURCE:
            print('\n'.join(own), flush=True)
        return name

    names = objects(makefile)
    with ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(build, names))
    link = expand(recipe(makefile, f'{DRIVER}/winemac.so'), out / 'winemac.raw.so', makefile)
    link = re.sub(re.escape(DRIVER) + r'/(\w+)\.o', lambda m: str(objdir / (m.group(1) + '.o')), link)
    subprocess.run(link, shell=True, cwd=TREE, env=ENV, check=True)
    return out / 'winemac.raw.so'


def links(p):
    text = subprocess.check_output(['otool', '-L', str(p)], text=True)
    return [line.strip().split(' (')[0] for line in text.splitlines()[1:]]


def rpaths(p):
    text = subprocess.check_output(['otool', '-l', str(p)], text=True)
    return re.findall(r'cmd LC_RPATH\n\s+cmdsize \d+\n\s+path (.*?) \(offset', text)


def package(raw, final):
    """The assemble_portable_runtime.py treatment for lib/wine/x86_64-unix, minus Developer ID signing."""
    shutil.copy2(raw, final)
    run('/usr/bin/strip', '-S', '-x', final, stderr=subprocess.DEVNULL)
    for dep in links(final):
        if dep.startswith(('/usr/lib/', '/System/Library/', '@loader_path/', '@rpath/', '@executable_path/')):
            continue
        if Path(dep).name in ('ntdll.so', 'win32u.so'):
            run('install_name_tool', '-change', dep, '@rpath/' + Path(dep).name, final, stderr=subprocess.DEVNULL)
        else:
            raise ValueError('Unresolved non-system dependency: ' + dep)
    desired = ['@loader_path', '@loader_path/../..']
    old = rpaths(final)
    for path in old:
        if path not in desired:
            run('install_name_tool', '-delete_rpath', path, final, stderr=subprocess.DEVNULL)
    for path in desired:
        if path not in old:
            run('install_name_tool', '-add_rpath', path, final, stderr=subprocess.DEVNULL)
    for value in (str(ROOT), '/Users/'):
        if value.encode() in final.read_bytes():
            raise ValueError('Development path remains in the driver')
    return final


def without_linkedit_vmsize(path):
    """Bytes with the __LINKEDIT vmsize zeroed: codesign --remove-signature leaves it at the signed size."""
    data = bytearray(Path(path).read_bytes())
    magic, _, _, _, ncmds, _, _, _ = struct.unpack_from('<8I', data, 0)
    if magic != 0xfeedfacf:
        raise ValueError('Not a 64-bit Mach-O file: ' + str(path))
    offset = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<2I', data, offset)
        if cmd == 0x19 and data[offset + 8:offset + 24].rstrip(b'\0') == b'__LINKEDIT':
            data[offset + 32:offset + 40] = bytes(8)
        offset += size
    return bytes(data)


def unsigned_copy(path, target):
    shutil.copy2(path, target)
    run('/usr/bin/codesign', '--remove-signature', target)
    return target


def write_patch():
    lines = []
    base, new = PRISTINE / DRIVER, SOURCE / DRIVER
    for path in sorted(new.iterdir()):
        if path.suffix not in EXTENSIONS:
            continue
        old = base / path.name
        before = old.read_text().splitlines(keepends=True) if old.exists() else []
        after = path.read_text().splitlines(keepends=True)
        lines.extend(difflib.unified_diff(before, after, fromfile=f'a/{DRIVER}/{path.name}' if before else '/dev/null',
                                          tofile=f'b/{DRIVER}/{path.name}'))
    for path in sorted(base.iterdir()):
        if path.suffix in EXTENSIONS and not (new / path.name).exists():
            raise RuntimeError('Driver source removed from the experiment tree: ' + path.name)
    PATCH.write_text(''.join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', action='store_true', help='Reproduce the shipped driver from unmodified sources')
    args = parser.parse_args()
    for required in (TREE / 'Makefile', BASE / DRIVER, PRISTINE / DRIVER, ARCHIVED, TREE / 'dlls/win32u/win32u.so',
                     Path(ENV['SDKROOT'])):
        if not required.exists():
            parser.error('Missing Phase 2 build input: ' + str(required))
    if args.base:
        out = OUT / 'base'
        if out.exists():
            shutil.rmtree(out)
        out.mkdir(parents=True)
        raw = compile_driver(PRISTINE, out)
        if sha(raw) != PRISTINE_RAW_SHA256:
            raise SystemExit('Base driver link output differs from the Phase 2 build')
        final = package(raw, out / 'winemac.so')
        if without_linkedit_vmsize(final) != without_linkedit_vmsize(unsigned_copy(ARCHIVED, out / 'archived-unsigned.so')):
            raise SystemExit('Base driver differs from the shipped driver after packaging')
        print(json.dumps({'reproduced': True, 'raw_sha256': sha(raw), 'packaged_unsigned_sha256': sha(final)}, indent=2))
        return
    if not (SOURCE / DRIVER).is_dir():
        parser.error('Experiment sources are missing: ' + str(SOURCE / DRIVER))
    before = {p.name: sha(p) for p in (SOURCE / DRIVER).iterdir() if p.suffix in EXTENSIONS}
    out = OUT / 'current'
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    raw = compile_driver(SOURCE, out)
    final = package(raw, out / 'winemac.so')
    run('/usr/bin/codesign', '--force', '--sign', '-', final, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run('/usr/bin/codesign', '--verify', '--strict', final)
    if before != {p.name: sha(p) for p in (SOURCE / DRIVER).iterdir() if p.suffix in EXTENSIONS}:
        raise SystemExit('Driver sources changed during the build')
    write_patch()
    manifest = {'schema': 1, 'driver_sha256': sha(final), 'patch': str(PATCH.relative_to(ROOT)), 'patch_sha256': sha(PATCH),
                'base_driver_sha256': sha(ARCHIVED), 'base_sources': 'runtime/source/wine-v1 (CrossOver 26.3 + wine-v1-canvas.patch)',
                'sources': before}
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({'driver': str(final), 'sha256': manifest['driver_sha256'], 'patch': str(PATCH)}, indent=2))


if __name__ == '__main__':
    main()
