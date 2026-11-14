"""Synthetic exchange tests. No proprietary shaders or GPU compilation required."""
import hashlib
import json
import unittest
import test_portable_setup as setup
from build_portable_setup import build


def digest(data):
    return hashlib.sha256(data).hexdigest()


class ShaderShare(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        import tempfile
        from pathlib import Path
        cls.build_temp = tempfile.TemporaryDirectory(prefix='recall-share-tests-')
        cls.binary = Path(cls.build_temp.name) / 'ow2-setup'
        build(cls.binary, setup.ROOT / 'runtime/toolchains/libarchive-3.7.7', ('RECALL_SHADER_SHARE_FIXTURE',))

    tearDownClass = classmethod(setup.NativeSetup.tearDownClass.__func__)
    setUp = setup.NativeSetup.setUp
    call = setup.NativeSetup.call

    def initialize(self):
        self.call('status')
        (self.root / 'state.json').write_text(json.dumps({'active_runtime': 'test-runtime'}))
        engine = self.root / 'runtimes/test-runtime'
        engine.mkdir(parents=True)
        (engine / 'runtime.json').write_text('{}')
        self.cache = self.root / 'cache/pipelines/fixture-device'
        for group in ('recipes', 'libraries'):
            (self.cache / group).mkdir(parents=True, exist_ok=True)

    def recipe(self, label):
        air = ('synthetic AIR ' + label).encode()
        library = digest(air)
        recipe = {'schema': 1, 'vertex': {'library': library}, 'fragment': None}
        key = digest(json.dumps(recipe, sort_keys=True, separators=(',', ':')).encode())
        (self.cache / 'libraries' / (library + '.air')).write_bytes(air)
        path = self.cache / 'recipes' / (key + '.json')
        path.write_text(json.dumps({'recipe': recipe, 'cost_us': 1000}))
        return path

    def export(self, name):
        folder = self.base / name
        folder.mkdir()
        self.call('export-shaders', '--folder', folder)
        return folder

    def test_bidirectional_union_and_idempotent_import(self):
        self.initialize()
        first = self.recipe('first')
        folder = self.export('first-export')
        first_bytes = first.read_bytes()
        first.unlink()
        self.recipe('second')
        result = self.call('import-shaders', '--folder', folder)[-1]
        self.assertEqual(result['added'], 1)
        self.assertEqual(first.read_bytes(), first_bytes)
        self.assertEqual(len(list((self.cache / 'recipes').iterdir())), 2)
        self.assertEqual(self.call('import-shaders', '--folder', folder)[-1]['added'], 0)
        merged = self.export('merged-export')
        self.assertEqual(len(list((merged / 'recipes').iterdir())), 2)
        self.assertFalse((merged / 'archives').exists())

    def test_corrupt_library_rejected_before_merge(self):
        self.initialize()
        self.recipe('first')
        folder = self.export('export')
        next((folder / 'libraries').iterdir()).write_bytes(b'corrupt')
        self.assertEqual(self.call('import-shaders', '--folder', folder, success=False)[-1]['code'], 'shader_share_invalid')
        self.assertEqual(len(list((self.cache / 'recipes').iterdir())), 1)

    def test_incompatible_runtime_rejected(self):
        self.initialize()
        self.recipe('first')
        folder = self.export('export')
        manifest = folder / 'recall-shaders.json'
        data = json.loads(manifest.read_text())
        data['compatibility']['runtime'] = 'different'
        manifest.write_text(json.dumps(data))
        self.assertEqual(self.call('import-shaders', '--folder', folder, success=False)[-1]['code'], 'shader_share_incompatible')

    def test_symlink_and_nonempty_export_rejected(self):
        self.initialize()
        self.recipe('first')
        folder = self.export('export')
        self.assertEqual(self.call('export-shaders', '--folder', folder, success=False)[-1]['code'], 'shader_share_export_not_empty')
        library = next((folder / 'libraries').iterdir())
        library.unlink()
        library.symlink_to(self.base / 'outside')
        self.assertEqual(self.call('import-shaders', '--folder', folder, success=False)[-1]['code'], 'shader_share_invalid')

    def test_zip_import_preview_and_path_traversal_rejection(self):
        import zipfile
        self.initialize()
        self.recipe('first')
        folder = self.export('export')
        archive = self.base / 'shaders.zip'
        with zipfile.ZipFile(archive, 'w') as z:
            for path in folder.rglob('*'):
                if path.is_file():
                    z.write(path, path.relative_to(folder))
        preview = self.call('preview-shaders', '--folder', archive)[-1]
        self.assertTrue(preview['compatible'])
        self.assertIn('producer', preview['manifest'])
        self.assertEqual(self.call('import-shaders', '--folder', archive)[-1]['added'], 0)
        malicious = self.base / 'malicious.zip'
        with zipfile.ZipFile(malicious, 'w') as z:
            z.writestr('../outside', 'bad')
        self.assertEqual(self.call('import-shaders', '--folder', malicious, success=False)[-1]['code'], 'shader_share_invalid')
