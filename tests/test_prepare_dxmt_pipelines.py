import fcntl
import errno
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import types
import unittest
from unittest import mock

SPEC = importlib.util.spec_from_file_location('prepare_dxmt_pipelines_tested', Path(__file__).resolve().parents[1] / 'scripts/prepare_dxmt_pipelines.py')
MOD = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MOD)


class PreparationPublicationSafetyTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.cache = self.root/'runtime/cache'
        self.directory = self.cache/('a'*64)
        for path in (self.directory/'recipes', self.directory/'libraries', self.directory/'archives',
                     self.root/'runtime/build', self.root/'runtime/build-history'):
            path.mkdir(parents=True)
        self.old, self.new = 'b'*64, 'c'*64
        for key in (self.old,self.new):
            (self.directory/'recipes'/f'{key}.json').write_text(json.dumps({'cost_us':30000,'recipe':key}))
        (self.directory/'libraries'/('d'*64+'.air')).write_bytes(b'learned fixture AIR')
        old_hash = hashlib.sha256(b'old archive').hexdigest()
        (self.directory/'archives'/f'{old_hash}.metallib').write_bytes(b'old archive')
        (self.directory/'archive.json').write_text(json.dumps({'prepared_keys':[self.old],
            'archives':[{'sha256':old_hash,'prepared_keys':[self.old],'bytes':11}]}))
        self.baseline = self.inventory(self.directory)
        self.failure = None
        self.calls = []
        for patch in (mock.patch.object(MOD,'ROOT',self.root), mock.patch.object(MOD,'CACHE',self.cache),
                      mock.patch.object(MOD,'validate_helper'), mock.patch.object(MOD,'game_running',return_value=False),
                      mock.patch.object(MOD.shutil,'disk_usage',return_value=types.SimpleNamespace(free=4*2**30)),
                      mock.patch.object(MOD,'run_helper',side_effect=self.helper)):
            patch.start();self.addCleanup(patch.stop)

    @staticmethod
    def inventory(path):
        return {str(p.relative_to(path)):p.read_bytes() for p in path.rglob('*') if p.is_file() and p.name!='write.lock'}

    def helper(self, cache, output, mode, **kwargs):
        self.calls.append(mode)
        directory=cache/self.directory.name
        selected=[self.new] if self.failure=='lost_coverage' else [self.old,self.new]
        if 'selection' in kwargs:
            selected = kwargs['selection']
        elif mode == 'verify':
            selected = list(MOD.archive_keys(directory))
        data=b'new verified archive'
        digest=hashlib.sha256(data).hexdigest()
        if mode=='prepare':
            (directory/'archives'/f'{digest}.metallib').write_bytes(data if self.failure!='bad_archive_hash' else b'wrong')
            (directory/'archive.json').write_text(json.dumps({'prepared_keys':selected,
                'archives':[{'sha256':digest,'prepared_keys':selected,'bytes':len(data)}]}))
            if self.failure=='recipe_changed':
                (directory/'recipes'/f'{self.old}.json').write_text('changed')
        return {'namespace_directory':str(directory if self.failure!='wrong_namespace' else cache/'other'),
                'write_owner':True, 'prepared':len(selected), 'failures':int(self.failure=='verification_failed' and mode=='verify'),
                'archive_failures':int(self.failure=='archive_failed'), 'verify_only':mode=='verify',
                'archive_bytes':len(data)}

    def assert_original(self):
        self.assertEqual(self.inventory(self.directory),self.baseline)

    def test_full_archive_with_equal_value_skips_without_native_attempt(self):
        manifest_path=self.directory/'archive.json'
        manifest=json.loads(manifest_path.read_text())
        manifest['archives'][0]['bytes']=MOD.ARCHIVE_STOP_BYTES
        manifest_path.write_text(json.dumps(manifest))
        before=self.inventory(self.directory)
        result=MOD.prepare_before_launch()
        self.assertEqual(result['status'],'up_to_date')
        self.assertIn('comparable',result['reason'])
        self.assertEqual(self.calls,[])
        self.assertEqual(self.inventory(self.directory),before)

    def configure_refresh(self):
        manifest_path = self.directory/'archive.json'
        manifest = json.loads(manifest_path.read_text())
        manifest['archives'][0]['bytes'] = MOD.ARCHIVE_STOP_BYTES
        manifest_path.write_text(json.dumps(manifest))
        (self.directory/'recipes'/f'{self.old}.json').write_text(json.dumps({'cost_us':1000,'recipe':self.old}))
        (self.directory/'recipes'/f'{self.new}.json').write_text(json.dumps({'cost_us':100000,'recipe':self.new}))

    def test_refresh_replaces_prepared_subset_preserves_all_learning_and_backup(self):
        self.configure_refresh()
        baseline = self.inventory(self.directory)
        self.failure = 'lost_coverage'  # Deliberately replace old prepared key.
        native = MOD.run_helper.side_effect
        def inspect_clone(cache, output, mode, **kwargs):
            candidate = cache/self.directory.name
            if mode == 'prepare':
                self.assertFalse((candidate/'archive.json').exists())
                self.assertEqual(list((candidate/'archives').glob('*.metallib')), [])
                for group in ['recipes','libraries']:
                    for path in (self.directory/group).iterdir():
                        self.assertEqual(path.read_bytes(), (candidate/group/path.name).read_bytes())
            return native(cache, output, mode, **kwargs)
        MOD.run_helper.side_effect = inspect_clone
        result = MOD.prepare_before_launch()
        self.assertEqual(result['status'], 'prepared')
        self.assertEqual(result['policy'], 'refresh')
        self.assertEqual(result['retired_prepared_keys'], 1)
        self.assertEqual(MOD.archive_keys(self.directory), {self.new})
        self.assertEqual(self.inventory(Path(result['backup'])/self.directory.name), baseline)
        self.assertEqual(self.calls, ['prepare', 'verify'])

    def test_failed_refresh_preserves_active_archive_and_is_not_retried_unchanged(self):
        self.configure_refresh()
        baseline = self.inventory(self.directory)
        self.failure = 'archive_failed'
        result = MOD.prepare_before_launch()
        self.assertEqual(result['status'], 'skipped')
        after = self.inventory(self.directory)
        self.assertEqual({k:v for k,v in after.items() if k!='refresh-decision.json'}, baseline)
        before_calls = len(self.calls)
        result = MOD.prepare_before_launch()
        self.assertEqual(result['status'], 'up_to_date')
        self.assertEqual(len(self.calls), before_calls)
        (self.directory/'recipes'/f'{self.new}.json').write_text(json.dumps({'cost_us':110000,'recipe':self.new}))
        MOD.prepare_before_launch()
        self.assertGreater(len(self.calls), before_calls)

    def test_refresh_rejects_changed_learning_before_publication(self):
        self.configure_refresh()
        before = self.inventory(self.directory)
        self.failure = 'recipe_changed'
        with self.assertRaisesRegex(RuntimeError, 'learned recipe'):
            MOD.prepare_before_launch()
        self.assertEqual(self.inventory(self.directory), before)

    def test_archive_failure_halves_only_added_keys_and_reclones(self):
        native=MOD.run_helper.side_effect
        limits=[];fresh=[]
        def fail_then_succeed(cache,output,mode,**kwargs):
            directory=cache/self.directory.name
            if mode=='prepare':
                limits.append(kwargs['limit'])
                fresh.append(not (directory/'failed-attempt-marker').exists())
            result=native(cache,output,mode,**kwargs)
            if mode=='prepare' and len(limits)<3:
                result['archive_failures']=1
                (directory/'failed-attempt-marker').write_bytes(b'failed clone')
            return result
        MOD.run_helper.side_effect=fail_then_succeed
        with mock.patch.object(MOD,'candidate_count',return_value=8):
            result=MOD.prepare_before_launch()
        self.assertEqual(limits,[9,5,3])
        self.assertEqual(fresh,[True,True,True])
        self.assertEqual([a['limit'] for a in result['attempts']],limits)
        self.assertEqual(result['status'],'prepared')
        self.assertFalse((self.directory/'failed-attempt-marker').exists())
        self.assertEqual(MOD.archive_keys(self.directory),{self.old,self.new})

    def test_archive_failure_stops_after_three_attempts(self):
        self.failure='archive_failed'
        with mock.patch.object(MOD,'candidate_count',return_value=100):
            result=MOD.prepare_before_launch()
        self.assertEqual(result['status'],'skipped')
        self.assertEqual([a['limit'] for a in result['attempts']],[101,51,26])
        self.assertEqual(self.calls,['prepare']*3)
        self.assert_original()

    def test_plain_missing_dependency_without_expansion_does_not_retry(self):
        native=MOD.run_helper.side_effect
        def no_expansion(cache,output,mode,**kwargs):
            result=native(cache,output,mode,**kwargs)
            if mode=='prepare':
                path=cache/self.directory.name/'archive.json'
                path.write_bytes(self.baseline['archive.json'])
                result.update(failures=1,prepared=1,archive_failures=0)
            return result
        MOD.run_helper.side_effect=no_expansion
        with mock.patch.object(MOD,'candidate_count',return_value=100):
            result=MOD.prepare_before_launch()
        self.assertEqual(result['status'],'skipped')
        self.assertEqual(self.calls,['prepare'])
        self.assertEqual(len(result['attempts']),1)
        self.assert_original()

    def test_running_game_blocks_before_helper(self):
        MOD.game_running.return_value=True
        with self.assertRaises(MOD.PipelinePreparationUnsafeError): MOD.prepare_before_launch()
        self.assertEqual(self.calls,[]);self.assert_original()

    def test_existing_writer_lease_blocks(self):
        with (self.directory/'write.lock').open('a') as lease:
            fcntl.flock(lease,fcntl.LOCK_EX|fcntl.LOCK_NB)
            with self.assertRaises(MOD.PipelinePreparationUnsafeError): MOD.prepare_before_launch()
        self.assertEqual(self.calls,[]);self.assert_original()

    def test_missing_coverage_or_archive_failure_never_publishes(self):
        for failure in ('lost_coverage','archive_failed'):
            self.failure=failure
            self.assertEqual(MOD.prepare_before_launch()['status'],'skipped')
            self.assert_original()
        self.assertNotIn('verify',self.calls)

    def test_validation_failures_never_publish(self):
        for failure in ('wrong_namespace','verification_failed','recipe_changed','bad_archive_hash'):
            self.failure=failure
            with self.assertRaises(RuntimeError): MOD.prepare_before_launch()
            self.assert_original()

    def test_game_start_during_preparation_blocks_publication(self):
        MOD.game_running.side_effect=[False,False,True]
        with self.assertRaises(MOD.PipelinePreparationUnsafeError): MOD.prepare_before_launch()
        self.assertEqual(self.calls,['prepare','verify']);self.assert_original()

    def test_exchange_unsupported_or_failure_leaves_original(self):
        for code in (errno.ENOTSUP, errno.EIO):
            with mock.patch.object(MOD,'exchange_directories',side_effect=OSError(code,'injected exchange failure')):
                with self.assertRaises((OSError,RuntimeError)): MOD.prepare_before_launch()
            self.assert_original()

    def test_interrupt_after_atomic_exchange_preserves_both_caches(self):
        exchange=MOD.exchange_directories
        seen=[]
        def swap_then_interrupt(original,candidate):
            seen.append(Path(candidate))
            exchange(original,candidate)
            raise KeyboardInterrupt('injected immediately after successful atomic exchange')
        with mock.patch.object(MOD,'exchange_directories',side_effect=swap_then_interrupt):
            with self.assertRaises(MOD.PipelinePreparationUnsafeError) as raised: MOD.prepare_before_launch()
        self.assertEqual(len(seen),1)
        self.assertEqual(self.inventory(seen[0]),self.baseline)
        self.assertEqual(MOD.archive_keys(self.directory),{self.old,self.new})
        self.assertIn('pipeline-prepare-',str(raised.exception))

    def test_backup_move_failure_restores_original(self):
        rename=MOD.os.rename
        def fail_old_backup(source,target):
            if Path(source).parent.name=='cache' and 'pipeline-prepare-' in str(source):
                raise OSError('injected backup move failure')
            return rename(source,target)
        with mock.patch.object(MOD.os,'rename',side_effect=fail_old_backup):
            with self.assertRaises(RuntimeError): MOD.prepare_before_launch()
        self.assert_original()
        self.assertEqual(list((self.root/'runtime/build').glob('pipeline-prepare-*')),[])

    def test_restore_exchange_failure_is_unsafe_and_preserves_both_caches(self):
        exchange=MOD.exchange_directories
        exchanges=[]
        def fail_second_exchange(original,candidate):
            exchanges.append((Path(original),Path(candidate)))
            if len(exchanges)==2: raise OSError('injected rollback exchange failure')
            return exchange(original,candidate)
        rename=MOD.os.rename
        def fail_old_backup(source,target):
            if Path(source).parent.name=='cache' and 'pipeline-prepare-' in str(source):
                raise OSError('injected backup move failure')
            return rename(source,target)
        with mock.patch.object(MOD,'exchange_directories',side_effect=fail_second_exchange), \
             mock.patch.object(MOD.os,'rename',side_effect=fail_old_backup):
            with self.assertRaises(MOD.PipelinePreparationUnsafeError) as raised: MOD.prepare_before_launch()
        self.assertEqual(len(exchanges),2)
        recovery=exchanges[0][1]
        self.assertEqual(self.inventory(recovery),self.baseline)
        self.assertEqual(MOD.archive_keys(self.directory),{self.old,self.new})
        self.assertTrue(recovery.is_dir())
        self.assertIn('pipeline-prepare-',str(raised.exception))

    def test_success_preserves_rollback_and_learned_files(self):
        report=MOD.prepare_before_launch()
        self.assertEqual(report['status'],'prepared')
        self.assertEqual((report['added_keys'],report['verified_keys']),(1,2))
        self.assertEqual(self.inventory(Path(report['backup'])/self.directory.name),self.baseline)
        self.assertEqual(MOD.archive_keys(self.directory),{self.old,self.new})
        for name,data in self.baseline.items():
            if name.startswith(('recipes/','libraries/')): self.assertEqual((self.directory/name).read_bytes(),data)
        self.assertEqual(len(list((self.directory/'archives').glob('*.metallib'))),1)

    def test_no_new_expensive_candidates_skips_without_helper(self):
        entry=self.directory/'recipes'/f'{self.new}.json'
        entry.write_text(json.dumps({'cost_us':1000}))
        self.assertEqual(MOD.prepare_before_launch()['status'],'up_to_date')
        self.assertEqual(self.calls,[])

    def test_budget_headroom_skips_without_helper(self):
        MOD.shutil.disk_usage.return_value=types.SimpleNamespace(free=2**30)
        self.assertEqual(MOD.prepare_before_launch()['status'],'skipped')
        self.assertEqual(self.calls,[]);self.assert_original()


