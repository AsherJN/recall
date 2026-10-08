"""Runtime archives hold exactly runtime.json and the files it lists.

The setup worker refuses to install a runtime with any other file, so a stray
file in an artifact folder (Finder writes .DS_Store) must never be archived.
From 1.1 the engine's Mach-O files are re-stamped to require macOS 15; a
re-stamp changes only that field. 1.1 also adds the game app for macOS Game Mode,
a copy of the loader that differs from it only in its UUID. Its project license
becomes Apache 2.0 with a NOTICE, and nothing else changes. 1.3 re-signs Wine's
loader and server with the microphone entitlement; nothing else changes. 1.3 also replaces
DXMT with its MetalFX upscaling build and adds the DLSS and NVAPI stand-ins.
"""
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import derive_runtime
from derive_runtime import (archive_minimum, check_archive, file_minimum, format_macos, parse_macos, restamp,
                            same_apart_from_minimum, write_archive)
import game_mode_app


class RuntimeArchive(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='ow2-runtime-archive-')
        self.addCleanup(temp.cleanup)
        self.runtime = Path(temp.name) / 'phase2-test'
        (self.runtime / 'bin').mkdir(parents=True)
        (self.runtime / 'share/empty').mkdir(parents=True)
        (self.runtime / 'bin/wine').write_text('wine')
        (self.runtime / 'bin/wine64').symlink_to('wine')
        manifest = {'version': 'phase2-test', 'files': {'bin/wine': {'sha256': 'x'}, 'bin/wine64': {'symlink': 'wine'}}}
        (self.runtime / 'runtime.json').write_text(json.dumps(manifest))

    def names(self, archive):
        with tarfile.open(archive) as tar:
            return sorted(tar.getnames())

    def test_unlisted_files_are_left_out_and_every_folder_is_kept(self):
        (self.runtime / '.DS_Store').write_text('finder')
        (self.runtime / 'bin/.DS_Store').write_text('finder')
        archive = write_archive(self.runtime)
        self.assertEqual(self.names(archive), ['bin', 'bin/wine', 'bin/wine64', 'runtime.json', 'share', 'share/empty'])
        self.assertEqual(check_archive(archive)['version'], 'phase2-test')

    def test_archive_with_an_unlisted_or_missing_file_is_refused(self):
        for name, extra in (('stray.tar.gz', '.DS_Store'), ('short.tar.gz', None)):
            archive = self.runtime.parent / name
            with tarfile.open(archive, 'w:gz') as tar:
                tar.add(self.runtime / 'runtime.json', arcname='runtime.json')
                tar.add(self.runtime / 'bin/wine64', arcname='bin/wine64')
                if extra:
                    tar.add(self.runtime / 'bin/wine', arcname='bin/wine')
                    (self.runtime / extra).write_text('finder')
                    tar.add(self.runtime / extra, arcname=extra)
            with self.assertRaises(ValueError):
                check_archive(archive)


