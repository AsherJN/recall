"""ow2-pipeline's decisions, with stand-ins for its two Metal tools.

The archive is prepared after a session (--after-session); a launch only keeps what
was learned, warms the game app's cache and reports what that preparation added. A
failed archive (too large, or not covering every key the last one listed) must
lead to a smaller attempt, not end preparation for good; an archive listing
pipelines that have no recipe left is rebuilt, and so is one in a folder over the
game's save limit; an archive the tool did not save keeps the cache; past Recall's
budget the least recently used learned pipelines are forgotten; and the game app's
shader cache is warmed once per app, macOS version and GPU. Sparse files stand in
for hundreds of MiB. tests/run_native_pipeline.py runs the real tools. Needs swiftc
and a Metal device."""
import hashlib
import json
import os
import plistlib
import secrets
import shutil
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

# Prepares the selection, or the last archive's keys then the costliest others, and
# like the real tool saves nothing when the archive would hold more than `fit`
# pipelines or would drop a key the last one listed, and, without a failure, when
# its folder held over 512 - 128 MiB as it started (or with `nosave`). With
# `deadline`, the last pipeline is prepared too late to be captured.
PREPARE = r'''#!/usr/bin/python3
import hashlib, json, os, sys
from pathlib import Path
here = Path(sys.argv[0]).parent; env = os.environ
folder = next(p for p in Path(env['DXMT_PIPELINE_CACHE_PATH']).iterdir() if p.is_dir())
size = sum(f.lstat().st_size for f in folder.rglob('*') if f.is_file())
manifest = folder / 'archive.json'
previous = json.loads(manifest.read_text())['prepared_keys'] if manifest.exists() else []
limit = int(env['DXMT_PIPELINE_CACHE_PREWARM_LIMIT']); verify = env['DXMT_PIPELINE_CACHE_VERIFY_ONLY'] == '1'
with open(here / 'calls', 'a') as calls: calls.write(('verify' if verify else 'prepare') + ' %d\n' % limit)
if verify:
    print(json.dumps({'write_owner': True, 'verify_only': True, 'failures': 0, 'archive_failures': 0, 'prepared': len(previous)})); sys.exit()
costs = {f.stem: json.loads(f.read_text())['cost_us'] for f in (folder / 'recipes').glob('*.json')}
if env.get('DXMT_PIPELINE_CACHE_SELECTION'): order = json.loads(Path(env['DXMT_PIPELINE_CACHE_SELECTION']).read_text())
else: order = [k for k in previous if k in costs] + sorted((k for k in costs if k not in previous and costs[k] >= 16667), key=lambda k: -costs[k])
chosen = order[:limit]
captured = chosen[:-1] if (here / 'deadline').exists() else chosen
result = {'namespace_directory': str(folder), 'write_owner': True, 'prepared': len(chosen), 'captured_keys': captured, 'verify_only': False, 'archive_failures': 0}
if len(captured) > int((here / 'fit').read_text()) or not set(previous) <= set(captured): result['archive_failures'] = 1
elif size <= (512 - 128) * 1048576 and not (here / 'nosave').exists():
    data = json.dumps(captured).encode(); sha = hashlib.sha256(data).hexdigest()
    (folder / 'archives').mkdir(exist_ok=True); (folder / 'archives' / (sha + '.metallib')).write_bytes(data)
    manifest.write_text(json.dumps({'schema': 2, 'prepared_keys': captured,
        'archives': [{'sha256': sha, 'bytes': len(captured) * 150000, 'prepared_keys': captured}]}))
print(json.dumps(result))
'''
# "Compiles" each selected pipeline into the cache folder it is given.
WARM = r'''#!/usr/bin/python3
import json, os, sys
from pathlib import Path
folder, cache, selection, log, seconds = sys.argv[1:]
keys = json.loads(Path(selection).read_text())
Path(cache).mkdir(parents=True, exist_ok=True); (Path(cache) / 'functions.data').write_text('\n'.join(keys))
with open('%s-%d.jsonl' % (log, os.getpid()), 'w') as out:
    for key in keys: out.write(json.dumps({'event': 'prewarm', 'key': key, 'success': True, 'duration_us': 1500}) + '\n')
print(json.dumps({'attempted': len(keys), 'warmed': len(keys), 'failed': 0, 'complete': True, 'cache': cache}))
'''
IDENTITY = '#import <Metal/Metal.h>\nint main(void){@autoreleasepool{id<MTLDevice> d=MTLCreateSystemDefaultDevice();printf("%llu\\n%s\\n%s\\n",d.registryID,NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String,d.name.UTF8String);}return 0;}\n'