class PreparationBudgetTests(unittest.TestCase):
    def limit(self, previous_count, archive_bytes, candidates):
        with tempfile.TemporaryDirectory() as folder:
            directory=Path(folder)
            if archive_bytes is not None:
                (directory/'archive.json').write_text(json.dumps({'archives':[{'bytes':archive_bytes}]}))
            return MOD.preparation_limit(directory,set(range(previous_count)),candidates)

    def test_real_measured_archive_estimates_bounded_growth(self):
        self.assertEqual(self.limit(512,80525808,1941),768)
        self.assertEqual(self.limit(768,116678592,1685),768)
        self.assertEqual(self.limit(512,80525808,10),522)

    def test_initial_batch_and_growth_caps(self):
        self.assertEqual(self.limit(0,None,9000),256)
        self.assertEqual(self.limit(0,None,7),7)
        self.assertEqual(self.limit(512,1,9000),1536)
        self.assertEqual(self.limit(MOD.MAX_PREPARED_KEYS-1,1,9000),MOD.MAX_PREPARED_KEYS)

    def test_near_full_archive_adds_no_keys(self):
        self.assertEqual(self.limit(800,MOD.ARCHIVE_STOP_BYTES,1000),800)
        self.assertGreater(self.limit(800,MOD.ARCHIVE_STOP_BYTES-1,1000),800)
        self.assertEqual(self.limit(800,128*2**20,1000),800)