class MinimumMacOS(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='ow2-minimum-macos-')
        self.addCleanup(temp.cleanup)
        self.folder = Path(temp.name)
        source = self.folder / 'probe.c'
        source.write_text('int probe(void) { return 1; }\n')
        self.library = self.folder / 'probe.dylib'
        subprocess.run(['/usr/bin/clang', '-arch', 'x86_64', '-mmacosx-version-min=26.0', '-dynamiclib', source,
                        '-o', self.library], check=True)

    def test_versions(self):
        self.assertEqual(parse_macos('15.0'), 0x0F0000)
        self.assertEqual(parse_macos('26'), 0x1A0000)
        self.assertEqual(parse_macos('15.4.1'), 0x0F0401)
        self.assertEqual(format_macos(0x1A0000), '26.0')
        self.assertEqual(format_macos(0x0F0401), '15.4.1')
        for bad in ('', '15.', 'v15', '15.256', '15.0.0.0'):
            with self.assertRaises(ValueError):
                parse_macos(bad)

    def test_restamp_lowers_only_the_minimum(self):
        copy = self.folder / 'restamped.dylib'
        shutil.copy2(self.library, copy)
        self.assertEqual(file_minimum(self.library)[1], parse_macos('26.0'))
        self.assertEqual(restamp(copy, parse_macos('15.0')), parse_macos('26.0'))
        self.assertEqual(file_minimum(copy)[1], parse_macos('15.0'))
        self.assertIsNone(restamp(copy, parse_macos('15.0')))
        self.assertIsNone(restamp(copy, parse_macos('26.0')))
        for path in (self.library, copy):
            subprocess.run(['codesign', '--force', '--sign', '-', path], check=True, capture_output=True)
        self.assertTrue(same_apart_from_minimum(self.library, copy))
        data = bytearray(copy.read_bytes())
        data[file_minimum(copy)[0] + 4] ^= 1  # the SDK version beside the minimum
        copy.write_bytes(data)
        self.assertFalse(same_apart_from_minimum(self.library, copy))

    def test_other_files_are_not_mach_o(self):
        text = self.folder / 'notes.txt'
        text.write_text('not a binary')
        self.assertIsNone(file_minimum(text))
        self.assertIsNone(restamp(text, parse_macos('15.0')))

    def test_archive_minimum_reads_every_mach_o_and_the_manifest(self):
        runtime = self.folder / 'phase2-test'
        (runtime / 'lib').mkdir(parents=True)
        shutil.copy2(self.library, runtime / 'lib/probe.dylib')
        (runtime / 'lib/notes.txt').write_text('text')
        manifest = {'version': 'phase2-test', 'minimum_macos': '26.0',
                    'files': {'lib/probe.dylib': {'sha256': 'x'}, 'lib/notes.txt': {'sha256': 'y'}}}
        (runtime / 'runtime.json').write_text(json.dumps(manifest))
        self.assertEqual(archive_minimum(write_archive(runtime)), (parse_macos('26.0'), '26.0'))
        restamp(runtime / 'lib/probe.dylib', parse_macos('15.0'))
        manifest['minimum_macos'] = '15.0'
        (runtime / 'runtime.json').write_text(json.dumps(manifest))
        Path(str(runtime) + '.tar.gz').unlink()
        self.assertEqual(archive_minimum(write_archive(runtime)), (parse_macos('15.0'), '15.0'))


class Relicense(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='ow2-relicense-')
        self.addCleanup(temp.cleanup)
        self.artifacts = Path(temp.name)
        original = derive_runtime.ARTIFACTS
        derive_runtime.ARTIFACTS = self.artifacts
        self.addCleanup(setattr, derive_runtime, 'ARTIFACTS', original)
        base = self.artifacts / 'base'
        (base / 'bin').mkdir(parents=True)
        (base / 'licenses').mkdir()
        (base / 'bin/wine').write_text('wine')
        (base / 'licenses/PROJECT-MIT').write_text('MIT License\n')
        (base / 'licenses/Wine-LGPL-2.1').write_text('LGPL\n')
        files = {name: {'sha256': derive_runtime.sha(base / name)} for name in
                 ('bin/wine', 'licenses/PROJECT-MIT', 'licenses/Wine-LGPL-2.1')}
        (base / 'runtime.json').write_text(json.dumps({'version': 'base', 'files': files}))
        write_archive(base)
        (self.artifacts / 'base.tar.json').write_text(json.dumps({'version': 'base', 'replaced': ['bin/wine']}))

    def test_only_the_project_license_changes(self):
        derive_runtime.relicense('base', 'next')
        archive = self.artifacts / 'next.tar.gz'
        manifest = check_archive(archive)
        with tarfile.open(archive) as tar:
            names = {m.name for m in tar.getmembers() if m.isfile()}
            notice = tar.extractfile('licenses/PROJECT-NOTICE').read()
            wine = tar.extractfile('bin/wine').read()
        self.assertEqual(names, {'runtime.json', 'bin/wine', 'licenses/Wine-LGPL-2.1',
                                 'licenses/PROJECT-APACHE-2.0', 'licenses/PROJECT-NOTICE'})
        self.assertEqual(notice, (derive_runtime.ROOT / 'licenses/PROJECT-NOTICE').read_bytes())
        self.assertEqual(wine, b'wine')
        self.assertEqual(list(manifest['derived_from']['removed']), ['licenses/PROJECT-MIT'])
        proof = json.loads((self.artifacts / 'next.tar.json').read_text())
        self.assertEqual((proof['removed'], proof['added'], 'replaced' in proof),
                         (['licenses/PROJECT-MIT'], ['licenses/PROJECT-APACHE-2.0', 'licenses/PROJECT-NOTICE'], False))

    def test_a_relicensed_base_or_an_existing_version_is_refused(self):
        derive_runtime.relicense('base', 'next')
        for base, version in (('next', 'again'), ('base', 'next')):
            with self.assertRaises(ValueError):
                derive_runtime.relicense(base, version)


