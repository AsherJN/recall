"""Runtime archives hold exactly runtime.json and the files it lists.

The setup worker refuses to install a runtime with any other file, so a stray
file in an artifact folder (Finder writes .DS_Store) must never be archived.
From 1.1 the engine's Mach-O files are re-stamped to require macOS 15; a
re-stamp changes only that field. 1.1 also adds the game app for macOS Game Mode,
a copy of the loader that differs from it only in its UUID. Its project license
becomes Apache 2.0 with a NOTICE, and nothing else changes.
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
