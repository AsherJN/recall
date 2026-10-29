"""Settings › Advanced and the Rosetta check, through the real setup worker.

A fixture registry tool stands in for Wine's reg.exe: it edits user.reg the way Wine saves
it (escaped key names, long binary values wrapped across lines). No Wine or game runs.
"""
import base64
import hashlib
import json
from pathlib import Path
import re
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest

import test_portable_setup as setup
from build_portable_setup import build

ROOT = Path(__file__).resolve().parents[1]
CONNECTIONS = r'Software\Microsoft\Windows\CurrentVersion\Internet Settings\Connections'
CERTIFICATE_KEY = r'Software\Microsoft\SystemCertificates\Root\Certificates\A99D5B79E9F1CDA59CDAB6373169D5353F5874C6'
ASSURED_ROOT_KEY = r'Software\Microsoft\SystemCertificates\Root\Certificates\0563B8630D62D75ABBC8AB1E4BDFB5A899B24D43'
DIRECT = bytes.fromhex('460000000100000001000000' + '00' * 24)
GAME_KEYBOARD = r'Software\Wine\AppDefaults\Overwatch.exe\Mac Driver'

# Wine's reg.exe, as far as Recall uses it: add a binary or string value, delete a value or a
# key, and import a REGEDIT4 file of REG_MULTI_SZ values (saved as Wine saves them:
# str(7):"a\0b\0").
FAKE_REG = r'''import json, os, re, sys
from pathlib import Path
prefix=Path(os.environ['WINEPREFIX'])
with open(prefix.parent/'reg-calls.json','a') as log: log.write(json.dumps(sys.argv[1:])+'\n')
if sys.argv[1]!='reg.exe': sys.exit(0)  # the Battle.net installer
if (prefix.parent/'reg-fails').exists(): sys.exit(1)
args=sys.argv[2:]
path=prefix/'user.reg'
text=path.read_text()
sections=re.split(r'\n(?=\[)',text)
if args[0]=='import':
    source=Path(args[1][2:].replace('\\','/'))
    with open(prefix.parent/'reg-imports.txt','ab') as log: log.write(source.read_bytes())
    key,values=None,{}
    for line in source.read_text().splitlines():
        if line.startswith('['):
            assert line.startswith('[HKEY_CURRENT_USER\\'), line
            key=line[len('[HKEY_CURRENT_USER\\'):-1]
        elif line.startswith('"'):
            name,data=line[1:].split('"=',1)
            assert data.startswith('hex(7):'), data
            # A REGEDIT4 file's hex(7) data is its own single-byte text, as Wine reads it.
            raw=bytes.fromhex(data[7:].replace(',',''))
            assert raw.endswith(b'\0\0'), raw
            values[name]='str(7):"'+''.join(n+'\\0' for n in raw.decode('ascii').split('\0') if n)+'"'
    header='['+key.replace('\\','\\\\')+']'
    for i,s in enumerate(sections):
        if s.lower().startswith(header.lower()+' '):
            body=[l for l in s.split('\n') if not any(l.startswith('"%s"='%n) for n in values)]
            sections[i]='\n'.join(body).rstrip('\n')+'\n'+''.join('"%s"=%s\n'%item for item in values.items())
            break
    else: sections.append(header+' 1\n#time=1\n'+''.join('"%s"=%s\n'%item for item in values.items()))
    path.write_text('\n'.join(s.rstrip('\n')+'\n' for s in sections))
    sys.exit(0)
action,key=args[0],args[1]
assert key.startswith('HKCU\\'), key
key=key[5:]
header='['+key.replace('\\','\\\\')+']'
def ours(section): return section.lower().startswith(header.lower()+' ') or section.lower().startswith(header.lower()+'\n')
def below(section): return section.lower().startswith(header[:-1].lower()+'\\\\')
if action=='add':
    name=args[args.index('/v')+1]; kind=args[args.index('/t')+1]
    assert kind in ('REG_BINARY','REG_SZ'), kind
    if kind=='REG_SZ': value='"%s"="%s"'%(name,args[args.index('/d')+1])
    else:
        data=bytes.fromhex(args[args.index('/d')+1])
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


def certificate(name='crossSignedG4'):
    """The certificate the worker embeds, decoded from its source."""
    source = (ROOT/'scripts/portable_korea.h').read_text()
    body = source.split(name + '=', 1)[1].split(';', 1)[0]
    return base64.b64decode(''.join(re.findall(r'@"([^"]*)"', body)))


def certificate_blob(der):
    return struct.pack('<III', 3, 1, 20) + hashlib.sha1(der).digest() + struct.pack('<III', 32, 1, len(der)) + der


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

    def write_certificate_blob(self, blob, key=CERTIFICATE_KEY):
        header = '[' + key.replace('\\', '\\\\') + ']'
        sections = [s for s in re.split(r'\n(?=\[)', self.registry.read_text())
                    if not s.startswith(header)]
        sections.append(header + ' 1\n"Blob"=hex:' + ','.join('%02x' % b for b in blob) + '\n')
        self.registry.write_text('\n'.join(sections))

    def launch_fixture(self):
        self.fixture()
        engine = self.root/'runtimes/v1'
        config = engine/'config/dxmt.conf'
        config.parent.mkdir()
        config.write_text((ROOT/'config/dxmt-source60-1200.conf').read_text())
        client = self.root/'environment/drive_c/Program Files (x86)/Battle.net/Battle.net.exe'
        client.parent.mkdir(parents=True)
        client.write_text('fixture client')
        (self.root/'state.json').write_text(json.dumps({**self.state(), 'korean_support': True}))

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

    def test_left_option_key_is_alt_in_overwatch_only(self):
        self.fixture()
        self.assertEqual(self.call('keyboard', '--apply', '0')[-1], {'stage': 'keyboard', 'left_option_is_alt': True, 'changed': True})
        self.assertEqual(self.call('keyboard')[-1], {'stage': 'keyboard', 'left_option_is_alt': True, 'changed': True})
        self.assertEqual(self.calls()[-1], ['reg.exe', 'add', 'HKCU\\' + GAME_KEYBOARD, '/v', 'LeftOptionIsAlt', '/t', 'REG_SZ', '/d', 'Y', '/f'])
        sections = {s.split(']')[0] + ']': s for s in re.split(r'\n(?=\[)', self.registry.read_text()) if s.startswith('[')}
        self.assertIn('"LeftOptionIsAlt"="Y"', sections['[' + GAME_KEYBOARD.replace('\\', '\\\\') + ']'])
        # Battle.net and every other program keep Wine's default: Option types characters.
        self.assertNotIn('OptionIsAlt', sections['[Software\\\\Wine\\\\Mac Driver]'])
        # Set already: nothing to write.
        before = len(self.calls())
        self.assertEqual(self.call('keyboard')[-1], {'stage': 'keyboard', 'left_option_is_alt': True, 'changed': False})
        self.assertFalse(self.call('keyboard', '--apply', '0')[-1]['changed'])
        self.assertEqual(len(self.calls()), before)

    def test_left_option_key_failure_never_stops_the_worker(self):
        self.fixture()
        (self.root/'reg-fails').write_text('')
        self.assertEqual(self.call('keyboard')[-1], {'stage': 'keyboard', 'left_option_is_alt': True, 'changed': False, 'failed': True})
        self.assertNotIn('LeftOptionIsAlt', self.registry.read_text())

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

    def test_korean_support_adds_and_removes_both_certificates(self):
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
        root_der = certificate('assuredRoot')
        self.assertEqual(len(root_der), 955)
        self.assertEqual(hashlib.sha256(root_der).hexdigest(), '3e9099b5015e8f486c00bcea9d111ee721faba355a89bcf1df69561e3dc6325c')
        self.assertEqual(hashlib.sha1(root_der).hexdigest().upper(), ASSURED_ROOT_KEY.rsplit('\\', 1)[1])
        self.assertEqual(self.value(ASSURED_ROOT_KEY, 'Blob'), certificate_blob(root_der))
        self.assertIs(self.state()['korean_support'], True)
        status = self.call('status')[-1]
        self.assertIs(status['state']['korean_support'], True)
        self.assertFalse(self.call('korean-support', '--enabled', '1', '--apply', '0')[-1]['changed'])
        # Off removes the key; turning it off again has nothing to do.
        self.call('korean-support', '--enabled', '0')
        self.assertIsNone(self.value(CERTIFICATE_KEY, 'Blob'))
        self.assertIsNone(self.value(ASSURED_ROOT_KEY, 'Blob'))
        self.assertNotIn('A99D5B79', self.registry.read_text())
        self.assertNotIn('0563B863', self.registry.read_text())
        self.assertIs(self.state()['korean_support'], False)
        before = len(self.calls())
        self.call('korean-support', '--enabled', '0')
        self.assertEqual(len(self.calls()), before)

    def test_existing_cross_signed_g4_is_migrated_with_missing_assured_root(self):
        self.fixture()
        existing = certificate_blob(certificate())
        self.write_certificate_blob(existing)
        (self.root/'state.json').write_text(json.dumps({**self.state(), 'korean_support': True}))
        self.assertTrue(self.call('korean-support', '--enabled', '1', '--apply', '0')[-1]['changed'])
        self.call('korean-support', '--enabled', '1')
        self.assertEqual(self.value(CERTIFICATE_KEY, 'Blob'), existing)
        self.assertEqual(self.value(ASSURED_ROOT_KEY, 'Blob'), certificate_blob(certificate('assuredRoot')))
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(self.calls()[0][2], 'HKCU\\' + ASSURED_ROOT_KEY)
        self.assertFalse(self.call('korean-support', '--enabled', '1', '--apply', '0')[-1]['changed'])

    def test_invalid_assured_root_is_repaired_without_rewriting_g4(self):
        self.fixture()
        self.call('korean-support', '--enabled', '1')
        self.write_certificate_blob(b'\x01', ASSURED_ROOT_KEY)
        before = len(self.calls())
        self.call('korean-support', '--enabled', '1')
        self.assertEqual(len(self.calls()), before + 1)
        self.assertEqual(self.calls()[-1][2], 'HKCU\\' + ASSURED_ROOT_KEY)
        self.assertEqual(self.value(ASSURED_ROOT_KEY, 'Blob'), certificate_blob(certificate('assuredRoot')))

    def test_status_reports_the_korean_build(self):
        self.fixture()
        self.assertIs(self.call('status')[-1]['nexon_build'], False)
        retail = self.root/'environment/drive_c/Program Files (x86)/Overwatch/_retail_'
        (retail/'grap').mkdir(parents=True)
        self.assertIs(self.call('status')[-1]['nexon_build'], True)
        (retail/'grap').rmdir()
        (retail/'grap64.dll').write_text('fixture')
        self.assertIs(self.call('status')[-1]['nexon_build'], True)

    def test_corrupt_certificate_blobs_are_repaired(self):
        self.fixture()
        self.call('korean-support', '--enabled', '1')
        expected = self.value(CERTIFICATE_KEY, 'Blob')
        for corrupt in (b'', b'\x01', expected[:-1], expected[:32], expected[32:],
                        expected[:12] + b'\x00' * 20 + expected[32:],
                        expected[:-1] + bytes([expected[-1] ^ 1]),
                        expected[:8] + b'\xff' * 4 + expected[12:]):
            with self.subTest(size=len(corrupt)):
                self.write_certificate_blob(corrupt)
                self.assertTrue(self.call('korean-support', '--enabled', '1', '--apply', '0')[-1]['changed'])
                self.call('korean-support', '--enabled', '1')
                self.assertEqual(self.value(CERTIFICATE_KEY, 'Blob'), expected)

    def test_certificate_properties_can_be_reordered_or_extended(self):
        self.fixture()
        self.call('korean-support', '--enabled', '1')
        expected = self.value(CERTIFICATE_KEY, 'Blob')
        # Wine can persist other properties, such as a UTF-16 friendly name.
        name = 'Korean support\0'.encode('utf-16le')
        extra = struct.pack('<III', 11, 1, len(name)) + name
        extended = expected[32:] + extra + expected[:32]
        self.write_certificate_blob(extended)
        self.assertFalse(self.call('korean-support', '--enabled', '1', '--apply', '0')[-1]['changed'])
        before = len(self.calls())
        self.call('korean-support', '--enabled', '1')
        self.assertEqual(len(self.calls()), before)
        self.assertEqual(self.value(CERTIFICATE_KEY, 'Blob'), extended)

    def test_disabling_removes_an_invalid_certificate_blob(self):
        self.fixture()
        self.write_certificate_blob(b'\x01')
        self.assertTrue(self.call('korean-support', '--enabled', '0', '--apply', '0')[-1]['changed'])
        (self.root/'reg-fails').write_text('')
        self.assertEqual(self.call('korean-support', '--enabled', '0', success=False)[-1]['code'], 'setting_change_failed')
        self.assertEqual(self.value(CERTIFICATE_KEY, 'Blob'), b'\x01')
        (self.root/'reg-fails').unlink()
        self.call('korean-support', '--enabled', '0')
        self.assertIsNone(self.value(CERTIFICATE_KEY, 'Blob'))

    def test_launch_stops_if_required_certificate_cannot_be_installed(self):
        self.launch_fixture()
        (self.root/'reg-fails').write_text('')
        events = self.call('launch', '--play', '1', success=False)
        self.assertEqual(events[-1]['code'], 'korean_support_failed')
        self.assertNotIn('battlenet_open', [event['stage'] for event in events])
        self.assertNotIn('battlenet_started', [event['stage'] for event in events])
        self.assertTrue(self.calls())
        self.assertTrue(all(call[0] == 'reg.exe' for call in self.calls()))
        self.assertIs(self.state()['korean_support'], True)

    def test_prepare_stops_if_required_certificate_cannot_be_installed(self):
        self.launch_fixture()
        engine = self.root/'runtimes/v1'
        names = ['lib/external/libd3dshared.dylib', 'lib/wine/x86_64-unix/winemetal.so',
                 'lib/wine/x86_64-unix/winemac.so']
        names += ['lib/wine/' + arch + '/' + name for arch in ('x86_64-windows', 'i386-windows')
                  for name in ('winemac.drv', 'mountmgr.sys', 'nsiproxy.sys', 'kernel32.dll', 'ntdll.dll')]
        for name in names:
            path = engine/name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b'fixture only')
        manifest = {'version': 'v1', 'files': {
            str(path.relative_to(engine)): {'sha256': hashlib.sha256(path.read_bytes()).hexdigest()}
            for path in engine.rglob('*') if path.is_file() and path.name != 'runtime.json'}}
        (engine/'runtime.json').write_text(json.dumps(manifest))
        (self.root/'environment-owned.json').write_text('{"schema":1,"runtime":"v1"}')
        (self.root/'reg-fails').write_text('')
        events = self.call('prepare', success=False)
        self.assertEqual(events[-1]['code'], 'korean_support_failed')
        self.assertNotIn('environment_ready', [event['stage'] for event in events])
        self.assertNotIn('prepared_runtime', self.state())

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

    # REC-68: finish-installer closes the Battle.net Blizzard's installer opens.
    def session_process(self, windows_name):
        """A stand-in Wine process as the worker finds one: Windows name, engine program, prefix file mapped."""
        program = self.root/'runtimes/v1/bin/session-process'
        if not program.exists():
            source = self.base/'session-process.c'
            source.write_text('#include <fcntl.h>\n#include <sys/mman.h>\n#include <unistd.h>\n'
                              'int main(int c,char**v){int f=open(v[1],O_RDONLY);'
                              'if(f<0||mmap(0,4096,PROT_READ,MAP_PRIVATE,f,0)==MAP_FAILED)return 1;sleep(60);return 0;}\n')
            subprocess.run(['clang', '-o', program, source], check=True)
        mapped = self.root/'environment/drive_c/Program Files (x86)/Battle.net/Battle.net.exe'
        process = subprocess.Popen([windows_name, mapped], executable=program)
        self.addCleanup(process.kill)
        threading.Thread(target=process.wait, daemon=True).start()  # reaped as soon as it ends
        time.sleep(0.3)
        return process

    def installer_watch(self, *args):
        worker = subprocess.Popen([str(self.binary), 'finish-installer', '--root', str(self.root), *args],
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(worker.kill)
        named = self.root/'cache/installer-watch.pid'
        for _ in range(200):
            if named.exists() and named.read_text() == str(worker.pid):
                break
            time.sleep(0.05)
        self.assertEqual(named.read_text(), str(worker.pid))
        return worker

    def finished(self, worker):
        stdout, _ = worker.communicate(timeout=20)
        return worker.returncode, [json.loads(line) for line in stdout.splitlines()]

    def test_installer_watch_leaves_setup_free_while_it_waits(self):
        self.fixture()
        worker = self.installer_watch('--timeout', '3')
        self.assertEqual(self.call('status')[-1]['stage'], 'status')
        self.assertEqual(self.finished(worker), (0, [{'stage': 'installer_wait_ended', 'game': False}]))
        self.assertFalse((self.root/'cache/installer-watch.pid').exists())

    def test_installer_watch_closes_the_battlenet_the_installer_opens(self):
        self.launch_fixture()
        # The installer names Battle.net with forward slashes; the processes Battle.net starts use backslashes.
        clients = [self.session_process('C:/Program Files (x86)/Battle.net/Battle.net.exe'),
                   self.session_process(r'C:\Program Files (x86)\Battle.net\Battle.net.exe')]
        started = time.monotonic()
        events = self.call('finish-installer', '--timeout', '30')
        self.assertEqual(events, [{'stage': 'installer_client_closed', 'processes': 2}])
        self.assertLess(time.monotonic() - started, 5)
        for client in clients:
            client.wait(timeout=5)
            self.assertEqual(client.returncode, -15)

    def test_installer_watch_leaves_battlenet_alone_once_overwatch_runs(self):
        self.launch_fixture()
        client = self.session_process(r'C:\Program Files (x86)\Battle.net\Battle.net.exe')
        self.session_process(r'C:\Program Files (x86)\Overwatch\_retail_\Overwatch.exe')
        self.assertEqual(self.call('finish-installer', '--timeout', '30'), [{'stage': 'installer_wait_ended', 'game': True}])
        self.assertIsNone(client.poll())

    def test_a_launch_or_another_watch_stops_the_installer_watch(self):
        self.launch_fixture()
        first = self.installer_watch('--timeout', '60')
        second = self.installer_watch('--timeout', '60')
        self.assertEqual(self.finished(first)[1][-1], {'stage': 'error', 'code': 'cancelled'})
        # The Korean certificate fails after the launch's first step, before Battle.net would open.
        (self.root/'reg-fails').write_text('')
        self.assertEqual(self.call('launch', '--play', '1', success=False)[-1]['code'], 'korean_support_failed')
        self.assertEqual(self.finished(second)[1][-1], {'stage': 'error', 'code': 'cancelled'})
        self.assertFalse((self.root/'cache/installer-watch.pid').exists())


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