class DerivationChain(unittest.TestCase):
    """A build of a patch starts from the file the chain had before any build of that patch."""
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='ow2-derivation-chain-')
        self.addCleanup(temp.cleanup)
        artifacts = Path(temp.name)
        original = derive_runtime.ARTIFACTS
        derive_runtime.ARTIFACTS = artifacts
        self.addCleanup(setattr, derive_runtime, 'ARTIFACTS', original)
        def runtime(version, files, derived=None):
            (artifacts / version).mkdir()
            manifest = {'version': version, 'files': {k: {'sha256': v} for k, v in files.items()}}
            if derived:
                manifest['derived_from'] = derived
            (artifacts / version / 'runtime.json').write_text(json.dumps(manifest))
        x, y = 'lib/x.so', 'lib/y.so'
        runtime('a', {x: 'x0', y: 'y0'})  # assembled
        runtime('b', {x: 'x1', y: 'y0'}, {'version': 'a', 'replaced': {x: {'patch': 'p'}}})
        runtime('c', {x: 'x1', y: 'y1'}, {'version': 'b', 'replaced': {y: {'patch': 'q'}}})  # leaves x alone
        runtime('d', {x: 'x2', y: 'y2'}, {'version': 'c', 'restamped': {x: {}, y: {}}})

    def test_derivations_that_left_the_file_alone_and_restamps_are_looked_through(self):
        self.assertEqual(derive_runtime.chain_original('d', 'lib/x.so', 'p'), 'x0')
        self.assertEqual(derive_runtime.chain_replacement('d', 'lib/x.so'), {'patch': 'p'})

    def test_a_replacement_by_another_patch_is_the_original(self):
        self.assertEqual(derive_runtime.chain_original('d', 'lib/y.so', 'p'), 'y1')
        self.assertEqual(derive_runtime.chain_original('d', 'lib/y.so', 'q'), 'y0')
        self.assertEqual(derive_runtime.chain_replacement('a', 'lib/y.so'), {})


