#!/usr/bin/env python3
"""Build the native Wine components that v1.0 changes in the Phase 2 runtime.

  build_wine_native.py wineserver|ntdll|win32u|winemac [--base]

Developer tool only. Compiles a component from its experiment tree with the exact
compiler and linker commands recorded in the Phase 2 Wine Makefile, applies the
assemble_portable_runtime.py strip and rpath treatment and signs the result ad hoc. It
never modifies the Phase 2 tree, the runtime archive or an installed runtime; replay
engines take the result with `replay.py variant --wineserver/--ntdll/--win32u/--winemac`.

--base builds the unmodified sources through the same steps, as the control for
experiments, and requires the result to match the Phase 2 link output and the shipped
file (Developer ID signature removed) byte for byte apart from LC_UUID, which ld64
derives from its inputs, including where the object files were.

Experiments (each tree is a git repository whose first commit is the unmodified source):
  wineserver  runtime/source/wine-server (wine-v1's server/, identical to Phase 2's).
              The periodic registry save is written by a forked copy of the server, so
              client requests no longer wait ~0.1 s every 30 s while system.reg is
              written; WINESERVER_REGISTRY_LOG=<file> logs changes to saved keys.
  ntdll       runtime/source/wine-ntdll (the Phase 2 tree's dlls/ntdll, which carries
              wine-portable-directory-boolean.patch). A DLL's Unix library is loaded
              without holding virtual_mutex. WINE_SYSCALL_LOG=<file> writes, every 100 ms,
              the busiest Windows system calls, BSD/Mach call counts, page faults, signal
              and fault counters, virtual_mutex waits and holds, the busiest threads and
              rare calls, plus a line per slow call; WINE_IO_ERROR_LOG=<file> logs failed
              file reads.
  win32u      runtime/source/wine-win32u (the Phase 2 tree's dlls/win32u).
              WINE_DISPLAY_LOG=<file> logs every display-device update: forced or not,
              why, from where, and how long it took.
  winemac     runtime/source/wine-winemac (the shipped mouselook driver, i.e.
              runtime/source/wine-mouselook). macOS re-announces the game as active on
              every left click; the driver re-synchronised Wine's display list each
              time (~16 ms on the game's main thread). It now does so only after the
              application had actually resigned active. The fullscreen canvas keeps its
              letterbox bars black, caps its drawable at the screen's own pixels, and
              answers the game's window moves with the canvas frame, so Wine's window stays
              where the canvas draws it (cursor clipping and pointer positions depend on it).
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import re
import shutil
import struct
import subprocess

from build_mouselook_driver import (BASE, ENV, LDFLAGS, PHASE2, PRISTINE, ROOT, TREE, expand, links, recipe,
                                    rpaths, run, sha, unsigned_copy, without_linkedit_vmsize)

ARTIFACT = PHASE2 / 'artifacts/phase2-20260927.1'
COMPONENTS = {
    'wineserver': dict(rule='server/wineserver', directory='server', pristine=PRISTINE,
                       source=ROOT / 'runtime/source/wine-server', archived='bin/wineserver',
                       rpaths=['@loader_path', '@loader_path/../lib', '@loader_path/../lib/wine/x86_64-unix'],
                       patch=ROOT / 'patches/wine-server-registry-save.patch'),
    'ntdll': dict(rule='dlls/ntdll/ntdll.so', directory='dlls/ntdll', pristine=BASE,
                  source=ROOT / 'runtime/source/wine-ntdll', archived='lib/wine/x86_64-unix/ntdll.so',
                  rpaths=['@loader_path', '@loader_path/../..'],
                  patch=ROOT / 'patches/wine-ntdll-syscall-log.patch'),
    'win32u': dict(rule='dlls/win32u/win32u.so', directory='dlls/win32u', pristine=BASE,
                   source=ROOT / 'runtime/source/wine-win32u', archived='lib/wine/x86_64-unix/win32u.so',
                   rpaths=['@loader_path', '@loader_path/../..'],
                   patch=ROOT / 'patches/wine-win32u-display-log.patch'),
    # The shipped driver is the mouselook build, not the Phase 2 tree's link output, so
    # --base checks the packaged file against the shipped one only.
    'winemac': dict(rule='dlls/winemac.drv/winemac.so', directory='dlls/winemac.drv',
                    pristine=ROOT / 'runtime/source/wine-mouselook', raw_check=False,
                    source=ROOT / 'runtime/source/wine-winemac', archived='lib/wine/x86_64-unix/winemac.so',
                    rpaths=['@loader_path', '@loader_path/../..'],
                    patch=ROOT / 'patches/wine-winemac-activation.patch'),
}
OUT = ROOT / 'runtime/build/wine-native'


def expand_braces(command, makefile):
    """Expand ${name} make variables (server/unicode.o gets -DBINDIR="${bindir}"); expand() handles $(...)."""
    def value(match):
        found = re.search(r'^' + re.escape(match.group(1)) + r' = (.*)$', makefile, re.M)
        if not found:
            raise RuntimeError('Phase 2 Makefile lacks ' + match.group(1))
        return found.group(1)
    for _ in range(10):
        expanded = re.sub(r'\$\{(\w+)\}', value, command)
        if expanded == command:
            return command
        command = expanded
    raise RuntimeError('Make variables nest too deeply in: ' + command)


def without_uuid(data):
    """Mach-O bytes with LC_UUID zeroed."""
    data = bytearray(data)
    magic, _, _, _, ncmds, _, _, _ = struct.unpack_from('<8I', data, 0)
    if magic != 0xfeedfacf:
        raise ValueError('Not a 64-bit Mach-O file')
    offset = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<2I', data, offset)
        if cmd == 0x1b:
            data[offset + 8:offset + 24] = bytes(16)
        offset += size
    return bytes(data)


def objects(makefile, rule):
    deps = re.search(r'^' + re.escape(rule) + r':((?:[^\n]*\\\n)*[^\n]*)', makefile, re.M).group(1)
    return re.findall(r'(\S+)\.o\b', deps)


def compile_component(component, source, out):
    makefile = (TREE / 'Makefile').read_text()
    directory = component['directory']
    objdir = out / 'obj'
    prefix_map = ''
    if source != BASE:
        # Same reproducible-path treatment as the Phase 2 build: no developer paths in the binary.
        prefix_map = ' -ffile-prefix-map=' + str(source) + '=/build/overwatch-2-mac/sources/wine/sources/wine'

    def build(name):
        target = objdir / (name + '.o')
        target.parent.mkdir(parents=True, exist_ok=True)
        command = expand_braces(expand(recipe(makefile, name + '.o'), target, makefile), makefile)
        command = command.replace(str(BASE / directory) + '/', str(source / directory) + '/')
        command = command.replace('-I' + str(BASE / directory) + ' ', '-I' + str(source / directory) + ' ')
        result = subprocess.run(command + prefix_map, shell=True, cwd=TREE, env=ENV, capture_output=True, text=True)
        if result.returncode:
            raise RuntimeError(f'{name}.o failed to compile:\n' + result.stderr)
        own = [line for line in result.stderr.splitlines() if 'warning:' in line and 'deprecated' not in line]
        if own and source == component['source']:
            print('\n'.join(own), flush=True)
        return name

    names = objects(makefile, component['rule'])
    with ThreadPoolExecutor(max_workers=6) as pool:
        list(pool.map(build, names))
    raw = out / (Path(component['rule']).name + '.raw')
    link = expand(recipe(makefile, component['rule']), raw, makefile)
    for name in names:
        link = re.sub(re.escape(name) + r'\.o\b', str(objdir / (name + '.o')), link)
    subprocess.run(link, shell=True, cwd=TREE, env=ENV, check=True)
    return raw


def package(component, raw, final):
    """The assemble_portable_runtime.py treatment, minus Developer ID signing."""
    shutil.copy2(raw, final)
    run('/usr/bin/strip', '-S', '-x', final, stderr=subprocess.DEVNULL)
    for dep in links(final):
        if dep.startswith(('/usr/lib/', '/System/Library/', '@loader_path/', '@rpath/', '@executable_path/')):
            continue
        if Path(dep).name == 'libinotify.dylib':
            run('install_name_tool', '-change', dep, '@rpath/libinotify.dylib', final, stderr=subprocess.DEVNULL)
        else:
            raise ValueError('Unresolved non-system dependency: ' + dep)
    old = rpaths(final)
    for path in old:
        if path not in component['rpaths']:
            run('install_name_tool', '-delete_rpath', path, final, stderr=subprocess.DEVNULL)
    for path in component['rpaths']:
        if path not in old:
            run('install_name_tool', '-add_rpath', path, final, stderr=subprocess.DEVNULL)
    for value in (str(ROOT), '/Users/'):
        if value.encode() in final.read_bytes():
            raise ValueError('Development path remains in ' + final.name)
    return final


def write_patch(component):
    source = component['source']
    first = subprocess.check_output(['git', '-C', str(source), 'rev-list', '--max-parents=0', 'HEAD'], text=True).strip()
    diff = subprocess.run(['git', '-C', str(source), 'diff', '--no-color', '--src-prefix=a/', '--dst-prefix=b/', first,
                           '--', component['directory']], capture_output=True, text=True, check=True).stdout
    component['patch'].write_text(diff)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('component', choices=sorted(COMPONENTS))
    parser.add_argument('--base', action='store_true', help='Reproduce the shipped file from unmodified sources')
    args = parser.parse_args()
    component = COMPONENTS[args.component]
    shipped_raw = TREE / component['rule']
    archived = ARTIFACT / component['archived']
    for required in (TREE / 'Makefile', BASE / component['directory'], component['pristine'] / component['directory'],
                     archived, shipped_raw, Path(ENV['SDKROOT'])):
        if not required.exists():
            parser.error('Missing Phase 2 build input: ' + str(required))
    name = Path(component['rule']).name
    if args.base:
        out = OUT / args.component / 'base'
        if out.exists():
            shutil.rmtree(out)
        out.mkdir(parents=True)
        raw = compile_component(component, component['pristine'], out)
        final = package(component, raw, out / name)
        if component.get('raw_check', True) and without_uuid(raw.read_bytes()) != without_uuid(shipped_raw.read_bytes()):
            raise SystemExit(f'Base {name} link output differs from the Phase 2 build (beyond LC_UUID)')
        if (without_uuid(without_linkedit_vmsize(final)) !=
                without_uuid(without_linkedit_vmsize(unsigned_copy(archived, out / (name + '.archived-unsigned'))))):
            raise SystemExit(f'Base {name} differs from the shipped file after packaging (beyond LC_UUID)')
        run('/usr/bin/codesign', '--force', '--sign', '-', final, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        print(json.dumps({args.component: str(final), 'reproduced': True, 'raw_sha256': sha(raw)}, indent=2))
        return
    source = component['source']
    if not (source / component['directory']).is_dir():
        parser.error('Experiment sources are missing: ' + str(source / component['directory']))

    def snapshot():
        return {str(p): sha(p) for p in (source / component['directory']).rglob('*') if p.is_file()}
    before = snapshot()
    out = OUT / args.component / 'current'
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    raw = compile_component(component, source, out)
    final = package(component, raw, out / name)
    run('/usr/bin/codesign', '--force', '--sign', '-', final, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    run('/usr/bin/codesign', '--verify', '--strict', final)
    if before != snapshot():
        raise SystemExit('Sources changed during the build')
    write_patch(component)
    manifest = {'schema': 1, 'component': args.component, 'sha256': sha(final),
                'patch': str(component['patch'].relative_to(ROOT)), 'patch_sha256': sha(component['patch']),
                'base_sha256': sha(archived)}
    (out / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps({args.component: str(final), 'sha256': manifest['sha256'],
                      'patch': str(component['patch'])}, indent=2))


if __name__ == '__main__':
    main()
