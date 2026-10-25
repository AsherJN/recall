"""Settings › Advanced › Logging in the worker (scripts/portable_logs.h, REC-40, REC-51): what each setting,
alone or combined, gives Wine and the graphics layer, Custom text checked against Wine's grammar before
anything starts, and old session logs removed only while they would take more room than the disk has left.

Builds the real worker (needs runtime/toolchains/libarchive-3.7.7), once as shipped and once with the
disk's room stood in by LOG_ROOM. No Wine or game is launched.
"""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts'))
from build_portable_setup import build  # noqa: E402

QUIET = '-all'


class SessionLogs(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build_temp = tempfile.TemporaryDirectory(prefix='ow2-logging-tests-')
        cls.binary = Path(cls.build_temp.name)/'ow2-setup'
        build(cls.binary, ROOT/'runtime/toolchains/libarchive-3.7.7')
        # The disk has 2,500 bytes left, as far as the logs are concerned.
        cls.small = Path(cls.build_temp.name)/'small'/'ow2-setup'
        cls.small.parent.mkdir()
        build(cls.small, ROOT/'runtime/toolchains/libarchive-3.7.7', defines=['LOG_ROOM=2500ULL'])

    @classmethod
    def tearDownClass(cls):
        cls.build_temp.cleanup()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='ow2-logging-root-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()/'Overwatch2Mac'

    def call(self, *args, binary=None, success=True):
        r = subprocess.run([str(binary or self.binary), args[0], '--root', str(self.root), *map(str, args[1:])], capture_output=True, text=True)
        self.assertEqual(r.returncode == 0, success, r.stdout + r.stderr)
        return [json.loads(line) for line in r.stdout.splitlines()]

    def logging(self, setting, custom=None):
        return self.call('logging', '--setting', setting, *(['--custom', custom] if custom is not None else []))[-1]

    def environment(self, setting, custom=None):
        return self.logging(setting, custom)['environment']

    def test_off_keeps_the_launch_quiet(self):
        self.assertEqual(self.environment('off'), {})

    def test_presets_start_from_quiet_and_carry_wines_clock(self):
        for setting in ('crashes', 'graphics', 'battlenet'):
            winedebug = self.environment(setting)['WINEDEBUG']
            self.assertTrue(winedebug.startswith(QUIET + ',err+all'), winedebug)
            self.assertIn('+timestamp', winedebug)
            self.assertIn('+pid', winedebug)
        self.assertIn('+seh', self.environment('crashes')['WINEDEBUG'])
        self.assertEqual(self.environment('graphics')['DXMT_LOG_LEVEL'], 'info')
        self.assertIn('warn+winhttp', self.environment('battlenet')['WINEDEBUG'])

    def test_custom_is_wines_own_text_with_its_clock(self):
        # A player's example, as in Terminal: from Wine's defaults, so nothing is put in front.
        self.assertEqual(self.environment('custom', 'fixme-all,+seh,+tid,+timestamp,+loaddll')['WINEDEBUG'],
                         'fixme-all,+seh,+tid,+timestamp,+loaddll,+pid')
        self.assertEqual(self.environment('custom', 'warn+all')['WINEDEBUG'], 'warn+all,+timestamp,+pid')
        # A player who turned the clock off keeps it off.
        self.assertEqual(self.environment('custom', '+seh,-timestamp,-pid')['WINEDEBUG'], '+seh,-timestamp,-pid')
        self.assertEqual(self.environment('custom', 'Overwatch.exe:+seh')['WINEDEBUG'], 'Overwatch.exe:+seh,+timestamp,+pid')

    def test_presets_combine_in_settings_order(self):
        # Any mix of presets (REC-51): one quiet start, each preset's channels once, in Settings' order.
        self.assertEqual(self.environment('battlenet,crashes')['WINEDEBUG'],
                         '-all,err+all,+seh,+loaddll,warn+winhttp,warn+wininet,warn+secur32,+timestamp,+pid')
        both = self.environment('graphics,crashes')
        self.assertEqual((both['WINEDEBUG'], both['DXMT_LOG_LEVEL']), ('-all,err+all,+seh,+loaddll,+timestamp,+pid', 'info'))
        self.assertEqual(self.logging('mouse,battlenet,crashes')['setting'], 'crashes,battlenet,mouse')
        # Custom's items come after the presets', so the player's text has the last word.
        self.assertEqual(self.environment('crashes,custom', '+relay,-loaddll')['WINEDEBUG'],
                         '-all,err+all,+seh,+loaddll,+relay,-loaddll,+timestamp,+pid')
        self.assertEqual(self.environment('custom,mouse', 'warn+all')['WINEDEBUG'], 'warn+all,+timestamp,+pid')

    def test_mouse_turns_on_the_mouse_report_and_no_wine_logging(self):
        mouse = self.logging('mouse')
        self.assertEqual((mouse['setting'], mouse['environment'], mouse['mouse_report']), ('mouse', {}, True))
        self.assertTrue(self.logging('graphics,mouse')['mouse_report'])
        self.assertEqual(self.environment('graphics,mouse'), {'WINEDEBUG': '-all,err+all,+timestamp,+pid', 'DXMT_LOG_LEVEL': 'info'})
        self.assertFalse(self.logging('crashes')['mouse_report'])
        self.assertEqual(self.logging('off'), {'stage': 'logging', 'setting': 'off', 'environment': {}, 'mouse_report': False})

    def test_text_wine_wouldnt_understand_is_refused(self):
        for custom in ('', '+SEH', 'debug+all', '+seh;rm -rf /', '+a_channel_name_too_long', '+seh,', 'x' * 1100):
            events = self.call('logging', '--setting', 'custom', '--custom', custom, success=False)
            self.assertEqual(events[-1], {'stage': 'error', 'code': 'invalid_logging_settings'}, custom)
        self.assertEqual(self.call('logging', '--setting', 'custom', success=False)[-1]['code'], 'invalid_logging_settings')
        self.assertEqual(self.call('logging', '--setting', 'verbose', success=False)[-1]['code'], 'invalid_logging_settings')
        for setting in ('crashes,crashes', 'crashes,', ',mouse', 'off,mouse', 'crashes,verbose', 'crashes mouse', 'mouse,custom'):
            self.assertEqual(self.call('logging', '--setting', setting, success=False)[-1]['code'], 'invalid_logging_settings', setting)

    def test_a_launch_refuses_bad_logging_before_anything_starts(self):
        # Before the runtime, Battle.net or Rosetta are even looked at.
        self.assertEqual(self.call('launch', '--logging', 'verbose', success=False)[-1]['code'], 'invalid_logging_settings')
        self.assertEqual(self.call('launch', '--logging', 'custom', '--logging-custom', '+SEH', success=False)[-1]['code'], 'invalid_logging_settings')
        self.assertEqual(self.call('launch', '--logging', 'crashes,verbose', success=False)[-1]['code'], 'invalid_logging_settings')
        self.assertNotEqual(self.call('launch', '--logging', 'crashes', success=False)[-1]['code'], 'invalid_logging_settings')
        self.assertNotEqual(self.call('launch', '--logging', 'crashes,mouse', success=False)[-1]['code'], 'invalid_logging_settings')

    def sessions(self, sizes):
        folder = self.root/'logs/sessions'
        for index, size in enumerate(sizes):
            session = folder/f'2026101{index}T100000Z'
            session.mkdir(parents=True)
            (session/'battlenet.log').write_bytes(b'x' * size)
            (session/'session.json').write_text('{}')
        (folder/'not-a-session').mkdir()
        return folder

    def test_old_sessions_go_only_while_the_logs_would_outgrow_the_room_left(self):
        self.call('status')
        folder = self.sessions([1000, 1000, 1000, 400])
        # As shipped: this disk has room for all of them.
        self.assertEqual(self.call('session-logs', '--prune', '1')[-1]['sessions'],
                         ['20261010T100000Z', '20261011T100000Z', '20261012T100000Z', '20261013T100000Z'])
        # 3,410 bytes in 2,500 bytes of room: the oldest goes, then the rest fit (2,410).
        events = self.call('session-logs', '--prune', '1', binary=self.small)
        self.assertEqual([e['session'] for e in events if e['stage'] == 'session_log_removed'], ['20261010T100000Z'])
        self.assertEqual(events[-1]['sessions'], ['20261011T100000Z', '20261012T100000Z', '20261013T100000Z'])
        self.assertTrue((folder/'not-a-session').exists())
        # Listing alone never removes anything.
        self.assertEqual(len(self.call('session-logs', binary=self.small)[-1]['sessions']), 3)


if __name__ == '__main__':
    unittest.main()
