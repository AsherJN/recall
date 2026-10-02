"""Run the real setup worker with a fixture registry tool; never launch a game."""
import json
import sys
import unittest
import test_portable_setup as setup


class RetinaSetup(unittest.TestCase):
    setUpClass = classmethod(setup.NativeSetup.setUpClass.__func__)
    tearDownClass = classmethod(setup.NativeSetup.tearDownClass.__func__)
    setUp = setup.NativeSetup.setUp
    call = setup.NativeSetup.call

    def fixture(self, registry, *, busy=False, fail=False, no_write=False):
        self.call('status')
        engine = self.root/'runtimes/v1/bin'
        engine.mkdir(parents=True)
        (engine.parent/'runtime.json').write_text('{}')
        (self.root/'state.json').write_text(json.dumps({'schema':1,'active_runtime':'v1'}))
        self.registry = self.root/'environment/user.reg'
        self.registry.parent.mkdir()
        self.registry.write_text(registry)
        server = engine/'wineserver'
        server.write_text('#!/bin/sh\n' + ('exec /bin/sleep 30\n' if busy else 'exit 0\n'))
        server.chmod(0o755)
        wine = engine/'wine'
        wine.write_text(f'#!{sys.executable}\n' + '''import os, sys
from pathlib import Path
p=Path(os.environ['WINEPREFIX'])/'user.reg'
expected=['reg.exe','add',r'HKCU\\Software\\Wine\\Mac Driver','/v','RetinaMode','/t','REG_SZ','/d','Y','/f']
assert sys.argv[1:]==expected, sys.argv
''' + ('sys.exit(1)\n' if fail else '' if no_write else '''text=p.read_text().replace('"RetinaMode"="N"','"RetinaMode"="Y"')
if '"RetinaMode"="Y"' not in text:
    text+='\\n[Software\\\\\\\\Wine\\\\\\\\Mac Driver] 1\\n"RetinaMode"="Y"\\n'
p.write_text(text)
'''))
        wine.chmod(0o755)

    def test_missing_setting_is_backed_up_and_migrated_idempotently(self):
        original='WINE REGISTRY Version 2\n\n[Unrelated] 1\n"Keep"="yes"\n'
        self.fixture(original)
        events=self.call('repair-retina')
        self.assertEqual(events[-1]['stage'],'retina_configured')
        self.assertIn('"Keep"="yes"',self.registry.read_text())
        backup=self.root/'settings-backup/before-retina-user.reg'
        self.assertEqual(backup.read_text(),original)
        before=self.registry.stat().st_mtime_ns
        self.assertEqual(self.call('repair-retina'),[])
        self.assertEqual(self.registry.stat().st_mtime_ns,before)
        self.assertEqual(backup.read_text(),original)

    def test_disabled_setting_is_corrected_without_changing_other_values(self):
        original='WINE REGISTRY Version 2\n\n[Software\\\\Wine\\\\Mac Driver] 1\n"RetinaMode"="N"\n"Other"="keep"\n'
        self.fixture(original)
        self.call('repair-retina')
        self.assertEqual(self.registry.read_text(),original.replace('"N"','"Y"'))

    def test_setting_in_another_section_does_not_skip_migration(self):
        self.fixture('[Unrelated]\n"RetinaMode"="Y"\n',no_write=True)
        self.assertEqual(self.call('repair-retina',success=False)[-1]['code'],'retina_configuration_failed')

    def test_busy_environment_is_preserved(self):
        original='WINE REGISTRY Version 2\n'
        self.fixture(original,busy=True)
        self.assertEqual(self.call('repair-retina',success=False)[-1]['code'],'close_game_before_setup')
        self.assertEqual(self.registry.read_text(),original)
        self.assertFalse((self.root/'settings-backup').exists())

    def test_failed_registry_tool_keeps_backup_and_can_retry(self):
        original='WINE REGISTRY Version 2\n'
        self.fixture(original,fail=True)
        self.assertEqual(self.call('repair-retina',success=False)[-1]['code'],'retina_configuration_failed')
        self.assertEqual((self.root/'settings-backup/before-retina-user.reg').read_text(),original)
        wine=self.root/'runtimes/v1/bin/wine'
        wine.write_text(wine.read_text().replace('sys.exit(1)', '''p.write_text(p.read_text()+'\\n[Software\\\\\\\\Wine\\\\\\\\Mac Driver] 1\\n"RetinaMode"="Y"\\n')'''))
        self.call('repair-retina')
        self.assertEqual((self.root/'settings-backup/before-retina-user.reg').read_text(),original)

    def test_registry_symlink_is_rejected(self):
        self.fixture('WINE REGISTRY Version 2\n')
        external=self.base/'personal.reg'
        self.registry.rename(external)
        self.registry.symlink_to(external)
        self.assertEqual(self.call('repair-retina',success=False)[-1]['code'],'retina_configuration_failed')
        self.assertEqual(external.read_text(),'WINE REGISTRY Version 2\n')


if __name__=='__main__':
    unittest.main()
