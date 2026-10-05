import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import audit_public_source as audit
import prepare_public_snapshot as snapshot


class PublicSnapshot(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        self.manifest = {'files': []}
        for name in ('README.md', 'LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md'):
            data = ('Public source: ' + name + '\n').encode()
            (self.source / name).write_bytes(data)
            self.manifest['files'].append({'from': name, 'to': name,
                                          'sha256': hashlib.sha256(data).hexdigest()})

    def test_only_allowlisted_files_are_exported_and_existing_destination_is_preserved(self):
        (self.source / 'account.json').write_text('never export')
        dest = self.root / 'export'
        snapshot.export(self.source, self.manifest, dest)
        self.assertEqual({p.name for p in dest.iterdir()}, {'README.md', 'LICENSE', 'NOTICE', 'THIRD_PARTY_NOTICES.md'})
        with self.assertRaises(ValueError):
            snapshot.export(self.source, self.manifest, dest)
        self.assertTrue((dest / 'README.md').exists())

    def test_unfilled_placeholders_block_a_release_but_not_a_preview(self):
        # Built from parts so this test file, which is exported too, never matches.
        marker = '[' + 'TBD: average FPS]'
        data = ('Average FPS: ' + marker + '\n').encode()
        (self.source / 'README.md').write_bytes(data)
        self.manifest['files'][0]['sha256'] = hashlib.sha256(data).hexdigest()
        with self.assertRaisesRegex(ValueError, 'placeholder'):
            snapshot.plan(self.source, self.manifest)
        outputs = snapshot.plan(self.source, self.manifest, allow_placeholders=True)
        self.assertIn(marker.encode(), outputs['README.md'][0])
        dest = self.root / 'export'
        with self.assertRaises(ValueError):
            snapshot.export(self.source, self.manifest, dest)
        self.assertFalse(dest.exists())

    def test_changed_source_fails_before_creating_destination(self):
        (self.source / 'README.md').write_text('changed after review')
        dest = self.root / 'export'
        with self.assertRaises(ValueError):
            snapshot.export(self.source, self.manifest, dest)
        self.assertFalse(dest.exists())

    def test_traversal_duplicate_and_symlink_inputs_fail(self):
        for name in ('../README.md', '/tmp/README.md', 'logs/a.md', 'a/../b.md',
                     '.git/config', '.env', 'secret.pem', 'raw.csv'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                audit.inspect_path(name)
        self.manifest['files'].append(dict(self.manifest['files'][0]))
        with self.assertRaises(ValueError):
            snapshot.plan(self.source, self.manifest)
        self.manifest['files'].pop()
        (self.source / 'README.md').unlink()
        (self.source / 'README.md').symlink_to(self.source / 'LICENSE')
        with self.assertRaises(ValueError):
            snapshot.plan(self.source, self.manifest)

    def test_private_text_and_old_history_are_rejected_without_printing_values(self):
        for payload in (b'ghp_' + b'A' * 36, b'/Users/' + b'fixture/Desktop/x', b'x\0y'):
            with self.assertRaises(ValueError):
                audit.inspect_bytes('fixture', payload)
        dest = self.root / 'history';dest.mkdir()
        def git(*args):
            return subprocess.run(['git', '-C', str(dest), *args],check=True,capture_output=True)
        git('init', '-b', 'main')
        git('config', 'user.name', 'Fixture')
        git('config', 'user.email', 'fixture@example.invalid')
        git('config', 'commit.gpgsign', 'false')
        (dest / 'README.md').write_text('old confidential phrase')
        git('add', '.');git('commit', '-m', 'Initial fixture')
        (dest / 'README.md').write_text('clean now')
        git('add', '.');git('commit', '-m', 'Replace fixture')
        with self.assertRaises(ValueError):
            audit.audit_git(dest, forbidden=['confidential phrase'])

    def test_direct_tree_and_blob_refs_are_audited_outside_commit_ancestry(self):
        dest = self.root / 'direct-refs'
        dest.mkdir()
        def git(*args, data=None):
            return subprocess.run(['git', '-C', str(dest), *args], input=data,
                                  check=True, capture_output=True).stdout.strip()
        git('init', '-b', 'main')
        blob = git('hash-object', '-w', '--stdin', data=b'confidential fixture').decode()
        tree = git('mktree', data=('100644 blob ' + blob + '\tREADME.md\n').encode()).decode()
        for kind, oid in [('blob', blob), ('tree', tree)]:
            with self.subTest(kind=kind):
                git('update-ref', 'refs/audit/' + kind, oid)
                with self.assertRaises(ValueError):
                    audit.audit_git(dest, forbidden=['confidential fixture'])
                git('update-ref', '-d', 'refs/audit/' + kind)


if __name__ == '__main__':
    unittest.main()