class Controllers(unittest.TestCase):
    """1.2: winebus built with SDL2 replaces the base's; the SDL2 library (packaged as the
    assembler packages a dependency) and its license are added; nothing else changes."""
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='ow2-controllers-')
        self.addCleanup(temp.cleanup)
        folder = Path(temp.name)
        for name, value in (('ARTIFACTS', folder / 'artifacts'), ('NATIVE', folder / 'native'),
                            ('CLEAN_DEPS', folder / 'clean-deps')):
            self.addCleanup(setattr, derive_runtime, name, getattr(derive_runtime, name))
            setattr(derive_runtime, name, value)
        source = folder / 'probe.c'
        source.write_text('int probe(void) { return 1; }\n')

        def library(path, install_name, *rpaths):
            path.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['/usr/bin/clang', '-arch', 'x86_64', '-mmacosx-version-min=26.0', '-dynamiclib', source,
                            '-install_name', install_name, *[f'-Wl,-rpath,{r}' for r in rpaths], '-o', path], check=True)
            return path
        base = folder / 'artifacts/base'
        winebus = library(base / derive_runtime.WINEBUS, '@rpath/winebus.so', '@loader_path', '@loader_path/../..')
        (base / 'bin').mkdir(parents=True)
        (base / 'bin/wine').write_text('wine')
        files = {name: {'sha256': derive_runtime.sha(base / name)} for name in ('bin/wine', derive_runtime.WINEBUS)}
        (base / 'runtime.json').write_text(json.dumps({'version': 'base', 'minimum_macos': '15.0', 'files': files}))
        write_archive(base)
        (folder / 'artifacts/base.tar.json').write_text(json.dumps(
            {'version': 'base', 'signed_native_components': 1, 'dependency_names': ['libfreetype.6.dylib'],
             'removed': ['licenses/PROJECT-MIT'], 'resigned': ['bin/wine'], 'entitlement_added': 'microphone'}))
        self.sdl2 = library(folder / 'clean-deps/lib/libSDL2-2.0.0.dylib',
                            str(folder / 'clean-deps/lib/libSDL2-2.0.0.dylib'), str(folder / 'clean-deps/lib'))
        (folder / 'clean-deps/licenses/sdl2').mkdir(parents=True)
        (folder / 'clean-deps/licenses/sdl2/LICENSE.txt').write_text('zlib\n')
        built = library(folder / 'native/winebus/current/winebus.so', '@rpath/winebus.so', '@loader_path', '@loader_path/../..')
        subprocess.run(['/usr/bin/strip', '-x', built], check=True)  # differs from the base's file
        (built.parent / 'manifest.json').write_text(json.dumps(
            {'component': 'winebus', 'sha256': derive_runtime.sha(built), 'base_sha256': derive_runtime.sha(winebus),
             'sdl2': {'version': '2.32.10', 'library_sha256': derive_runtime.sha(self.sdl2), 'config_sha256': 'c'}}))
        self.artifacts = folder / 'artifacts'

    def test_winebus_is_replaced_and_sdl2_added_as_a_runtime_library(self):
        derive_runtime.derive_controllers('base', 'next', '-')
        manifest = check_archive(self.artifacts / 'next.tar.gz')
        self.assertEqual(sorted(manifest['files']), sorted(['bin/wine', derive_runtime.WINEBUS,
                                                           derive_runtime.SDL2_LIBRARY, derive_runtime.SDL2_LICENSE]))
        library = self.artifacts / 'next' / derive_runtime.SDL2_LIBRARY
        self.assertEqual(subprocess.check_output(['otool', '-D', str(library)], text=True).splitlines()[1],
                         '@rpath/libSDL2-2.0.0.dylib')
        rpaths = subprocess.check_output(['otool', '-l', str(library)], text=True)
        self.assertEqual(rpaths.count('cmd LC_RPATH'), 1)
        self.assertIn('path @loader_path (offset', rpaths)
        self.assertEqual(file_minimum(library)[1], parse_macos('15.0'))
        derived = manifest['derived_from']
        self.assertEqual(derived['replaced'][derive_runtime.WINEBUS]['sdl2']['version'], '2.32.10')
        self.assertEqual(sorted(derived['added']), [derive_runtime.SDL2_LIBRARY, derive_runtime.SDL2_LICENSE])
        proof = json.loads((self.artifacts / 'next.tar.json').read_text())
        self.assertEqual((proof['dependency_names'], proof['signed_native_components'], 'removed' in proof),
                         (['libSDL2-2.0.0.dylib', 'libfreetype.6.dylib'], 2, False))
        # The base's own records (here a microphone derivation's) are not this derivation's.
        self.assertEqual(('resigned' in proof, 'entitlement_added' in proof), (False, False))

    def test_another_sdl2_build_or_a_runtime_that_has_one_is_refused(self):
        derive_runtime.derive_controllers('base', 'next', '-')
        with self.assertRaises(ValueError):
            derive_runtime.derive_controllers('next', 'again', '-')
        subprocess.run(['/usr/bin/strip', '-x', self.sdl2], check=True)
        with self.assertRaises(ValueError):
            derive_runtime.derive_controllers('base', 'other', '-')

    def test_a_library_with_a_non_system_dependency_is_refused(self):
        other = self.sdl2.parent / 'libother.dylib'
        shutil.copy2(self.sdl2, other)
        subprocess.run(['install_name_tool', '-id', str(other), other], check=True)
        linked = self.sdl2.parent / 'linked.dylib'
        subprocess.run(['/usr/bin/clang', '-arch', 'x86_64', '-dynamiclib', str(other), '-x', 'c', '/dev/null',
                        '-o', linked], check=True)
        with self.assertRaises(ValueError):
            derive_runtime.package_dependency(linked)


