"""Choose your Battle.net (issue #23), through the real setup worker: the region and language
kept in state.json, the installer's language, the fonts for Chinese and Korean text, and finding
Battle.net and Overwatch in other folders. The fixture registry tool of test_portable_compat
stands in for Wine's reg.exe. No Wine or game runs.
"""
import hashlib
import json
import time
import unittest

import test_portable_compat as compat
import test_portable_setup as setup

REPLACEMENTS = r'Software\Wine\Fonts\Replacements'


class BattleNetChoice(unittest.TestCase):
    setUpClass = classmethod(setup.NativeSetup.setUpClass.__func__)
    tearDownClass = classmethod(setup.NativeSetup.tearDownClass.__func__)
    setUp = setup.NativeSetup.setUp
    call = setup.NativeSetup.call
    fixture = compat.AdvancedSettings.fixture
    calls = compat.AdvancedSettings.calls
    state = compat.AdvancedSettings.state

    def replacement(self, name):
        """A font replacement as Wine's registry file holds it, or None."""
        header = '[' + REPLACEMENTS.replace('\\', '\\\\') + ']'
        for section in self.registry.read_text().split('\n['):
            if ('[' + section).lower().startswith(header.lower()):
                for line in section.splitlines():
                    if line.startswith('"%s"=' % name):
                        return line.split('=', 1)[1]
        return None

    def install(self):
        """Runs install-battlenet with a fixture installer; returns its events and the installer's arguments."""
        installer = self.base/'Battle.net-Setup.exe'
        installer.write_bytes(b'fixture installer')
        digest = hashlib.sha256(installer.read_bytes()).hexdigest()
        events = self.call('install-battlenet', '--installer', installer, '--sha256', digest)
        # The installer runs on after the worker exits.
        for _ in range(100):
            if self.calls() and self.calls()[-1][0] != 'reg.exe':
                break
            time.sleep(0.05)
        return events, self.calls()[-1]

    def test_choice_is_kept_and_checked(self):
        self.call('status')
        self.assertEqual(self.call('battlenet', '--region', 'cn', '--language', 'zhCN')[-1],
                         {'stage': 'battlenet_choice', 'region': 'cn', 'language': 'zhCN'})
        self.assertEqual((self.state()['battlenet_region'], self.state()['battlenet_language']), ('cn', 'zhCN'))
        self.assertEqual(self.call('status')[-1]['state']['battlenet_region'], 'cn')
        # China's Battle.net is Simplified Chinese only; anything unknown is refused.
        for args in (('--region', 'cn', '--language', 'enUS'), ('--region', 'us', '--language', 'enUS'),
                     ('--region', 'global', '--language', 'deDE'), ('--region', 'global')):
            self.assertEqual(self.call('battlenet', *args, success=False)[-1]['code'], 'invalid_arguments')
        self.assertEqual(self.state()['battlenet_region'], 'cn')
        self.call('battlenet', '--region', 'global', '--language', 'koKR')
        self.assertEqual((self.state()['battlenet_region'], self.state()['battlenet_language']), ('global', 'koKR'))

    def test_choice_stays_once_battlenet_is_installed(self):
        self.fixture()
        self.call('battlenet', '--region', 'global', '--language', 'enUS')
        client = self.root/'environment/drive_c/Program Files (x86)/Battle.net/Battle.net.exe'
        client.parent.mkdir(parents=True)
        client.write_text('fixture')
        self.assertEqual(self.call('battlenet', '--region', 'global', '--language', 'enUS')[-1]['stage'], 'battlenet_choice')
        self.assertEqual(self.call('battlenet', '--region', 'cn', '--language', 'zhCN', success=False)[-1]['code'],
                         'battlenet_already_installed')
        self.assertEqual(self.state()['battlenet_region'], 'global')

    def test_global_english_installs_as_before(self):
        self.fixture()
        events, installer = self.install()
        self.assertEqual([e['stage'] for e in events], ['network_proxy', 'installing_battlenet', 'battlenet_installer_open'])
        self.assertEqual(installer[1:], ['--lang=enUS'])
        self.assertIsNone(self.replacement('Microsoft YaHei'))
        self.assertEqual(self.call('fonts', '--apply', '0')[-1], {'stage': 'fonts', 'enabled': False, 'changed': False})

    def test_china_installs_in_chinese_with_the_fonts(self):
        self.fixture()
        self.call('battlenet', '--region', 'cn', '--language', 'zhCN')
        self.assertTrue(self.call('fonts', '--apply', '0')[-1]['changed'])
        events, installer = self.install()
        self.assertEqual([e['stage'] for e in events], ['network_proxy', 'fonts', 'installing_battlenet', 'battlenet_installer_open'])
        self.assertEqual(events[1], {'stage': 'fonts', 'enabled': True, 'changed': True, 'added': 20})
        self.assertEqual(installer[1:], ['--lang=zhCN'])
        # Windows' names and DirectWrite's fallbacks, each to fonts every Mac has, first found wins.
        chinese = 'str(7):"Hiragino Sans GB W3\\0Hiragino Sans GB\\0Heiti SC\\0"'
        for name in ('Microsoft YaHei', 'Microsoft YaHei UI', 'SimSun', 'Noto Sans CJK SC', 'Noto Sans CJK JP'):
            self.assertEqual(self.replacement(name), chinese)
        self.assertEqual(self.replacement('Microsoft JhengHei'), 'str(7):"Heiti TC\\0Songti TC\\0Hiragino Sans GB W3\\0"')
        # Each list is single-byte text in the file Wine's importer reads (hex(7) in REGEDIT4).
        imported = (self.root/'reg-imports.txt').read_bytes().decode('ascii')
        self.assertTrue(imported.startswith('REGEDIT4\r\n\r\n[HKEY_CURRENT_USER\\Software\\Wine\\Fonts\\Replacements]\r\n'))
        self.assertIn('"Malgun Gothic"=hex(7):' + ','.join('%02x' % b for b in b'Apple SD Gothic Neo\0AppleGothic\0\0') + '\r\n', imported)
        self.assertEqual(self.replacement('Malgun Gothic'), 'str(7):"Apple SD Gothic Neo\\0AppleGothic\\0"')
        self.assertEqual(self.replacement('Noto Sans CJK KR'), 'str(7):"Apple SD Gothic Neo\\0AppleGothic\\0"')
        # One import, its file removed; the Retina setting untouched.
        self.assertEqual([c for c in self.calls() if c[:2] == ['reg.exe', 'import']].__len__(), 1)
        self.assertEqual(list((self.root/'tmp').glob('*.reg')), [])
        self.assertIn('"RetinaMode"="Y"', self.registry.read_text())
        # Present now: nothing to add, and no registry tool at the next check.
        self.assertFalse(self.call('fonts', '--apply', '0')[-1]['changed'])
        before = len(self.calls())
        self.assertEqual(self.call('fonts')[-1], {'stage': 'fonts', 'enabled': True, 'changed': False})
        self.assertEqual(len(self.calls()), before)

    def test_a_missing_replacement_is_put_back(self):
        self.fixture()
        self.call('battlenet', '--region', 'global', '--language', 'koKR')
        self.call('fonts')
        self.registry.write_text('\n'.join(l for l in self.registry.read_text().split('\n') if not l.startswith('"Gulim"=')))
        self.assertIsNone(self.replacement('Gulim'))
        self.assertEqual(self.call('fonts')[-1], {'stage': 'fonts', 'enabled': True, 'changed': True, 'added': 1})
        self.assertEqual(self.replacement('Gulim'), 'str(7):"Apple SD Gothic Neo\\0AppleGothic\\0"')
        events, installer = self.install()
        self.assertEqual(installer[1:], ['--lang=koKR'])
        self.assertFalse([e for e in events if e['stage'] == 'fonts'][0]['changed'])

    def test_a_failed_registry_tool_does_not_stop_the_installer(self):
        self.fixture()
        self.call('battlenet', '--region', 'cn', '--language', 'zhCN')
        (self.root/'reg-fails').write_text('')
        events, installer = self.install()
        self.assertEqual([e for e in events if e['stage'] == 'fonts'][0]['failed'], True)
        self.assertEqual(events[-1]['stage'], 'battlenet_installer_open')
        self.assertEqual(installer[1:], ['--lang=zhCN'])

    def test_status_finds_battlenet_and_overwatch_in_other_folders(self):
        self.fixture()
        status = self.call('status')[-1]
        self.assertEqual((status['battlenet_installed'], status['game_installed'], status['neac_build']), (False, False, False))
        self.assertEqual(status['battlenet_path'], 'environment/drive_c/Program Files (x86)/Battle.net/Battle.net.exe')
        files = self.root/'environment/drive_c/Program Files (x86)'
        (files/'战网').mkdir(parents=True)
        (files/'战网/Battle.net.exe').write_text('fixture')
        retail = files/'守望先锋/_retail_'
        retail.mkdir(parents=True)
        (retail/'Overwatch.exe').write_text('fixture')
        status = self.call('status')[-1]
        self.assertEqual((status['battlenet_installed'], status['game_installed'], status['neac_build']), (True, True, False))
        self.assertEqual(status['battlenet_path'], 'environment/drive_c/Program Files (x86)/战网/Battle.net.exe')
        # NetEase's anti-cheat beside the game, or one folder below it.
        (retail/'NEAC').mkdir()
        (retail/'NEAC/NeacSafe64.sys').write_text('fixture')
        self.assertIs(self.call('status')[-1]['neac_build'], True)
        (retail/'NEAC/NeacSafe64.sys').unlink()
        (retail/'NEAC').rmdir()
        (retail/'OWNeacClient.exe').write_text('fixture')
        self.assertIs(self.call('status')[-1]['neac_build'], True)
        # The usual folders win when both exist.
        (files/'Overwatch/_retail_').mkdir(parents=True)
        (files/'Overwatch/_retail_/Overwatch.exe').write_text('fixture')
        self.assertIs(self.call('status')[-1]['neac_build'], False)


if __name__ == '__main__':
    unittest.main()
