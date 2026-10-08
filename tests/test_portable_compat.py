"""Settings › Advanced and the Rosetta check, through the real setup worker.

A fixture registry tool stands in for Wine's reg.exe: it edits user.reg the way Wine saves
it (escaped key names, long binary values wrapped across lines). No Wine or game runs.
"""
import base64
import hashlib
import json
from pathlib import Path
import re
import sys
import tempfile
import time
import unittest

import test_portable_setup as setup
from build_portable_setup import build

ROOT = Path(__file__).resolve().parents[1]
CONNECTIONS = r'Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'
CERTIFICATE_KEY = r'Software\Microsoft\SystemCertificates\Root\Certificates\A99D5B79E9F1CDA59CDAB6373169D5353F5874C6'
DIRECT = bytes.fromhex('460000000100000001000000' + '00' * 24)

# Wine's reg.exe, as far as Recall uses it: add a binary value, delete a value or a key.
FAKE_REG = r'''import json, os, re, sys
from pathlib import Path
prefix=Path(os.environ['WINEPREFIX'])
with open(prefix.parent/'reg-calls.json','a') as log: log.write(json.dumps(sys.argv[1:])+'\n')
if sys.argv[1]!='reg.exe': sys.exit(0)  # the Battle.net installer
if (prefix.parent/'reg-fails').exists(): sys.exit(1)
args=sys.argv[2:]
action,key=args[0],args[1]
assert key.startswith('HKCU\\'), key
key=key[5:]
path=prefix/'user.reg'
text=path.read_text()
sections=re.split(r'\n(?=\[)',text)
header='['+key.replace('\\','\\\\')+']'
def ours(section): return section.lower().startswith(header.lower()+' ') or section.lower().startswith(header.lower()+'\n')
def below(section): return section.lower().startswith(header[:-1].lower()+'\\\\')
if action=='add':
    name=args[args.index('/v')+1]; data=bytes.fromhex(args[args.index('/d')+1])
    assert args[args.index('/t')+1]=='REG_BINARY'
    hexed=','.join('%02x'%b for b in data)
    lines,line=[],'"%s"=hex:'%name
    for i,part in enumerate(hexed.split(',')):
        piece=part+(',' if i<len(data)-1 else '')
        if len(line)+len(piece)>79: lines.append(line+'\\'); line='  '
        line+=piece
    value='\n'.join(lines+[line])
    for i,s in enumerate(sections):
        if ours(s):
            body=[l for l in re.split(r'\n(?=\S)',s) if not l.startswith('"%s"='%name)]
            sections[i]='\n'.join(body).rstrip('\n')+'\n'+value+'\n'
            break
    else: sections.append(header+' 1\n#time=1\n'+value+'\n')
elif '/v' in args:
    name=args[args.index('/v')+1]
    for i,s in enumerate(sections):
        if ours(s):
            body=re.split(r'\n(?=\S)',s)
            kept=[l for l in body if not l.startswith('"%s"='%name)]
            if kept==body: sys.exit(1)
            sections[i]='\n'.join(kept).rstrip('\n')+'\n'
            break
    else: sys.exit(1)
else:
    kept=[s for s in sections if not ours(s) and not below(s)]
    if kept==sections: sys.exit(1)
    sections=kept
path.write_text('\n'.join(s.rstrip('\n')+'\n' for s in sections))
'''


def certificate():
    """The certificate the worker embeds, decoded from its source."""
    source = (ROOT/'scripts/portable_korea.h').read_text()
    body = source.split('crossSignedG4=', 1)[1].split(';', 1)[0]
    return base64.b64decode(''.join(re.findall(r'@"([^"]*)"', body)))


