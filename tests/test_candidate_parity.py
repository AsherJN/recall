"""Exercise candidate migration through the compiled production worker."""
import json
import re
import unittest
import test_portable_setup as setup
from candidate_contract import load, launch_preferences, verify_generated
from set_windowed_1080 import update_preferences


def render_values(text):
    section=text.split('[Render.13]',1)[1].split('[',1)[0]
    return dict(re.findall(r'^\s*(\w+)\s*=\s*"([^"\r\n]*)"',section,re.M))


class CandidateParity(unittest.TestCase):
    setUpClass=classmethod(setup.NativeSetup.setUpClass.__func__)
    tearDownClass=classmethod(setup.NativeSetup.tearDownClass.__func__)
    setUp=setup.NativeSetup.setUp
    call=setup.NativeSetup.call

    def fixture(self, text=None):
        self.call('status')
        engine=self.root/'runtimes/v1'
        (engine/'bin').mkdir(parents=True)
        (engine/'runtime.json').write_text('{}')
        (self.root/'state.json').write_text(json.dumps({'schema':1,'active_runtime':'v1'}))
        prefix=self.root/'environment'
        prefix.mkdir()
        (prefix/'user.reg').write_text('[Software\\\\Wine\\\\Mac Driver]\n"RetinaMode"="Y"\n')
        profile=prefix/'drive_c/users/player'
        profile.mkdir(parents=True)
        self.path=profile/'Documents/Overwatch/Settings/Settings_v0.ini'
        if text is not None:
            self.path.parent.mkdir(parents=True)
            self.path.write_bytes(text.encode())
        return engine

    def test_fresh_profile_matches_candidate_contract(self):
        verify_generated()
        self.fixture()
        self.call('display','--height','1200')
        self.assertEqual(render_values(self.path.read_text()),launch_preferences()|load()['baseline_preferences'])

    def test_existing_choices_and_other_sections_survive_migration(self):
        original='[Render.13]\r\nFrameRateCap = "237"\r\nGFXPresetLevel = "3"\r\nDynamicRenderScale = "1"\r\n[Input.1]\r\nSensitivity = "9.5"\r\n[Account.1]\r\nKeep = "yes"\r\n'
        self.fixture(original)
        self.call('display','--height','1080')
        result=self.path.read_bytes().decode()
        self.assertIn(original.split('[Input.1]')[1],result)
        values=render_values(result)
        self.assertEqual(values['FrameRateCap'],'237')
        self.assertEqual(values['GFXPresetLevel'],'3')
        for key,value in launch_preferences(1080).items():self.assertEqual(values[key],value)
        self.assertEqual((self.root/'settings-backup/before-candidate-baseline.ini').read_bytes(),original.encode())
        before=self.path.stat().st_mtime_ns
        self.call('display','--height','1080')
        self.assertEqual(self.path.stat().st_mtime_ns,before)
        self.assertNotIn(b'\n',self.path.read_bytes().replace(b'\r\n',b''))

    def test_explicit_restore_matches_baseline_and_is_recoverable(self):
        original='[Render.13]\nFrameRateCap = "237"\nGFXPresetLevel = "3"\n[Input.1]\nSensitivity = "9.5"\n'
        self.fixture(original)
        self.call('restore-candidate')
        self.assertEqual(render_values(self.path.read_text()),launch_preferences()|load()['baseline_preferences'])
        self.assertIn('[Input.1]\nSensitivity = "9.5"',self.path.read_text())
        self.assertEqual((self.root/'settings-backup/before-candidate-restore.ini').read_text(),original)

    def test_both_heights_equal_legacy_launcher_preferences(self):
        self.fixture('[Render.13]\n')
        for height in (1080,1200):
            self.call('display','--height',str(height))
            legacy,_=update_preferences('[Render.13]\n',height)
            actual=render_values(self.path.read_text())
            for key,value in render_values(legacy).items():self.assertEqual(actual[key],value)

    def test_reapply_corrects_game_rewritten_fullscreen_mode(self):
        self.fixture('[Render.13]\n')
        self.call('display','--height','1200')
        self.path.write_text(self.path.read_text().replace('FullscreenWindowEnabled = "0"','FullscreenWindowEnabled = "1"'))
        self.call('display','--height','1200')
        self.assertEqual(render_values(self.path.read_text())['FullscreenWindowEnabled'],'0')

    def test_ambiguous_settings_rejected_without_changes(self):
        original='[Render.13]\nDynamicRenderScale = "0"\nDynamicRenderScale = "1"\n'
        self.fixture(original)
        self.assertEqual(self.call('display','--height','1200',success=False)[-1]['code'],'invalid_game_settings')
        self.assertEqual(self.path.read_text(),original)
        self.assertFalse((self.root/'settings-backup').exists())

    def test_report_records_actual_contract_without_personal_sections(self):
        engine=self.fixture('[Render.13]\n[Account.1]\nPrivate = "must-not-appear"\n')
        for name in ('bin/wine','bin/wineserver','lib/wine/x86_64-windows/d3d11.dll',
                     'lib/wine/x86_64-windows/dxgi.dll','lib/wine/x86_64-windows/winemetal.dll',
                     'lib/wine/x86_64-unix/winemetal.so','lib/wine/x86_64-unix/winemac.so',
                     'lib/wine/x86_64-unix/ntdll.so','lib/wine/x86_64-unix/win32u.so','config/dxmt.conf'):
            path=engine/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text('fixture')
        self.call('display','--height','1200')
        import os
        from unittest.mock import patch
        with patch.dict(os.environ,{'DXMT_CONFIG':'unexpected override','PRIVATE_TEST_SECRET':'must-not-appear'}):
            report=self.call('parity-report')[-1]
        self.assertTrue(report['retina_enabled'])
        self.assertEqual(report['render_preferences'],launch_preferences()|load()['baseline_preferences'])
        for key,value in load()['environment'].items():self.assertEqual(report['launch_environment'][key],value)
        self.assertNotIn('DXMT_CONFIG',report['launch_environment'])
        self.assertNotIn('must-not-appear',json.dumps(report))


if __name__=='__main__':unittest.main()