class Microphone(unittest.TestCase):
    """1.3: the Wine loader and server gain the microphone entitlement, keeping their other
    entitlements and identifiers; the game app is made again from the loader and carries it too.
    Unsigned, nothing differs from the base."""
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='ow2-microphone-')
        self.addCleanup(temp.cleanup)
        folder = Path(temp.name)
        self.addCleanup(setattr, derive_runtime, 'ARTIFACTS', derive_runtime.ARTIFACTS)
        derive_runtime.ARTIFACTS = self.artifacts = folder / 'artifacts'
        base = self.artifacts / 'base'
        (folder / 'info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'com.codeweavers.CrossOver.wineloader', 'CFBundleExecutable': 'wineloader'}))
        (folder / 'main.c').write_text('int main(void) { return 0; }\n')
        (folder / 'entitlements.plist').write_bytes(plistlib.dumps({'com.apple.security.cs.allow-jit': True}))
        for relative, identifier, plist in (('bin/wine', 'wine', False), ('bin/wineserver', 'wineserver', False),
                                            (game_mode_app.LOADER, 'com.codeweavers.CrossOver.wineloader', True),
                                            ('lib/wine/x86_64-unix/other', 'other', False)):
            path = base / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['/usr/bin/clang', '-arch', 'x86_64', '-mmacosx-version-min=15.0', folder / 'main.c',
                            *(['-Wl,-sectcreate,__TEXT,__info_plist,' + str(folder / 'info.plist')] if plist else []),
                            '-o', path], check=True)
            entitled = [] if relative.endswith('other') else ['--entitlements', folder / 'entitlements.plist']
            subprocess.run(['codesign', '--sign', '-', '--options', 'runtime', '--identifier', identifier, *entitled,
                            path], check=True, capture_output=True)
        game_mode_app.make(base, '15.0')
        files = {str(p.relative_to(base)): {'sha256': derive_runtime.sha(p)} for p in base.rglob('*') if p.is_file()}
        (base / 'runtime.json').write_text(json.dumps({'version': 'base', 'minimum_macos': '15.0', 'files': files}))
        write_archive(base)
        (self.artifacts / 'base.tar.json').write_text(json.dumps({'version': 'base', 'replaced': ['x']}))

    def test_the_loader_server_and_game_app_gain_only_the_microphone_entitlement(self):
        derive_runtime.derive_microphone('base', 'next', '-')
        manifest = check_archive(self.artifacts / 'next.tar.gz')
        base, next_ = self.artifacts / 'base', self.artifacts / 'next'
        wanted = {'com.apple.security.cs.allow-jit': True, derive_runtime.MICROPHONE: True}
        for relative, identifier in (('bin/wine', 'wine'), ('bin/wineserver', 'wineserver'),
                                     (game_mode_app.LOADER, 'com.codeweavers.CrossOver.wineloader'),
                                     (game_mode_app.EXECUTABLE, 'org.overwatch2mac.overwatch')):
            self.assertEqual(derive_runtime.signature_of(next_ / relative), (identifier, wanted), relative)
            self.assertTrue(derive_runtime.unsigned_identical(base / relative, next_ / relative), relative)
        game_mode_app.check(next_)
        other = 'lib/wine/x86_64-unix/other'
        self.assertEqual(manifest['files'][other]['sha256'], derive_runtime.sha(base / other))
        self.assertEqual(manifest['derived_from']['entitlement_added'], derive_runtime.MICROPHONE)
        self.assertEqual(sorted(k for k, v in manifest['derived_from']['resigned'].items() if 'entitlement_added' in v),
                         ['bin/wine', 'bin/wineserver', game_mode_app.LOADER])
        proof = json.loads((self.artifacts / 'next.tar.json').read_text())
        self.assertEqual((proof['derived_from'], 'replaced' in proof), ('base', False))

    def test_a_runtime_that_already_has_it_is_refused(self):
        derive_runtime.derive_microphone('base', 'next', '-')
        with self.assertRaises(ValueError):
            derive_runtime.derive_microphone('next', 'again', '-')
        with self.assertRaises(ValueError):
            derive_runtime.derive_microphone('base', 'next', '-')


