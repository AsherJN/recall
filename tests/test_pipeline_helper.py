"""ow2-pipeline's decisions, with stand-ins for its two Metal tools.

The pack is prepared after a session (--after-session); a launch only keeps what
was learned, warms the game app's cache and reports what that preparation added.
Since 1.4 every learned pipeline is prepared, slowest first, in batches that each
add an archive to the pack and are published one at a time: a batch holds up to
2048 pipelines or about 150 seconds of first builds. Small archives (the game's
own, a batch cut short) and damaged ones are built again into the next batch. A
pipeline finished past the tool's deadline waits for the next batch; one that
failed, for the next session. An archive the tool did not save keeps the cache.
Nothing learned is forgotten and no size limit applies. The game app's shader
cache is warmed once per app, macOS version and GPU. Sparse files stand in for
hundreds of MiB. tests/run_native_pipeline.py runs the real tools. Needs swiftc
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

# Like the real tool in append mode: loads the archives whose files match their
# hashes, builds the selection's pipelines (those with a recipe) up to the limit,
# captures the ones the pack lacks and adds them as one more archive. With
# `deadline` (used once) the last is finished too late to be captured; keys in
# `fail` fail to build; with `nosave` nothing is saved. Verification counts the
# selection's pipelines found in the loaded archives.
PREPARE = r'''#!/usr/bin/python3
import hashlib, json, os, sys
from pathlib import Path
here = Path(sys.argv[0]).parent; env = os.environ
folder = next(p for p in Path(env['DXMT_PIPELINE_CACHE_PATH']).iterdir() if p.is_dir())
manifest = folder / 'archive.json'
catalog = json.loads(manifest.read_text()) if manifest.exists() else {'archives': []}
loaded, archived, failures = [], set(), 0
for entry in catalog.get('archives', []):
    path = folder / 'archives' / (entry['sha256'] + '.metallib')
    if path.exists() and hashlib.sha256(path.read_bytes()).hexdigest() == entry['sha256']: loaded.append(entry); archived |= set(entry['prepared_keys'])
    else: failures += 1
assert env['DXMT_PIPELINE_CACHE_APPEND'] == '1' and env['DXMT_PIPELINE_CACHE_MIN_COST_US'] == '0'
selection = json.loads(Path(env['DXMT_PIPELINE_CACHE_SELECTION']).read_text())
limit = int(env['DXMT_PIPELINE_CACHE_PREWARM_LIMIT']); verify = env['DXMT_PIPELINE_CACHE_VERIFY_ONLY'] == '1'
with open(here / 'calls', 'a') as calls: calls.write(('verify' if verify else 'prepare') + ' %d\n' % len(selection))
with open(here / 'selections', 'a') as out: out.write(json.dumps(selection) + '\n')
if verify:
    found = [k for k in selection if k in archived]
    print(json.dumps({'write_owner': True, 'verify_only': True, 'failures': len(selection) - len(found), 'archive_failures': failures, 'prepared': len(found)})); sys.exit()
recipes = {f.stem for f in (folder / 'recipes').glob('*.json')}
failing = set((here / 'fail').read_text().split()) if (here / 'fail').exists() else set()
built = [k for k in selection if k in recipes][:limit]
built = [k for k in built if k not in failing]
late = (here / 'deadline').exists()
if late: (here / 'deadline').unlink()
captured = [k for k in built if k not in archived]
if late: captured = captured[:-1]
result = {'namespace_directory': str(folder), 'write_owner': True, 'prepared': len(built), 'captured_keys': captured,
          'verify_only': False, 'archive_failures': failures, 'deadline_exceeded': late}
if captured and not (here / 'nosave').exists():
    data = json.dumps(captured).encode(); sha = hashlib.sha256(data).hexdigest()
    (folder / 'archives').mkdir(exist_ok=True); (folder / 'archives' / (sha + '.metallib')).write_bytes(data)
    manifest.write_text(json.dumps({'schema': 2, 'prepared_keys': sorted(archived | set(captured)),
        'archives': loaded + [{'sha256': sha, 'bytes': len(captured) * 150000, 'prepared_keys': captured}]}))
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

    def archives(self, *groups, damaged=()):
        # One archive per group of keys, in order; a damaged one's file doesn't match its hash.
        entries = []
        for keys in groups:
            data = json.dumps(keys).encode(); sha = hashlib.sha256(data).hexdigest()
            (self.folder / 'archives' / (sha + '.metallib')).write_bytes(b'damaged' if keys in damaged else data)
            entries.append({'sha256': sha, 'bytes': len(data), 'prepared_keys': keys})
        (self.folder / 'archive.json').write_text(json.dumps({'schema': 2, 'archives': entries,
            'prepared_keys': sorted({k for keys in groups for k in keys})}))

    def catalog(self):
        return json.loads((self.folder / 'archive.json').read_text())

    def selections(self):
        path = self.helpers / 'selections'
        selections = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        path.unlink(missing_ok=True)
        return selections

    def test_every_learned_pipeline_is_prepared_in_batches(self):
        # 3000 quick pipelines beside a full archive: one batch of 2048, then the rest.
        old = self.recipes(600, cost=150000, age=7 * 86400); self.archives(old)
        new = self.recipes(3000, cost=1000)
        result, steps, calls = self.run_helper()
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(calls, ['prepare 2048', 'verify 2048', 'prepare 952', 'verify 952'])
        self.assertIn('Prepared and verified 2048 learned pipelines; 2648 of 3600 ready', result.stdout)
        self.assertIn('Prepared and verified 952 learned pipelines; 3600 of 3600 ready', result.stdout)
        self.assertEqual(set(self.prepared()), set(old + new))
        self.assertEqual([len(a['prepared_keys']) for a in self.catalog()['archives']], [600, 2048, 952])
        self.assertEqual(steps[-1], {'graphics': 'done', 'ready': 3600, 'added': 3000, 'warmed': 0})
        self.assertEqual([s['graphics'] for s in steps if s['graphics'] != 'pipelines'],
                         ['learned', 'checking', 'preparing', 'verifying', 'preparing', 'verifying', 'done'])
        self.assertFalse((self.root / 'cache/preparing.json').exists())
        again, steps, calls = self.run_helper()
        self.assertEqual((again.returncode, calls), (0, []))
        self.assertIn('Learned pipelines are up to date', again.stdout)

    def test_the_slowest_come_first_and_a_batch_holds_about_150_seconds(self):
        quick = self.recipes(100, cost=1000); slow = self.recipes(900, cost=200000)
        result, steps, calls = self.run_helper()
        self.assertEqual(result.returncode, 0, result)
        first, second = self.selections()[0::2]
        self.assertEqual(len(first), 750)  # 750 x 0.2 s
        self.assertLessEqual(set(first), set(slow))
        self.assertEqual(second[:150], [k for k in second if k in slow])
        self.assertEqual(set(self.prepared()), set(quick + slow))

    def test_small_and_damaged_archives_are_built_into_the_next_batch(self):
        # The game's own archives are small; one whose file is damaged is skipped by
        # the game. Both go into the next batch with what is new; a pipeline whose
        # recipe is gone can't be built again and leaves the pack.
        game = [self.recipes(100) for _ in range(3)]; damaged = self.recipes(700); full = self.recipes(600)
        gone = [secrets.token_hex(32) for _ in range(4)]
        self.archives(full, game[0], game[1] + gone, damaged, game[2], damaged=(damaged,))
        new = self.recipes(10)
        result, steps, calls = self.run_helper()
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(calls, ['prepare 1010', 'verify 1010'])
        self.assertEqual([len(a['prepared_keys']) for a in self.catalog()['archives']], [600, 1010])
        self.assertEqual(set(self.prepared()), set(full + sum(game, []) + damaged + new))
        self.assertEqual(sorted(p.name for p in (self.folder / 'archives').iterdir()),
                         sorted(a['sha256'] + '.metallib' for a in self.catalog()['archives']))
        # With nothing new, one small archive stays as it is, and two are merged.
        self.archives(full + damaged + new + game[0] + game[1], game[2])
        self.assertEqual(self.run_helper()[2], [])
        self.archives(full + damaged + new, game[0], game[1] + game[2])
        result, steps, calls = self.run_helper()
        self.assertEqual(calls, ['prepare 300', 'verify 300'])
        self.assertEqual([len(a['prepared_keys']) for a in self.catalog()['archives']], [1310, 300])

    def test_the_pack_is_kept_slowest_first_and_summarized_for_settings(self):
        # The game loads the pack's parts in order, as much as Shader memory allows, so a new
        # part of slower pipelines goes before one of faster pipelines (by recorded build time
        # per byte). Settings reads each part's size and count from cache/pack.json.
        fast = self.recipes(600, cost=20000)
        self.archives(fast)
        catalog = self.catalog(); catalog['archives'][0]['bytes'] = 600 * 150000
        (self.folder / 'archive.json').write_text(json.dumps(catalog))
        slow = self.recipes(600, cost=200000)
        result, steps, calls = self.run_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        parts = self.catalog()['archives']
        self.assertEqual([set(part['prepared_keys']) for part in parts], [set(slow), set(fast)])
        summary = json.loads((self.root / 'cache/pack.json').read_text())
        self.assertEqual(summary, {'schema': 1, 'parts': [[600 * 150000, 600], [600 * 150000, 600]]})
        # A launch writes it as well, and with no pack there is none.
        (self.root / 'cache/pack.json').unlink()
        self.assertEqual(self.run_helper(launch=True)[0].returncode, 0)
        self.assertEqual(json.loads((self.root / 'cache/pack.json').read_text()), summary)
        (self.folder / 'archive.json').unlink()
        self.run_helper(launch=True)
        self.assertFalse((self.root / 'cache/pack.json').exists())

    def test_nothing_learned_is_forgotten_and_no_size_limit_applies(self):
        # Before 1.4, over 320 MiB learned the least recently used were forgotten, and
        # over 384 MiB in the folder no archive was saved.
        old = self.recipes(600, cost=150000, age=20 * 86400, library=1048576); self.archives(old)
        new = self.recipes(40, cost=2000, age=10 * 86400)
        self.pad(self.folder / 'padding', 900 * 1048576)
        result, steps, calls = self.run_helper(launch=True)
        self.assertEqual(result.returncode, 0, result)
        self.assertNotIn('Forgot', result.stdout)
        result, steps, calls = self.run_helper()
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(calls, ['prepare 40', 'verify 40'])
        self.assertEqual(len(list((self.folder / 'recipes').glob('*.json'))), 640)
        self.assertEqual(len(self.prepared()), 640)

    def test_an_archive_the_tool_did_not_save_keeps_the_cache(self):
        old = self.recipes(600, age=7 * 86400); self.archives(old); self.recipes(20, cost=200000)
        (self.helpers / 'nosave').write_text('')
        result, steps, calls = self.run_helper()
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(calls, ['prepare 20'])
        self.assertIn('Archive not saved; existing cache kept', result.stdout)
        self.assertEqual(self.prepared(), sorted(old))
        self.assertEqual(steps[-1], {'graphics': 'done', 'ready': 600, 'added': 0, 'warmed': 0})

    def test_a_pipeline_finished_after_the_deadline_goes_into_the_next_batch(self):
        old = self.recipes(600, age=7 * 86400); self.archives(old); self.recipes(20, cost=200000)
        (self.helpers / 'deadline').write_text('')
        result, steps, calls = self.run_helper()
        self.assertEqual(result.returncode, 0, result)
        # The batch of 19 is small, so the next one builds it again with the last.
        self.assertEqual(calls, ['prepare 20', 'verify 19', 'prepare 20', 'verify 20'])
        self.assertIn('Prepared and verified 19', result.stdout)
        self.assertEqual([len(a['prepared_keys']) for a in self.catalog()['archives']], [600, 20])
        self.assertEqual(steps[-1], {'graphics': 'done', 'ready': 620, 'added': 20, 'warmed': 0})

    def test_a_pipeline_that_fails_to_build_waits_for_the_next_session(self):
        old = self.recipes(600, age=7 * 86400); self.archives(old); new = self.recipes(20, cost=200000)
        (self.helpers / 'fail').write_text(new[0])
        result, steps, calls = self.run_helper()
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(calls, ['prepare 20', 'verify 19'])
        self.assertEqual(steps[-1], {'graphics': 'done', 'ready': 619, 'added': 19, 'warmed': 0})
        (self.helpers / 'fail').unlink()
        result, steps, calls = self.run_helper()
        self.assertEqual(calls, ['prepare 20', 'verify 20'])
        self.assertEqual(len(self.prepared()), 620)

    def test_a_launch_prepares_no_archive_and_reports_what_the_last_session_added(self):
        # Preparing takes minutes, so it happens after a session; a launch reports what
        # that added, once, without running the tool.
        old = self.recipes(600, age=7 * 86400); self.archives(old); self.recipes(20, cost=200000)
        result, steps, calls = self.run_helper(launch=True)
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(calls, [])
        self.assertIn('prepared after the session', result.stdout)
        self.assertEqual(steps, [{'graphics': 'learned', 'learned': 620, 'ready': 600},
                                 {'graphics': 'done', 'ready': 600, 'added': 0, 'warmed': 0}])
        result, steps, calls = self.run_helper()
        self.assertEqual(calls, ['prepare 20', 'verify 20'])
        self.assertEqual(steps[-1], {'graphics': 'done', 'ready': 620, 'added': 20, 'warmed': 0})
        self.assertEqual(self.run_helper(launch=True)[1][-1], {'graphics': 'done', 'ready': 620, 'added': 20, 'warmed': 0})
        self.assertEqual(self.run_helper(launch=True)[1][-1], {'graphics': 'done', 'ready': 620, 'added': 0, 'warmed': 0})

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

    def test_after_a_session_every_learned_pipeline_is_warmed_every_time(self):
        # The game loads only part of a large pack (pipeline_cache.c), so after each
        # session every learned pipeline also goes into the game app's own shader cache,
        # after the pack's batches, whatever the once-per-macOS marker says.
        identifier = 'org.overwatch2mac.helper-test-' + secrets.token_hex(4)
        cache = self.caches / identifier / 'com.apple.metal'
        self.addCleanup(shutil.rmtree, self.caches / identifier, True)
        app = self.base / 'Overwatch.app'; (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier}))
        old = self.recipes(600, age=7 * 86400); self.archives(old); new = self.recipes(20, cost=200000)
        result, steps, calls = self.run_helper(app)
        self.assertEqual(result.returncode, 0, result)
        self.assertEqual(calls, ['prepare 20', 'verify 20'])
        self.assertIn('Warmed 620 learned pipelines for ' + identifier, result.stdout)
        self.assertLess(result.stdout.index('Prepared and verified'), result.stdout.index('Warmed'))
        self.assertEqual(sorted((cache / 'functions.data').read_text().split()), sorted(old + new))
        self.assertEqual(steps[-1], {'graphics': 'done', 'ready': 620, 'added': 20, 'warmed': 620})
        again, steps, calls = self.run_helper(app)
        self.assertEqual(calls, [])
        self.assertIn('Warmed 620', again.stdout)

    def test_without_game_mode_wines_own_loaders_cache_is_warmed(self):
        # Without Game Mode the game runs as Wine's own loader (REC-51), an x86_64 program whose
        # identifier is in its own file (CrossOver's loader embeds an Info.plist); macOS keeps its
        # compiled shaders apart from the game app's.
        identifier = 'org.overwatch2mac.helper-test-' + secrets.token_hex(4)
        cache = self.caches / identifier / 'com.apple.metal'
        self.addCleanup(shutil.rmtree, self.caches / identifier, True)
        info = self.base / 'loader-Info.plist'; info.write_bytes(plistlib.dumps({'CFBundleIdentifier': identifier}))
        loader = self.base / 'engine/lib/wine/x86_64-unix/wine'; loader.parent.mkdir(parents=True)
        subprocess.run(['/usr/bin/clang', '-arch', 'x86_64', '-x', 'c', '-', '-o', str(loader), f'-Wl,-sectcreate,__TEXT,__info_plist,{info}'],
                       input='int main(void){return 0;}\n', text=True, check=True)
        keys = self.recipes(30)
        result, steps, _ = self.run_helper(loader, launch=True)
        self.assertEqual(result.returncode, 0, result)
        self.assertIn('Warmed 30 learned pipelines for ' + identifier, result.stdout)
        self.assertEqual(sorted((cache / 'functions.data').read_text().split()), sorted(keys))
        self.assertEqual(json.loads((self.root / 'cache/warmed.json').read_text())['app'], identifier)
        # Switching Game Mode on names another program, whose cache is warmed in turn.
        other = 'org.overwatch2mac.helper-test-' + secrets.token_hex(4)
        self.addCleanup(shutil.rmtree, self.caches / other, True)
        app = self.base / 'Overwatch.app'; (app / 'Contents').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': other}))
        self.assertIn('Warmed 30 learned pipelines for ' + other, self.run_helper(app, launch=True)[0].stdout)
        # A program without an identifier of its own is not warmed.
        bare = self.base / 'bare'
        subprocess.run(['/usr/bin/clang', '-arch', 'x86_64', '-x', 'c', '-', '-o', str(bare)], input='int main(void){return 0;}\n', text=True, check=True)
        (self.root / 'cache/warmed.json').unlink()
        self.assertNotIn('warming', [s['graphics'] for s in self.run_helper(bare, launch=True)[1]])

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