class AdvancedSettings(unittest.TestCase):
    setUpClass = classmethod(setup.NativeSetup.setUpClass.__func__)
    tearDownClass = classmethod(setup.NativeSetup.tearDownClass.__func__)
    setUp = setup.NativeSetup.setUp
    call = setup.NativeSetup.call

    def fixture(self, registry='WINE REGISTRY Version 2\n;; All keys relative to \\\\User\\\\S-1-5-21\n\n#arch=win64\n\n'
                '[Software\\\\Wine\\\\Mac Driver] 1790620772\n#time=1dd4f78b421c0b8\n"RetinaMode"="Y"\n'):
        self.call('status')
        engine = self.root/'runtimes/v1/bin'
        engine.mkdir(parents=True)
        (engine.parent/'runtime.json').write_text('{}')
        (self.root/'state.json').write_text(json.dumps({'schema': 1, 'active_runtime': 'v1'}))
        self.registry = self.root/'environment/user.reg'
        self.registry.parent.mkdir()
        (self.registry.parent/'system.reg').write_text('WINE REGISTRY Version 2\n')
        self.registry.write_text(registry)
        (engine/'wineserver').write_text('#!/bin/sh\nexit 0\n')
        (engine/'wineserver').chmod(0o755)
        (engine/'wine').write_text(f'#!{sys.executable}\n' + FAKE_REG)
        (engine/'wine').chmod(0o755)

    def calls(self):
        log = self.root/'reg-calls.json'
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def value(self, key, name):
        """A binary value as Wine's registry file holds it, continuation lines joined."""
        header = '[' + key.replace('\\', '\\\\') + ']'
        text = self.registry.read_text().replace('\\\n  ', '')
        for section in re.split(r'\n(?=\[)', text):
            if section.lower().startswith(header.lower()):
                found = re.search(r'^"' + re.escape(name) + r'"=hex:([0-9a-f,]*)$', section, re.M)
                return bytes.fromhex(found.group(1).replace(',', '')) if found else None
        return None

    def state(self):
        return json.loads((self.root/'state.json').read_text())

    def test_proxy_detection_is_off_until_the_player_turns_it_on(self):
        self.fixture()
        self.assertEqual(self.call('network', '--proxy-detect', '0', '--apply', '0')[-1],
                         {'stage': 'network_proxy', 'detect': False, 'changed': True})
        events = self.call('network', '--proxy-detect', '0')
        self.assertEqual(events[-1], {'stage': 'setting_saved', 'name': 'proxy_auto_detect', 'enabled': False})
        self.assertEqual(self.value(CONNECTIONS, 'DefaultConnectionSettings'), DIRECT)
        self.assertIn('"RetinaMode"="Y"', self.registry.read_text())
        self.assertIs(self.state()['proxy_auto_detect'], False)
        # Already direct: nothing to write.
        self.assertFalse(self.call('network', '--proxy-detect', '0', '--apply', '0')[-1]['changed'])
        before = len(self.calls())
        self.call('network', '--proxy-detect', '0')
        self.assertEqual(len(self.calls()), before)
        # On: Wine's default, the value removed.
        self.call('network', '--proxy-detect', '1')
        self.assertIsNone(self.value(CONNECTIONS, 'DefaultConnectionSettings'))
        self.assertIs(self.state()['proxy_auto_detect'], True)
        self.assertFalse(self.call('network', '--proxy-detect', '1', '--apply', '0')[-1]['changed'])

    def test_settings_written_by_windows_are_recognised(self):
        # Another key name case, a counter Windows advanced, the value wrapped: still direct.
        settings = bytes.fromhex('4600000007000000010000000000000000000000000000000000000000000000')
        self.fixture('WINE REGISTRY Version 2\n\n[Software\\\\Microsoft\\\\Windows\\\\CurrentVersion\\\\INTERNET SETTINGS\\\\Connections] 1\n'
                     '"DefaultConnectionSettings"=hex:' + ','.join('%02x' % b for b in settings[:20]) + ',\\\n  '
                     + ','.join('%02x' % b for b in settings[20:]) + '\n')
        self.assertEqual(self.value(CONNECTIONS, 'DefaultConnectionSettings'), settings)
        self.assertFalse(self.call('network', '--proxy-detect', '0', '--apply', '0')[-1]['changed'])
        # With the auto-detect flag it counts as on.
        self.registry.write_text(self.registry.read_text().replace('07,00,00,00,01,00', '07,00,00,00,09,00', 1))
        self.assertEqual(self.value(CONNECTIONS, 'DefaultConnectionSettings')[8], 9)
        self.assertFalse(self.call('network', '--proxy-detect', '1', '--apply', '0')[-1]['changed'])
        self.assertTrue(self.call('network', '--proxy-detect', '0', '--apply', '0')[-1]['changed'])

    def test_failed_registry_tool_keeps_the_previous_choice(self):
        self.fixture()
        (self.root/'reg-fails').write_text('')
        self.assertEqual(self.call('network', '--proxy-detect', '0', success=False)[-1]['code'], 'setting_change_failed')
        self.assertNotIn('proxy_auto_detect', self.state())
        self.assertEqual(self.call('korean-support', '--enabled', '1', success=False)[-1]['code'], 'setting_change_failed')
        self.assertNotIn('korean_support', self.state())

    def test_choice_before_setup_waits_for_the_environment(self):
        self.call('status')
        (self.root/'state.json').write_text(json.dumps({'schema': 1, 'active_runtime': 'v1'}))
        self.assertEqual(self.call('network', '--proxy-detect', '1')[-1]['stage'], 'setting_saved')
        self.assertIs(self.state()['proxy_auto_detect'], True)
        self.assertFalse((self.root/'environment').exists())

    def test_invalid_values_are_refused(self):
        self.fixture()
        self.assertEqual(self.call('network', '--proxy-detect', 'yes', success=False)[-1]['code'], 'invalid_arguments')
        self.assertEqual(self.call('korean-support', success=False)[-1]['code'], 'invalid_arguments')

    def test_korean_support_adds_and_removes_the_cross_signed_certificate(self):
        der = certificate()
        self.assertEqual(hashlib.sha256(der).hexdigest(), '33846b545a49c9be4903c60e01713c1bd4e4ef31ea65cd95d69e62794f30b941')
        self.assertEqual(hashlib.sha1(der).hexdigest().upper(), CERTIFICATE_KEY.rsplit('\\', 1)[1])
        self.fixture()
        self.assertTrue(self.call('korean-support', '--enabled', '1', '--apply', '0')[-1]['changed'])
        self.assertEqual(self.call('korean-support', '--enabled', '1')[-1],
                         {'stage': 'setting_saved', 'name': 'korean_support', 'enabled': True})
        # Wine's store format: the SHA-1 property (3), then the certificate (32).
        blob = self.value(CERTIFICATE_KEY, 'Blob')
        expected = ((3).to_bytes(4, 'little') + (1).to_bytes(4, 'little') + (20).to_bytes(4, 'little') + hashlib.sha1(der).digest()
                    + (32).to_bytes(4, 'little') + (1).to_bytes(4, 'little') + len(der).to_bytes(4, 'little') + der)
        self.assertEqual(blob, expected)
        self.assertEqual(len(blob), 1469)
        self.assertIs(self.state()['korean_support'], True)
        status = self.call('status')[-1]
        self.assertIs(status['state']['korean_support'], True)
        self.assertFalse(self.call('korean-support', '--enabled', '1', '--apply', '0')[-1]['changed'])
        # Off removes the key; turning it off again has nothing to do.
        self.call('korean-support', '--enabled', '0')
        self.assertIsNone(self.value(CERTIFICATE_KEY, 'Blob'))
        self.assertNotIn('A99D5B79', self.registry.read_text())
        self.assertIs(self.state()['korean_support'], False)
        before = len(self.calls())
        self.call('korean-support', '--enabled', '0')
        self.assertEqual(len(self.calls()), before)

    def test_status_reports_the_korean_build(self):
        self.fixture()
        self.assertIs(self.call('status')[-1]['nexon_build'], False)
        retail = self.root/'environment/drive_c/Program Files (x86)/Overwatch/_retail_'
        (retail/'grap').mkdir(parents=True)
        self.assertIs(self.call('status')[-1]['nexon_build'], True)
        (retail/'grap').rmdir()
        (retail/'grap64.dll').write_text('fixture')
        self.assertIs(self.call('status')[-1]['nexon_build'], True)

    def test_battlenet_installer_starts_with_a_direct_connection(self):
        self.fixture()
        installer = self.base/'Battle.net-Setup.exe'
        installer.write_bytes(b'fixture installer')
        digest = hashlib.sha256(installer.read_bytes()).hexdigest()
        events = self.call('install-battlenet', '--installer', installer, '--sha256', digest)
        self.assertEqual([e['stage'] for e in events], ['network_proxy', 'installing_battlenet', 'battlenet_installer_open'])
        self.assertEqual(self.value(CONNECTIONS, 'DefaultConnectionSettings'), DIRECT)
        # The installer runs on after the worker exits.
        for _ in range(100):
            if self.calls()[-1][0] != 'reg.exe':
                break
            time.sleep(0.05)
        self.assertEqual(self.calls()[-1], [str(installer), '--lang=enUS'])