class MetalFX(unittest.TestCase):
    """1.3: the DXMT build with the MetalFX patch replaces the base's DXMT and Wine's d3d12.dll; the
    signed DLSS stand-in (byte for byte), the NVAPI stand-in and NVAPI's license are added; nothing
    else changes. DLL stripping and the Authenticode check are stubbed: they need LLVM-MinGW and
    Recall's certificate, which a fresh checkout lacks."""
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='ow2-metalfx-')
        self.addCleanup(temp.cleanup)
        folder = Path(temp.name)
        self.addCleanup(setattr, derive_runtime, 'ARTIFACTS', derive_runtime.ARTIFACTS)
        derive_runtime.ARTIFACTS = self.artifacts = folder / 'artifacts'
        real_package = derive_runtime.package_like_assembler
        for name, value in (('package_like_assembler', lambda path: None if path.suffix == '.dll' else real_package(path)),):
            self.addCleanup(setattr, derive_runtime, name, getattr(derive_runtime, name))
            setattr(derive_runtime, name, value)
        self.addCleanup(setattr, derive_runtime.sign_pe, 'check', derive_runtime.sign_pe.check)
        derive_runtime.sign_pe.check = lambda path, *rest: Path(path).read_bytes().endswith(b'SIGNED')
        (folder / 'probe.c').write_text('int probe(void) { return 1; }\n')

        def winemetal(path):
            path.parent.mkdir(parents=True, exist_ok=True)
            subprocess.run(['/usr/bin/clang', '-arch', 'x86_64', '-mmacosx-version-min=26.0', '-dynamiclib',
                            folder / 'probe.c', '-install_name', '@rpath/winemetal.so', '-Wl,-rpath,@loader_path',
                            '-Wl,-rpath,@loader_path/../..', '-o', path],
                           check=True)
        base = self.artifacts / 'base'
        windows = sorted({*derive_runtime.METALFX_REPLACED} - {'lib/wine/x86_64-unix/winemetal.so'})
        for relative in [*windows, 'bin/wine']:
            (base / relative).parent.mkdir(parents=True, exist_ok=True)
            (base / relative).write_bytes(b'base ' + relative.encode())
        winemetal(base / 'lib/wine/x86_64-unix/winemetal.so')
        files = {str(p.relative_to(base)): {'sha256': derive_runtime.sha(p)} for p in base.rglob('*') if p.is_file()}
        (base / 'runtime.json').write_text(json.dumps({'version': 'base', 'minimum_macos': '15.0', 'files': files}))
        write_archive(base)
        (self.artifacts / 'base.tar.json').write_text(json.dumps({'version': 'base', 'resigned': ['bin/wine']}))
        self.workspace = folder / 'dxmt'
        install = self.workspace / 'dxmt-install'
        for built in [*derive_runtime.METALFX_REPLACED.values(), *derive_runtime.METALFX_ADDED.values()]:
            (install / built).parent.mkdir(parents=True, exist_ok=True)
            (install / built).write_bytes(b'built ' + built.encode() + (b' SIGNED' if built.endswith('nvngx.dll') else b''))
        winemetal(install / 'x86_64-unix/winemetal.so')
        subprocess.run(['/usr/bin/strip', '-x', install / 'x86_64-unix/winemetal.so'], check=True)
        nvapi = self.workspace / 'dxmt-source/external/nvapi'
        nvapi.mkdir(parents=True)
        (nvapi / 'License.txt').write_text('SPDX-License-Identifier: MIT\n')
        self.proof = {'files': {str(p.relative_to(install)): derive_runtime.sha(p) for p in install.rglob('*') if p.is_file()},
                      'nvapi': 'd08488f', **{key: derive_runtime.sha(derive_runtime.ROOT / patch)
                                             for patch, key in derive_runtime.DXMT_PATCHES.items()}}
        (self.workspace / 'dxmt-build-proof.json').write_text(json.dumps(self.proof))

    def test_dxmt_is_replaced_and_the_stand_ins_added(self):
        derive_runtime.derive_metalfx('base', 'next', '-', self.workspace)
        manifest = check_archive(self.artifacts / 'next.tar.gz')
        base, next_ = self.artifacts / 'base', self.artifacts / 'next'
        added = sorted([*derive_runtime.METALFX_ADDED, derive_runtime.NVAPI_LICENSE])
        self.assertEqual(sorted(manifest['files']), sorted([*json.loads((base / 'runtime.json').read_text())['files'], *added]))
        self.assertEqual(sorted(manifest['derived_from']['replaced']), sorted(derive_runtime.METALFX_REPLACED))
        self.assertEqual(sorted(manifest['derived_from']['added']), added)
        # The DLSS stand-in is the signed build, byte for byte.
        self.assertEqual((next_ / derive_runtime.METALFX_NVNGX).read_bytes(),
                         (self.workspace / 'dxmt-install/x86_64-windows/nvngx.dll').read_bytes())
        self.assertEqual((next_ / 'lib/wine/x86_64-windows/d3d12.dll').read_bytes(), b'built x86_64-windows/d3d12.dll')
        self.assertEqual((next_ / 'bin/wine').read_bytes(), (base / 'bin/wine').read_bytes())
        self.assertEqual(file_minimum(next_ / 'lib/wine/x86_64-unix/winemetal.so')[1], parse_macos('15.0'))
        patches = manifest['derived_from']['replaced']['lib/wine/x86_64-windows/d3d12.dll']['patches']
        self.assertEqual(sorted(patches), sorted(derive_runtime.DXMT_PATCHES))
        proof = json.loads((self.artifacts / 'next.tar.json').read_text())
        self.assertEqual(sorted(proof['added']), added)
        self.assertNotIn('resigned', proof)

    def test_an_unsigned_stand_in_another_patch_or_a_runtime_that_has_it_is_refused(self):
        stand_in = self.workspace / 'dxmt-install/x86_64-windows/nvngx.dll'
        stand_in.write_bytes(b'unsigned')
        self.proof['files']['x86_64-windows/nvngx.dll'] = derive_runtime.sha(stand_in)
        (self.workspace / 'dxmt-build-proof.json').write_text(json.dumps(self.proof))
        with self.assertRaises(ValueError):
            derive_runtime.derive_metalfx('base', 'next', '-', self.workspace)
        stand_in.write_bytes(b'built SIGNED')
        self.proof['files']['x86_64-windows/nvngx.dll'] = derive_runtime.sha(stand_in)
        self.proof['metalfx_patch_sha256'] = '0' * 64
        (self.workspace / 'dxmt-build-proof.json').write_text(json.dumps(self.proof))
        with self.assertRaises(ValueError):
            derive_runtime.derive_metalfx('base', 'next', '-', self.workspace)
        self.proof['metalfx_patch_sha256'] = derive_runtime.sha(derive_runtime.ROOT / 'patches/dxmt-metalfx-upscaling.patch')
        (self.workspace / 'dxmt-build-proof.json').write_text(json.dumps(self.proof))
        derive_runtime.derive_metalfx('base', 'next', '-', self.workspace)
        with self.assertRaises(ValueError):
            derive_runtime.derive_metalfx('next', 'again', '-', self.workspace)