class PipelineHelper(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory(prefix='ow2-pipeline-helper-')
        build = Path(cls.build.name)
        subprocess.run(['/usr/bin/swiftc', '-target', 'arm64-apple-macos15.0', str(ROOT / 'scripts/portable_pipeline.swift'), '-o', str(build / 'ow2-pipeline')], check=True)
        (build / 'identity.m').write_text(IDENTITY)
        subprocess.run(['/usr/bin/clang', '-x', 'objective-c', '-fobjc-arc', str(build / 'identity.m'), '-framework', 'Foundation', '-framework', 'Metal', '-o', str(build / 'identity')], check=True)
        registry, cls.macos, cls.gpu = subprocess.run([str(build / 'identity')], capture_output=True, text=True, check=True).stdout.splitlines()
        cls.folder_name = hashlib.sha256(f'dxmt-render-cache-v1|ow2-source-v1|{cls.macos}|{registry}|{cls.gpu}'.encode()).hexdigest()
        cls.caches = Path(subprocess.run(['/usr/bin/getconf', 'DARWIN_USER_CACHE_DIR'], capture_output=True, text=True, check=True).stdout.strip())

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ow2-pipeline-helper-')
        self.base = Path(self.temp.name).resolve()
        self.addCleanup(self.temp.cleanup)
        self.helpers = self.base / 'Helpers'; self.helpers.mkdir()
        shutil.copy2(Path(self.build.name) / 'ow2-pipeline', self.helpers)
        for name, text in (('pipeline-prepare', PREPARE), ('pipeline-warm', WARM)):
            (self.helpers / name).write_text(text); (self.helpers / name).chmod(0o755)
        (self.helpers / 'fit').write_text('100000')
        self.root = self.base / 'User Directory With Spaces/Overwatch2Mac'
        self.folder = self.root / 'cache/pipelines' / self.folder_name
        for name in ('recipes', 'libraries', 'archives'): (self.folder / name).mkdir(parents=True)
        (self.root / 'home').mkdir()

    def recipes(self, count, cost=50000, age=0, library=0, shared=None):
        # library: each recipe's own library of that size; shared: a library it also uses.
        keys = [secrets.token_hex(32) for _ in range(count)]
        moment = time.time() - age
        for key in keys:
            recipe = {'vertex': {'library': self.library(library)} if library else {}}
            if shared: recipe['fragment'] = {'library': shared}
            path = self.folder / 'recipes' / (key + '.json')
            path.write_text(json.dumps({'recipe': recipe, 'cost_us': cost})); os.utime(path, (moment, moment))
        return keys

    def library(self, size):
        key = secrets.token_hex(32); self.pad(self.folder / 'libraries' / (key + '.air'), size)
        return key

    def pad(self, path, size):
        # Sparse: counted at its full size without taking the disk space.
        with open(path, 'wb') as file: file.truncate(size)

    def archive(self, keys, size_each, on_disk=None):
        data = json.dumps(keys).encode(); sha = hashlib.sha256(data).hexdigest()
        (self.folder / 'archives' / (sha + '.metallib')).write_bytes(data)
        if on_disk: self.pad(self.folder / 'archives' / (sha + '.metallib'), on_disk)
        (self.folder / 'archive.json').write_text(json.dumps({'schema': 2, 'prepared_keys': keys,
            'archives': [{'sha256': sha, 'bytes': len(keys) * size_each, 'prepared_keys': keys}]}))

    def learned_bytes(self):
        # What the game's folder holds besides the archive.
        return sum(f.stat().st_size for f in self.folder.rglob('*') if f.is_file()
                   and f.name != 'archive.json' and f.suffix != '.metallib')

    def run_helper(self, *extra, launch=False):
        # The archive is prepared after a session; a launch (with the game app) only
        # keeps what was learned and warms that app's cache.
        (self.helpers / 'calls').unlink(missing_ok=True)
        mode = [] if launch else ['--after-session']
        result = subprocess.run([str(self.helpers / 'ow2-pipeline'), *mode, str(self.root), *map(str, extra)], capture_output=True, text=True, timeout=120)
        steps = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
        calls = (self.helpers / 'calls').read_text().split('\n')[:-1] if (self.helpers / 'calls').exists() else []
        return result, steps, calls

    def prepared(self):
        return json.loads((self.folder / 'archive.json').read_text())['prepared_keys']

    def test_an_archive_too_large_to_save_is_tried_again_smaller(self):
        # A full archive is rebuilt to about 85% of the 128 MiB budget. The owner's
        # rebuild came out too large to save, and the count check then ended every
        # launch's preparation before the smaller retry.
        old = self.recipes(894, age=7 * 86400); new = self.recipes(400)
        self.archive(old, 149223)  # 133.4 MB, as the owner's was
        (self.helpers / 'fit').write_text('700')
        result, steps, calls = self.run_helper()
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(calls, ['prepare 764', 'prepare 573', 'verify 4096'])
        self.assertIn('Prepared and verified 573', result.stdout)
        self.assertEqual(len(self.prepared()), 573)
        self.assertEqual(steps[-1], {'graphics': 'done', 'ready': 573, 'added': 400, 'warmed': 0})
        self.assertEqual(len(list((self.folder / 'archives').glob('*.metallib'))), 1)

    def test_an_archive_listing_pipelines_without_recipes_is_rebuilt(self):
        # The game archives what it prewarms; when those recipes are gone, preparing
        # around them could never save, so the archive is rebuilt and grows.
        kept = self.recipes(16); others = self.recipes(1000)
        self.archive(kept + [secrets.token_hex(32) for _ in range(240)], 130000)
        result, steps, calls = self.run_helper()
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(calls[0], 'prepare 689')
        self.assertEqual(len(self.prepared()), 689)
        self.assertLessEqual(set(self.prepared()), set(kept + others))
        again, _, _ = self.run_helper()
        self.assertEqual(again.returncode, 0, again)
        self.assertGreater(len(self.prepared()), 689)

    def test_an_archive_over_the_save_limit_is_rebuilt_without_it(self):
        # The owner's cache on 10-09: an archive under 85% full in a folder over the
        # game's save limit. An extended archive was never saved, and every launch
        # prepared it again for nothing; the rebuild's clone leaves the old one out.
        old = self.recipes(778, cost=150000, age=7 * 86400); new = self.recipes(100, cost=200000)
        self.archive(old, 145823, on_disk=113450294)  # 108.2 MiB, 84.5% of 128 MiB
        self.pad(self.folder / 'padding', 300 * 1048576)  # recipes and libraries, as far as the game counts
        result, steps, calls = self.run_helper()
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(calls, ['prepare 828', 'verify 4096'])
        self.assertIn('Prepared and verified 828', result.stdout)
        self.assertLessEqual(set(new), set(self.prepared()))
        self.assertEqual(steps[-1], {'graphics': 'done', 'ready': 828, 'added': 100, 'warmed': 0})
        # Under Recall's budget, nothing learned is forgotten.
        self.assertNotIn('Forgot', result.stdout)
        self.assertEqual(len(list((self.folder / 'recipes').glob('*.json'))), 878)

    def test_past_the_budget_the_least_recently_used_are_forgotten(self):
        # Over 320 MiB learned, the least recently used day goes first, cheapest first,
        # down to 288 MiB. The archive's recipes, a library a kept recipe still uses
        # and a library no recipe names stay.
        mib = 1048576
        packed = self.recipes(10, cost=200000, age=20 * 86400, library=8 * mib); self.archive(packed, 150000)
        shared = self.library(8 * mib)
        recent = self.recipes(10, cost=2000, library=8 * mib) + self.recipes(9, cost=200000, library=8 * mib) + self.recipes(1, cost=200000, shared=shared)
        sharing = self.recipes(1, cost=1000, age=10 * 86400, shared=shared)
        cheap = self.recipes(5, cost=2000, age=10 * 86400, library=8 * mib)
        costly = sorted(self.recipes(5, cost=200000, age=10 * 86400, library=8 * mib))
        orphan = self.library(12 * mib)
        def library_of(key): return json.loads((self.folder / 'recipes' / (key + '.json')).read_text())['recipe']['vertex']['library']
        doomed = [library_of(key) for key in cheap + costly[:1]]
        self.assertGreater(self.learned_bytes(), 320 * mib)
        result, steps, calls = self.run_helper(launch=True)  # before the game, which learns into this room
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(calls, [])
        self.assertIn('Forgot 7 least recently used learned pipelines', result.stdout)
        left = {path.stem for path in (self.folder / 'recipes').glob('*.json')}
        self.assertEqual(left, set(packed + recent + costly[1:]))
        libraries = {path.stem for path in (self.folder / 'libraries').glob('*.air')}
        self.assertEqual(libraries & set(doomed), set())
        self.assertLessEqual({shared, orphan} | {library_of(key) for key in packed + costly[1:]}, libraries)
        self.assertLessEqual(self.learned_bytes(), 288 * mib)
        self.assertEqual(steps[0], {'graphics': 'learned', 'learned': 34, 'ready': 10})

    def test_learned_pipelines_too_large_for_any_archive_skip_preparation(self):
        # Over the save limit with what no recipe accounts for: forgetting could not
        # make room, so nothing is forgotten, and no archive could be saved, so the
        # tool never runs.
        old = self.recipes(10, cost=150000, age=86400); self.archive(old, 150000); self.recipes(10, cost=200000)
        self.pad(self.folder / 'padding', 390 * 1048576)
        result, steps, calls = self.run_helper()
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(calls, [])
        self.assertIn('not by recipes that can be forgotten', result.stdout)
        self.assertIn('leave no room to save an archive', result.stdout)
        self.assertEqual(len(list((self.folder / 'recipes').glob('*.json'))), 20)
        self.assertEqual(steps[-1], {'graphics': 'done', 'ready': 10, 'added': 0, 'warmed': 0})

    def test_an_archive_the_tool_did_not_save_keeps_the_cache(self):
        # The game skips a save without a failure. Preparation keeps what it had
        # instead of ending in a count mismatch, whether it extended the archive...
        old = self.recipes(50, age=7 * 86400); self.archive(old, 150000); self.recipes(20, cost=200000)
        (self.helpers / 'nosave').write_text('')
        result, steps, calls = self.run_helper()
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(calls, ['prepare 70'])
        self.assertIn('Archive not saved; existing cache kept', result.stdout)
        self.assertEqual(self.prepared(), old)
        self.assertEqual(steps[-1], {'graphics': 'done', 'ready': 50, 'added': 0, 'warmed': 0})
        # ...or rebuilt it (this one lists a pipeline without a recipe).
        self.archive(old + [secrets.token_hex(32)], 150000)
        result, steps, calls = self.run_helper()
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(calls, ['prepare 70'])
        self.assertIn('Archive not saved; existing cache kept', result.stdout)
        self.assertEqual(len(self.prepared()), 51)

    def test_a_pipeline_finished_after_the_deadline_is_not_a_mismatch(self):
        # The tool counts a pipeline it finished after its deadline as prepared but
        # does not capture it; the archive it saved is still a good one.
        old = self.recipes(50, age=7 * 86400); self.archive(old, 150000); self.recipes(20, cost=200000)
        (self.helpers / 'deadline').write_text('')
        result, steps, calls = self.run_helper()
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(calls, ['prepare 70', 'verify 4096'])
        self.assertIn('Prepared and verified 69', result.stdout)
        self.assertEqual(steps[-1], {'graphics': 'done', 'ready': 69, 'added': 19, 'warmed': 0})

    def test_a_launch_prepares_no_archive_and_reports_what_the_last_session_added(self):
        # Preparing takes minutes, so it happens after a session; a launch reports what
        # that added, once, without running the tool.
        old = self.recipes(50, age=7 * 86400); self.archive(old, 150000); self.recipes(20, cost=200000)
        result, steps, calls = self.run_helper(launch=True)
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(calls, [])
        self.assertIn('prepared after the session', result.stdout)
        self.assertEqual(steps, [{'graphics': 'learned', 'learned': 70, 'ready': 50},
                                 {'graphics': 'done', 'ready': 50, 'added': 0, 'warmed': 0}])
        result, steps, calls = self.run_helper()
        self.assertEqual(calls, ['prepare 70', 'verify 4096'])
        self.assertEqual(steps[-1], {'graphics': 'done', 'ready': 70, 'added': 20, 'warmed': 0})
        self.assertEqual(self.run_helper(launch=True)[1][-1], {'graphics': 'done', 'ready': 70, 'added': 20, 'warmed': 0})
        self.assertEqual(self.run_helper(launch=True)[1][-1], {'graphics': 'done', 'ready': 70, 'added': 0, 'warmed': 0})

    def test_the_game_apps_shader_cache_is_warmed_once_per_app_macos_and_gpu(self):
        identifier = 'org.overwatch2mac.helper-test-' + secrets.token_hex(4)
        cache = self.caches / identifier / 'com.apple.metal'
        self.addCleanup(shutil.rmtree, self.caches / identifier, True)
        app = self.base / 'Overwatch.app'; (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier}))
        keys = self.recipes(50)
        result, steps, _ = self.run_helper(app, launch=True)
        self.assertEqual(result.returncode, 0, result)
        self.assertIn('Warmed 50 learned pipelines for ' + identifier, result.stdout)
        self.assertEqual([s['graphics'] for s in steps][:3], ['learned', 'warming', 'pipelines'])
        self.assertEqual(steps[1], {'graphics': 'warming', 'target': 50})
        self.assertEqual(sum(len(s['items']) for s in steps if s['graphics'] == 'pipelines' and not s['items'][0][2]), 50)
        self.assertEqual(steps[-1]['warmed'], 50)
        self.assertEqual(sorted((cache / 'functions.data').read_text().split()), sorted(keys))
        marker = self.root / 'cache/warmed.json'
        self.assertEqual(json.loads(marker.read_text()), {'app': identifier, 'macos': self.macos, 'gpu': self.gpu})
        self.assertEqual(list((self.root / 'tmp').glob('warm-log-*')), [])
        # Warmed already: later sessions skip it.
        again, steps, _ = self.run_helper(app, launch=True)
        self.assertNotIn('warming', [s['graphics'] for s in steps])
        self.assertEqual(steps[-1]['warmed'], 0)
        # A macOS update, or macOS clearing its caches, starts it again.
        marker.write_text(json.dumps({'app': identifier, 'macos': 'Version 26.0 (Build 25A354)', 'gpu': self.gpu}))
        self.assertIn('Warmed 50', self.run_helper(app, launch=True)[0].stdout)
        shutil.rmtree(cache)
        self.assertIn('Warmed 50', self.run_helper(app, launch=True)[0].stdout)
        # Without Game Mode the game is not its own app: nothing to warm.
        marker.unlink()
        self.assertNotIn('warming', [s['graphics'] for s in self.run_helper(launch=True)[1]])

    def test_an_unusable_game_app_is_not_warmed(self):
        self.recipes(5)
        for identifier in ('../escape', '.hidden', 'a/b', ''):
            app = self.base / 'Overwatch.app'; shutil.rmtree(app, ignore_errors=True); (app / 'Contents').mkdir(parents=True)
            (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier}))
            result, steps, _ = self.run_helper(app, launch=True)
            self.assertEqual(result.returncode, 0, result)
            self.assertNotIn('warming', [s['graphics'] for s in steps], identifier)
        self.assertFalse((self.root / 'cache/warmed.json').exists())


if __name__ == '__main__':
    unittest.main()
