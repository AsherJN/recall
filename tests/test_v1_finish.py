import json
import hashlib
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from analyze_process_stalls import display_hitches,correlate
from hitch_capture import HitchCapture,trigger_reason,stack_section
from set_windowed_1080 import update_preferences,apply_preferences
import stage_v1
import launch_cx26

class V1Finish(unittest.TestCase):
    def test_launch_rejects_interrupted_install_and_mismatched_bridge(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);engine=root/'engine';prefix=root/'prefix'
            paths=[engine/'lib/wine/x86_64-windows',engine/'lib/wine/x86_64-unix',prefix/'drive_c/windows/system32',root/'logs/dxmt']
            for p in paths:p.mkdir(parents=True)
            (engine/'lib/wine/x86_64-windows/winemetal.dll').write_bytes(b'new')
            (engine/'lib/wine/x86_64-unix/winemac.so').write_bytes(b'driver')
            (engine/'local-build-manifest.json').write_text(json.dumps(dict(files={'x86_64-windows/winemetal.dll':hashlib.sha256(b'new').hexdigest()})))
            (engine/'v1-window-manifest.json').write_text(json.dumps(dict(driver_sha256=hashlib.sha256(b'driver').hexdigest())))
            (prefix/'drive_c/windows/system32/winemetal.dll').write_bytes(b'old')
            with patch.object(launch_cx26,'ROOT',root):
                with self.assertRaisesRegex(RuntimeError,'bridge versions'):launch_cx26.validate_source_runtime(engine,prefix,True)
                (prefix/'drive_c/windows/system32/winemetal.dll').write_bytes(b'new')
                launch_cx26.validate_source_runtime(engine,prefix,True)
                (root/'logs/dxmt/v1-stage.json').write_text('{"status":"installing"}')
                with self.assertRaisesRegex(RuntimeError,'interrupted'):launch_cx26.validate_source_runtime(engine,prefix,True)
                launch_cx26.validate_source_runtime(engine,prefix,True,allow_installing=True)

    def test_recovery_verifies_backups_and_handles_interrupted_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);backup=root/'backup';original=root/'original';prefix=root/'prefix'
            for p in [backup,original/'scripts',original/'config',prefix/'drive_c/users/Sikarugir/Documents/Overwatch/Settings']:p.mkdir(parents=True)
            (root/'library').write_bytes(b'candidate');(backup/'library').write_bytes(b'old')
            (original/'settings-before-v1.ini').write_text('[Render.13]\n')
            state=root/'state.json'
            data=dict(status='installing',backup=str(backup),pre_phase_backup=str(original),entries=[
                dict(path='library',existed=True,sha256=hashlib.sha256(b'old').hexdigest())])
            state.write_text(json.dumps(data))
            with patch.object(stage_v1,'ROOT',root),patch.object(stage_v1,'PREFIX',prefix),patch.object(stage_v1,'STATE',state),patch.object(stage_v1.launch,'stop_clients') as stopped:
                (backup/'library').write_bytes(b'tampered')
                with self.assertRaisesRegex(RuntimeError,'hash verification'):stage_v1.restore()
                stopped.assert_not_called();self.assertEqual((root/'library').read_bytes(),b'candidate')
                (backup/'library').write_bytes(b'old');stage_v1.restore()
            self.assertEqual((root/'library').read_bytes(),b'old')
            self.assertEqual(json.loads(state.read_text())['status'],'restored')

    def test_clock_jump_cannot_create_a_hitch_or_false_join(self):
        def row(seq,host,wall):return dict(native_pid='1',event='presented',sequence=str(seq),
            layer_ptr='1',event_host_s=str(host),unix_ms=str(wall*1000),presented_s=str(host),presented_state='valid')
        pairs,coverage=display_hitches([row(1,1,1001),row(2,1.1,1000.9),row(3,1.2,1001)],1,50)
        self.assertEqual(len(pairs),2)
        self.assertAlmostEqual(pairs[0]['duration_ms'],100)
        self.assertTrue(pairs[0]['clock_step_overlap'])
        bins=[dict(start_utc_s=1000.92,end_utc_s=1001),dict(start_utc_s=1000.8,end_utc_s=1000.9)]
        joined=correlate(bins,pairs,[])
        self.assertEqual(joined[0]['bins'],[])
        self.assertEqual(len(joined[1]['bins']),1)
        self.assertGreater(coverage['offset_spread_ms'],200)

    def test_replacement_recovery_verifies_configuration_and_restores_prior_stage(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);backup=root/'backup';original=root/'original';prefix=root/'prefix'
            for p in [backup,original/'scripts',original/'config',root/'scripts',root/'config',
                      prefix/'drive_c/users/Sikarugir/Documents/Overwatch/Settings']:p.mkdir(parents=True)
            (root/'library').write_bytes(b'new');(backup/'library').write_bytes(b'old')
            (original/'scripts/launch.py').write_text('old launcher')
            (root/'scripts/launch.py').write_text('new launcher')
            (original/'config/game.conf').write_text('old profile')
            (root/'config/game.conf').write_text('new profile')
            (original/'Test.command').write_text('saved launch flags')
            (root/'Test.command').write_text('new launch flags')
            (original/'settings-before-v1.ini').write_text('old preferences')
            state=root/'state.json';previous=dict(status='installed',generation=1)
            data=dict(status='installing',backup=str(backup),pre_phase_backup=str(original),previous_stage=previous,
                      entries=[dict(path='library',existed=True,sha256=hashlib.sha256(b'old').hexdigest())])
            with patch.object(stage_v1,'ROOT',root),patch.object(stage_v1,'PREFIX',prefix),patch.object(stage_v1,'STATE',state),patch.object(stage_v1.launch,'stop_clients') as stopped:
                data['configuration_entries']=stage_v1.configuration_entries(original)
                state.write_text(json.dumps(data))
                (original/'config/game.conf').write_text('damaged backup')
                with self.assertRaisesRegex(RuntimeError,'configuration failed hash'):stage_v1.restore()
                stopped.assert_not_called();self.assertEqual((root/'library').read_bytes(),b'new')
                (original/'config/game.conf').write_text('old profile')
                # Exercise the same restoration path used after an install fails.
                stage_v1.restore_snapshot(data,stage_v1.verify_recovery(data),failure=True)
                self.assertEqual((root/'library').read_bytes(),b'old')
                self.assertEqual((root/'scripts/launch.py').read_text(),'old launcher')
                self.assertEqual((root/'config/game.conf').read_text(),'old profile')
                self.assertEqual((root/'Test.command').read_text(),'saved launch flags')
                self.assertEqual(json.loads(state.read_text()),previous)
                self.assertEqual((prefix/'drive_c/users/Sikarugir/Documents/Overwatch/Settings/Settings_v0.ini').read_text(),'old preferences')

    def test_resolution_is_scoped_atomic_and_recoverable(self):
        original='[Input.1]\nX=1\n[Render.13]\nWindowedHeight="1080"\nFrameRateCap="90"\n'
        after,changes=update_preferences(original,1200)
        self.assertIn('WindowedHeight = "1200"',after)
        self.assertIn('FrameRateCap="90"',after)
        self.assertIn('FullScreenHeight = "1200"',after)
        self.assertIn('WindowMode = "0"',after)
        self.assertIn('UseCustomWorldScale = "1"',after)
        self.assertIn('DynamicRenderScale = "0"',after)
        self.assertEqual(update_preferences(after,1200),(after,{}))
        with tempfile.TemporaryDirectory() as t:
            p=Path(t)/'settings.ini';p.write_text(original)
            result=apply_preferences(p,Path(t)/'backups',1200)
            self.assertEqual(p.read_text(),after)
            self.assertEqual(Path(result['backup']).read_text(),original)

    def test_stack_header_removed_and_content_bounded(self):
        clean=stack_section('Command: private launch details\nCall graph:\n  game_function\nEnvironment: private\n')
        self.assertNotIn('private',clean)
        self.assertIn('game_function',clean)
        self.assertLessEqual(len(stack_section('Call graph:\n'+'x'*3_000_000)),2*1024*1024+1)
        self.assertIsNone(stack_section('No graph'))

    def test_counter_trigger_requires_valid_identity_and_sampling_interval(self):
        a=dict(pid=7,start_abstime=123,error=0,monotonic_ns=1_000_000_000,vm_swapouts=0)
        b=dict(a,monotonic_ns=1_100_000_000,vm_swapouts=300)
        self.assertEqual(trigger_reason(a,b),'system_paging')
        self.assertIsNone(trigger_reason(a,dict(b,start_abstime=124)))
        self.assertIsNone(trigger_reason(a,dict(b,vm_error=1)))
        self.assertIsNone(trigger_reason(a,dict(b,monotonic_ns=2_000_000_000)))

    def test_worker_keeps_only_sanitized_capture_and_checks_process_twice(self):
        class Probe:
            def __init__(self):self.calls=[]
            def sample(self,pid,start):self.calls.append((pid,start))
        probe=Probe()
        with tempfile.TemporaryDirectory() as tmp:
            def sample(args,**kwargs):
                Path(args[-1]).write_text('Command: private\nCall graph:\n   wait_for_fixture\n')
                return type('Result',(),dict(returncode=0))()
            with patch('hitch_capture.subprocess.run',side_effect=sample):
                capture=HitchCapture(tmp,probe)
                capture.pending.put(dict(pid=7,start_abstime=123,number=1,reason='system_paging'))
                deadline=time.monotonic()+3
                while not capture.completed and time.monotonic()<deadline:time.sleep(.01)
                capture.close()
            self.assertEqual(probe.calls,[(7,123),(7,123)])
            self.assertEqual(capture.completed,1)
            self.assertFalse(list((Path(tmp)/'hitch-stacks').glob('*.raw')))
            record=json.loads((Path(tmp)/'hitch-stacks/01-7.json').read_text())
            self.assertEqual(record['status'],'captured')
            self.assertLessEqual(record['capture_start_monotonic_ns'],record['capture_end_monotonic_ns'])
            self.assertNotIn('private',(Path(tmp)/'hitch-stacks/01-7.txt').read_text())

    def test_progress_trigger_requires_focus_and_stale_valid_presentations(self):
        with tempfile.TemporaryDirectory() as tmp:
            capture=HitchCapture(tmp,None)
            root=Path(tmp)
            (root/'canvas-7.jsonl').write_text(json.dumps(dict(focused=True))+'\n')
            (root/'display-7.csv').write_text('event,presented_state,presented_s\npresented,valid,100\n')
            self.assertTrue(capture.progress_stale(7,102))
            self.assertFalse(capture.progress_stale(7,100.1))
            (root/'canvas-7.jsonl').write_text(json.dumps(dict(focused=False))+'\n')
            self.assertFalse(capture.progress_stale(7,102))
            capture.close()

if __name__=='__main__':unittest.main()