class GameModeApp(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix='ow2-game-mode-app-')
        self.addCleanup(temp.cleanup)
        self.engine = Path(temp.name) / 'engine'
        loader = self.engine / game_mode_app.LOADER
        loader.parent.mkdir(parents=True)
        folder = Path(temp.name)
        (folder / 'info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'com.codeweavers.CrossOver.wineloader', 'CFBundleName': 'CrossOver-Hosted Application',
            'CFBundleExecutable': 'wineloader', 'NSPrincipalClass': 'WineApplication', 'LSUIElement': '1'}))
        (folder / 'loader.c').write_text('#include <stdio.h>\nint main(int c, char **v) { puts(v[0]); return 0; }\n')
        subprocess.run(['/usr/bin/clang', '-arch', 'x86_64', '-mmacosx-version-min=15.0',
                        '-Wl,-sectcreate,__TEXT,__info_plist,' + str(folder / 'info.plist'), folder / 'loader.c',
                        '-o', loader], check=True)
        (folder / 'entitlements.plist').write_bytes(plistlib.dumps({'com.apple.security.cs.allow-jit': True}))
        subprocess.run(['codesign', '--sign', '-', '--options', 'runtime', '--entitlements',
                        folder / 'entitlements.plist', loader], check=True, capture_output=True)
        self.loader = loader

    def test_the_app_is_the_loader_with_a_game_info_plist_and_its_own_uuid(self):
        self.assertEqual(game_mode_app.make(self.engine, '15.0'), sorted(game_mode_app.FILES))
        bundle = self.engine / game_mode_app.BUNDLE
        info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        self.assertEqual((info['CFBundleIdentifier'], info['LSApplicationCategoryType'], info['LSSupportsGameMode']),
                         ('org.overwatch2mac.overwatch', 'public.app-category.action-games', True))
        self.assertEqual((info['NSPrincipalClass'], info['LSUIElement'], info['LSMinimumSystemVersion']),
                         ('WineApplication', '1', '15.0'))  # the loader's own keys stay
        loader, copy = self.loader.read_bytes(), (self.engine / game_mode_app.EXECUTABLE).read_bytes()
        at = game_mode_app.uuid_offset(loader)
        self.assertNotEqual(loader[at:at + 16], copy[at:at + 16])
        self.assertEqual(game_mode_app.entitlements_of(self.engine / game_mode_app.EXECUTABLE),
                         {'com.apple.security.cs.allow-jit': True})
        # Started with the usual loader's path as argv[0], as ntdll does.
        ran = subprocess.run(['/bin/bash', '-c', f'exec -a "{self.loader}" "{self.engine / game_mode_app.EXECUTABLE}"'],
                             capture_output=True, text=True, check=True)
        self.assertEqual(ran.stdout.strip(), str(self.loader))

    def test_a_changed_info_plist_or_second_app_is_refused(self):
        game_mode_app.make(self.engine, '15.0')
        with self.assertRaises(ValueError):
            game_mode_app.make(self.engine, '15.0')
        plist = self.engine / game_mode_app.BUNDLE / 'Contents/Info.plist'
        info = plistlib.loads(plist.read_bytes())
        info['LSApplicationCategoryType'] = 'public.app-category.utilities'
        plist.write_bytes(plistlib.dumps(info))
        with self.assertRaises(subprocess.CalledProcessError):
            game_mode_app.check(self.engine)


if __name__ == '__main__':
    unittest.main()