class RealAtomicDirectoryExchangeTests(unittest.TestCase):
    def test_real_nonempty_directory_swap_and_restore(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);first=root/'original';second=root/'candidate'
            first.mkdir();second.mkdir()
            (first/'nested').mkdir();(first/'nested/recipe').write_bytes(b'original learned recipe')
            (second/'nested').mkdir();(second/'nested/recipe').write_bytes(b'verified prepared recipe')
            first_inode,second_inode=first.stat().st_ino,second.stat().st_ino
            MOD.exchange_directories(first,second)
            self.assertEqual((first.stat().st_ino,second.stat().st_ino),(second_inode,first_inode))
            self.assertEqual((first/'nested/recipe').read_bytes(),b'verified prepared recipe')
            self.assertEqual((second/'nested/recipe').read_bytes(),b'original learned recipe')
            MOD.exchange_directories(first,second)
            self.assertEqual((first.stat().st_ino,second.stat().st_ino),(first_inode,second_inode))
            self.assertEqual((first/'nested/recipe').read_bytes(),b'original learned recipe')

    def test_missing_exchange_target_preserves_existing_directory(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);first=root/'original';first.mkdir()
            (first/'recipe').write_bytes(b'original');inode=first.stat().st_ino
            with self.assertRaises(OSError): MOD.exchange_directories(first,root/'missing')
            self.assertEqual(first.stat().st_ino,inode)
            self.assertEqual((first/'recipe').read_bytes(),b'original')


class PreparationHelperIntegrityTests(unittest.TestCase):
    def test_source_or_binary_mismatch_refuses_helper(self):
        with tempfile.TemporaryDirectory() as folder:
            helper=Path(folder);(helper/'prepare').write_bytes(b'helper')
            expected=hashlib.sha256(b'helper').hexdigest()
            (helper/'manifest.json').write_text(json.dumps({'sources':{'native':'expected'},'files':{'prepare':expected}}))
            with mock.patch.object(MOD,'HELPER',helper), mock.patch.object(MOD,'source_hashes',return_value={'native':'changed'}):
                with self.assertRaisesRegex(RuntimeError,'current source'): MOD.validate_helper()
            (helper/'prepare').write_bytes(b'tampered')
            with mock.patch.object(MOD,'HELPER',helper), mock.patch.object(MOD,'source_hashes',return_value={'native':'expected'}):
                with self.assertRaisesRegex(RuntimeError,'hash mismatch'): MOD.validate_helper()

if __name__=='__main__': unittest.main()
