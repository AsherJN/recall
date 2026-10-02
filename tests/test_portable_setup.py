"""Exercise the compiled native setup worker against real malicious archives.

No Wine/game is launched. Fixture runtimes are data used solely to test the
transaction/verification boundary; they are not gameplay or signing evidence.
"""
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
from build_portable_setup import build


class NativeSetup(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build_temp=tempfile.TemporaryDirectory(prefix='ow2-native-tests-')
        cls.binary=Path(cls.build_temp.name)/'ow2-setup'
        build(cls.binary,ROOT/'runtime/toolchains/libarchive-3.7.7')

    @classmethod
    def tearDownClass(cls):
        cls.build_temp.cleanup()

    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='ow2-install-tests-')
        self.addCleanup(self.temp.cleanup)
        self.base=Path(self.temp.name).resolve()
        self.root=self.base/'User Directory With Spaces'/'Overwatch2Mac'
        self.root.parent.mkdir()

    def call(self,command,*args,success=True):
        r=subprocess.run([str(self.binary),command,'--root',str(self.root),*map(str,args)],capture_output=True,text=True)
        if success:self.assertEqual(r.returncode,0,r.stdout+r.stderr)
        else:self.assertNotEqual(r.returncode,0,r.stdout)
        return [json.loads(line) for line in r.stdout.splitlines()]

    def archive(self,version='v1',extra=(),corrupt=False,omit=()):
        names=['bin/wine','bin/wineserver','config/dxmt.conf','lib/external/libd3dshared.dylib',
               'lib/wine/x86_64-unix/winemetal.so','lib/wine/x86_64-unix/winemac.so']
        names += ['lib/wine/'+arch+'/'+name for arch in ('x86_64-windows','i386-windows')
                  for name in ('winemac.drv','mountmgr.sys','nsiproxy.sys','kernel32.dll','ntdll.dll')]
        data={name:('fixture only '+name).encode() for name in names if name not in omit}
        manifest={'version':version,'files':{name:{'sha256':hashlib.sha256(content).hexdigest()} for name,content in data.items()}}
        if corrupt:data[names[0]]=b'changed after manifest'
        data['runtime.json']=json.dumps(manifest).encode()
        target=self.base/(version+'-'+str(len(list(self.base.glob('*.tar.gz'))))+'.tar.gz')
        with tarfile.open(target,'w:gz') as t:
            for name,content in data.items():
                member=tarfile.TarInfo(name);member.size=len(content);member.mode=0o644;t.addfile(member,io.BytesIO(content))
            for name,kind,content in extra:
                member=tarfile.TarInfo(name)
                if kind=='file':member.size=len(content);t.addfile(member,io.BytesIO(content))
                else:
                    member.type=tarfile.SYMTYPE if kind=='symlink' else tarfile.LNKTYPE
                    member.linkname=content;t.addfile(member)
        return target,hashlib.sha256(target.read_bytes()).hexdigest()

    def install(self,version='v1',**kwargs):
        archive,digest=self.archive(version,**kwargs)
        return self.call('install-runtime','--archive',archive,'--sha256',digest,'--version',version)

    def test_fresh_install_handles_spaces_and_repeated_install_is_idempotent(self):
        self.install();self.call('verify');self.install()
        self.assertEqual(self.call('status')[-1]['state']['active_runtime'],'v1')

    def test_uninstall_moves_owned_root_to_trash_and_never_touches_unowned(self):
        self.call('status');(self.root/'environment').mkdir();(self.root/'environment'/'system.reg').write_text('x')
        result=self.call('uninstall')[-1]
        self.assertEqual(result['stage'],'uninstalled');trashed=Path(result['trashed'])
        self.addCleanup(lambda:__import__('shutil').rmtree(trashed,ignore_errors=True))
        self.assertFalse(self.root.exists());self.assertTrue((trashed/'environment'/'system.reg').exists())
        self.assertTrue(trashed.is_relative_to(Path.home()/'.Trash'))
        self.root.mkdir();(self.root/'personal.txt').write_text('keep')
        self.assertEqual(self.call('uninstall',success=False)[-1]['code'],'directory_not_owned_by_app')
        self.assertEqual((self.root/'personal.txt').read_text(),'keep')

    def test_unowned_directory_is_never_adopted(self):
        self.root.mkdir();(self.root/'personal.txt').write_text('keep')
        self.assertEqual(self.call('status',success=False)[-1]['code'],'directory_not_owned_by_app')
        self.assertEqual((self.root/'personal.txt').read_text(),'keep')

    def test_version_and_hash_must_match_entire_string(self):
        archive,digest=self.archive()
        for version,expected in [('v1\n',digest),('v1',digest+'\n')]:
            self.call('install-runtime','--archive',archive,'--sha256',expected,'--version',version,success=False)
            self.assertNotIn('active_runtime',self.call('status')[-1]['state'])

    def test_manifest_cannot_omit_required_windows_drivers(self):
        for name in ('lib/wine/x86_64-windows/winemac.drv','lib/wine/i386-windows/mountmgr.sys'):
            archive,digest=self.archive(omit=(name,))
            events=self.call('install-runtime','--archive',archive,'--sha256',digest,'--version','v1',success=False)
            self.assertEqual(events[-1]['code'],'runtime_required_component_missing')
            self.assertNotIn('active_runtime',self.call('status')[-1]['state'])

    def test_archive_hash_failure_keeps_existing_runtime_and_state(self):
        self.install();before=(self.root/'state.json').read_bytes()
        archive,_=self.archive('v2')
        result=self.call('install-runtime','--archive',archive,'--sha256','0'*64,'--version','v2',success=False)
        self.assertEqual(result[-1]['code'],'archive_hash_mismatch')
        self.assertEqual((self.root/'state.json').read_bytes(),before)

    def test_incomplete_extraction_retries_without_activating_bad_runtime(self):
        self.install();archive,digest=self.archive('v2',corrupt=True)
        self.call('install-runtime','--archive',archive,'--sha256',digest,'--version','v2',success=False)
        self.assertEqual(self.call('status')[-1]['state']['active_runtime'],'v1')
        self.install('v2');self.call('verify')
        current=self.call('status')[-1]['state']
        self.assertEqual((current['active_runtime'],current['previous_runtime']),('v2','v1'))

    def test_traversal_absolute_paths_links_and_case_aliases_never_write_outside(self):
        for name,kind,content in [('../escaped','file',b'bad'),('/tmp/ow2-escaped','file',b'bad'),
                                  ('bin/../escaped','file',b'bad'),('BIN/WINE','file',b'bad'),
                                  ('escape','symlink','../../escaped'),('link','hardlink','bin/wine')]:
            with self.subTest(name=name):
                archive,digest=self.archive(extra=[(name,kind,content)])
                self.call('install-runtime','--archive',archive,'--sha256',digest,'--version','v1',success=False)
                self.assertFalse((self.base/'escaped').exists())
                self.assertNotIn('active_runtime',self.call('status')[-1]['state'])

    def test_symlink_parent_cannot_redirect_deferred_link_creation(self):
        archive,digest=self.archive(extra=[('alias','symlink','bin'),('alias/child','symlink','wine')])
        self.call('install-runtime','--archive',archive,'--sha256',digest,'--version','v1',success=False)
        self.assertNotIn('active_runtime',self.call('status')[-1]['state'])

    def test_changed_installed_file_is_detected(self):
        self.install();(self.root/'runtimes/v1/bin/wine').write_text('tampered')
        self.assertEqual(self.call('verify',success=False)[-1]['code'],'runtime_file_hash_mismatch')

    def test_repair_replaces_a_damaged_runtime_and_asks_for_preparation_again(self):
        archive,digest=self.archive('v1')
        self.call('install-runtime','--archive',archive,'--sha256',digest,'--version','v1')
        state=json.loads((self.root/'state.json').read_text());state['prepared_runtime']='v1'
        (self.root/'state.json').write_text(json.dumps(state))
        (self.root/'runtimes/v1/bin/wine').write_text('tampered')
        self.assertEqual(self.call('install-runtime','--archive',archive,'--sha256',digest,'--version','v1',success=False)[-1]['code'],'runtime_file_hash_mismatch')
        self.call('install-runtime','--archive',archive,'--sha256',digest,'--version','v1','--repair','1');self.call('verify')
        state=self.call('status')[-1]['state']
        self.assertEqual(state['active_runtime'],'v1');self.assertNotIn('prepared_runtime',state)
        self.assertFalse((self.root/'incoming-runtime').exists());self.assertFalse((self.root/'replaced-runtime').exists())

    def test_updates_keep_only_the_active_and_previous_runtimes(self):
        for version in ('v1','v2','v3'):self.install(version)
        (self.root/'runtimes/not-a-runtime').mkdir()
        self.assertEqual(sorted(p.name for p in (self.root/'runtimes').iterdir()),['not-a-runtime','v2','v3'])
        state=self.call('status')[-1]['state']
        self.assertEqual((state['active_runtime'],state['previous_runtime']),('v3','v2'))

    def test_close_client_without_a_session_reports_closed(self):
        self.install()
        self.assertEqual(self.call('close-client')[-1]['stage'],'client_closed')

    def test_missing_manifest_file_or_extra_payload_is_rejected(self):
        archive,digest=self.archive(extra=[('unexpected.txt','file',b'extra')])
        self.assertEqual(self.call('install-runtime','--archive',archive,'--sha256',digest,'--version','v1',success=False)[-1]['code'],'runtime_unlisted_file')

    def test_finder_metadata_is_tolerated_but_nothing_else(self):
        self.install(extra=[('.DS_Store','file',b'finder'),('lib/.DS_Store','file',b'finder')])
        (self.root/'runtimes/v1/bin/.DS_Store').write_text('finder');self.call('verify')
        (self.root/'runtimes/v1/bin/.DS_Store.dylib').write_text('not finder')
        self.assertEqual(self.call('verify',success=False)[-1]['code'],'runtime_unlisted_file')

    def test_simultaneous_setup_is_rejected(self):
        self.call('status')
        import fcntl
        with (self.root/'setup.lock').open('r+') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            self.assertEqual(self.call('status',success=False)[-1]['code'],'setup_already_running')

    def test_plain_http_and_embedded_url_credentials_are_rejected(self):
        for url in ['http://example.invalid/x','https://username:password@example.invalid/x']:
            self.assertEqual(self.call('download','--url',url,'--sha256','0'*64,success=False)[-1]['code'],'https_download_required')

    def test_real_small_filesystem_rejects_install_before_extraction(self):
        image=self.base/'small.sparseimage';mount=self.base/'small-volume'
        subprocess.run(['hdiutil','create','-size','128m','-fs','APFS','-type','SPARSE',
                        '-volname','OW2 Setup Space Test',str(image)],check=True,capture_output=True)
        subprocess.run(['hdiutil','attach','-nobrowse','-mountpoint',str(mount),str(image)],check=True,capture_output=True)
        try:
            self.root=mount/'Overwatch2Mac'
            archive,digest=self.archive()
            result=self.call('install-runtime','--archive',archive,'--sha256',digest,'--version','v1',success=False)
            self.assertEqual(result[-1]['code'],'insufficient_disk_space')
            self.assertFalse((self.root/'incoming-runtime').exists())
        finally:
            subprocess.run(['hdiutil','detach',str(mount)],check=True,capture_output=True)

    def volume(self,filesystem,name):
        image=self.base/(name+'.sparseimage');mount=self.base/name
        subprocess.run(['hdiutil','create','-size','128m','-fs',filesystem,'-type','SPARSE',
                        '-volname','OW2 '+name,str(image)],check=True,capture_output=True)
        subprocess.run(['hdiutil','attach','-nobrowse','-mountpoint',str(mount),str(image)],check=True,capture_output=True)
        self.addCleanup(subprocess.run,['hdiutil','detach','-force',str(mount)],check=True,capture_output=True)
        return mount

    def test_disconnected_drive_is_refused_without_creating_folders(self):
        self.root=self.base/'Volumes'/'Unplugged SSD'/'Overwatch2Mac'
        self.assertEqual(self.call('status',success=False)[-1]['code'],'install_location_unavailable')
        self.assertFalse((self.base/'Volumes').exists())

    def test_external_apfs_volume_installs_and_uninstalls_to_its_own_trash(self):
        mount=self.volume('APFS','External APFS');self.root=mount/'Overwatch2Mac'
        status=self.call('status')[-1]
        self.assertGreater(status['free_bytes'],0);self.assertTrue((self.root/'.overwatch-2-mac-owner').exists())
        (self.root/'environment').mkdir();(self.root/'environment'/'system.reg').write_text('x')
        trashed=Path(self.call('uninstall')[-1]['trashed'])
        self.assertFalse(self.root.exists());self.assertTrue(trashed.is_relative_to(mount))
        self.assertTrue((trashed/'environment'/'system.reg').exists())

    def test_unsupported_new_volumes_are_refused_but_existing_installs_are_kept(self):
        for filesystem,name,code in [('ExFAT','ExFAT','unsupported_volume_format'),
                                     ('Case-sensitive APFS','CaseSens','case_sensitive_volume')]:
            with self.subTest(filesystem=filesystem):
                mount=self.volume(filesystem,name);self.root=mount/'Overwatch2Mac'
                self.assertEqual(self.call('status',success=False)[-1]['code'],code)
                self.assertFalse(self.root.exists())
        # An installation that predates the rule is never re-judged or blocked.
        self.root.mkdir();(self.root/'.overwatch-2-mac-owner').write_text('ow2-native-setup-v1\n')
        self.call('status')

    def test_discard_unused_removes_only_an_empty_scaffold(self):
        self.call('status');(self.root/'logs'/'rosetta-check.log').write_text('')
        self.assertEqual(self.call('discard-unused')[-1]['stage'],'location_released')
        self.assertFalse(self.root.exists());self.assertTrue(self.root.parent.exists())
        self.install()
        self.assertEqual(self.call('discard-unused',success=False)[-1]['code'],'location_in_use')
        self.assertEqual(self.call('status')[-1]['state']['active_runtime'],'v1')
        other=self.base/'Other'/'Overwatch2Mac';other.parent.mkdir();self.root=other
        self.call('status');(other/'downloads'/'partial.part').write_text('keep')
        self.assertEqual(self.call('discard-unused',success=False)[-1]['code'],'location_in_use')
        self.assertEqual((other/'downloads'/'partial.part').read_text(),'keep')


if __name__=='__main__':unittest.main()