class MissingRosetta(unittest.TestCase):
    """A worker whose Rosetta probe fails, as on a Mac that upgraded to macOS 27."""
    @classmethod
    def setUpClass(cls):
        cls.build_temp = tempfile.TemporaryDirectory(prefix='ow2-rosetta-tests-')
        cls.binary = Path(cls.build_temp.name)/'ow2-setup'
        build(cls.binary, ROOT/'runtime/toolchains/libarchive-3.7.7', defines=['ROSETTA_PROBE=@"/usr/bin/false"'])

    @classmethod
    def tearDownClass(cls):
        cls.build_temp.cleanup()

    setUp = setup.NativeSetup.setUp
    call = setup.NativeSetup.call
    fixture = AdvancedSettings.fixture
    calls = AdvancedSettings.calls

    def test_launch_and_installer_stop_before_wine(self):
        self.fixture()
        self.assertEqual(self.call('launch', success=False)[-1]['code'], 'rosetta_required')
        self.assertEqual(self.call('launch', '--play', '1', success=False)[-1]['code'], 'rosetta_required')
        self.assertEqual(self.call('install-battlenet', '--installer', self.base/'none.exe', '--sha256', '0' * 64, success=False)[-1]['code'],
                         'rosetta_required')
        self.assertEqual(self.call('preflight', success=False)[-1]['code'], 'rosetta_required')
        self.assertEqual(self.calls(), [])


if __name__ == '__main__':
    unittest.main()
