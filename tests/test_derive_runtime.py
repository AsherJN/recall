"""Runtime archives hold exactly runtime.json and the files it lists.

The setup worker refuses to install a runtime with any other file, so a stray
file in an artifact folder (Finder writes .DS_Store) must never be archived.
"""
import json
from pathlib import Path
import sys
import tarfile
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from derive_runtime import check_archive, write_archive


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


if __name__ == '__main__':
    unittest.main()
