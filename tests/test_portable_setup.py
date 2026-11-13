"""Exercise the compiled native setup worker against real malicious archives.

No Wine/game is launched. Fixture runtimes are data used solely to test the
transaction/verification boundary; they are not gameplay or signing evidence.
"""
import hashlib
import fcntl
import io
import json
import os
import re
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unicodedata
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
from build_portable_setup import build

# The worker's Retina setting follows the main display (portable_retina.h); tests stand in
# a Retina one unless they choose otherwise, whatever this Mac's main display is.
os.environ.setdefault('OW2_SETUP_TEST_DISPLAY_SCALE','2')
os.environ.setdefault('OW2_SETUP_TEST_DISPLAY_REFRESH','120')
# Display sync follows the chip (portable_renderer.h, REC-93); tests stand in an M-series one
# unless they choose otherwise.
os.environ.setdefault('OW2_SETUP_TEST_CHIP','Apple M1 Pro')


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

    def call(self,command,*args,success=True,env=None):
        r=subprocess.run([str(self.binary),command,'--root',str(self.root),*map(str,args)],capture_output=True,text=True,
                         env=dict(os.environ,**env) if env else None)
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

    def test_saved_highlights_go_to_movies_and_earlier_clips_move_there(self):
        # REC-53: Overwatch's highlights folder becomes a link to Movies › Overwatch (NSHomeDirectory's,
        # here a scratch home through CFFIXED_USER_HOME), and clips saved before move there.
        home=self.base/'home';(home/'Movies').mkdir(parents=True);env={'CFFIXED_USER_HOME':str(home)}
        self.call('status',env=env)
        videos=self.root/'environment/drive_c/users/crossover/Documents/Overwatch/videos'
        (videos/'overwatch').mkdir(parents=True)
        (videos/'overwatch'/'Genji.mp4').write_text('saved before')
        (videos/'overwatch'/'.DS_Store').write_text('finder')
        movies=home/'Movies'/'Overwatch';movies.mkdir();(movies/'Genji.mp4').write_text('already there')
        events=self.call('highlights',env=env)
        self.assertEqual(events[0]['stage'],'highlights_moved');self.assertEqual(events[0]['count'],1)
        self.assertEqual(Path(events[-1]['folder']).resolve(),movies.resolve())
        self.assertTrue((videos/'overwatch').is_symlink())
        self.assertEqual((videos/'overwatch').resolve(),movies.resolve())
        self.assertEqual((movies/'Genji.mp4').read_text(),'already there')
        self.assertEqual((movies/'Genji 2.mp4').read_text(),'saved before')
        self.assertFalse((movies/'.DS_Store').exists())
        # Again: nothing to do. A file Overwatch writes through the link lands in Movies.
        self.assertEqual([e['stage'] for e in self.call('highlights',env=env)],['highlights_ready'])
        (videos/'overwatch'/'Tracer.mp4').write_text('new clip')
        self.assertEqual((movies/'Tracer.mp4').read_text(),'new clip')

    def test_highlights_link_follows_the_home_and_never_replaces_a_file(self):
        home=self.base/'home';(home/'Movies').mkdir(parents=True);env={'CFFIXED_USER_HOME':str(home)}
        self.call('status',env=env)
        videos=self.root/'environment/drive_c/users/crossover/Documents/Overwatch/videos';videos.mkdir(parents=True)
        # Fresh environment (the game never ran): folders and link are made, Movies › Overwatch too.
        self.call('highlights',env=env)
        self.assertEqual((videos/'overwatch').resolve(),(home/'Movies'/'Overwatch').resolve())
        # A link from another home is pointed at this one.
        other=self.base/'other';other.mkdir()
        (videos/'overwatch').unlink();(videos/'overwatch').symlink_to(other)
        self.call('highlights',env=env)
        self.assertEqual((videos/'overwatch').resolve(),(home/'Movies'/'Overwatch').resolve())
        # A file of that name is not Recall's to replace.
        (videos/'overwatch').unlink();(videos/'overwatch').write_text('not a folder')
        self.call('highlights',env=env)
        self.assertEqual((videos/'overwatch').read_text(),'not a folder')
        # Without a Windows profile there is nothing to link.
        __import__('shutil').rmtree(self.root/'environment')
        self.assertEqual([e['stage'] for e in self.call('highlights',env=env)],['highlights_ready'])

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

    def test_a_removed_file_stops_setup_until_repair_unpacks_it_again(self):
        # REC-94 (#75): security software quarantined one of the engine's Windows files. Checking
        # again, or installing the same version again (Try Again, a reinstalled app), fails the same
        # way; only Repair puts the file back.
        archive,digest=self.archive('v1')
        self.call('install-runtime','--archive',archive,'--sha256',digest,'--version','v1')
        (self.root/'runtimes/v1/lib/wine/x86_64-windows/kernel32.dll').unlink()
        self.assertEqual(self.call('verify',success=False)[-1]['code'],'runtime_file_missing')
        self.assertEqual(self.call('install-runtime','--archive',archive,'--sha256',digest,'--version','v1',success=False)[-1]['code'],'runtime_file_missing')
        self.call('install-runtime','--archive',archive,'--sha256',digest,'--version','v1','--repair','1');self.call('verify')
        self.assertTrue((self.root/'runtimes/v1/lib/wine/x86_64-windows/kernel32.dll').is_file())

    def test_files_the_app_offers_to_repair_are_ones_the_worker_reports(self):
        # REC-94: the failure screen makes Repair Game Files its main button for these codes.
        app=(ROOT/'app/Sources/SetupService.swift').read_text()
        codes=re.findall(r'"([a-z_]+)"',re.search(r'damagedFileCodes: Set<String>=\[(.*?)\]',app).group(1))
        worker=(ROOT/'scripts/portable_setup.m').read_text()
        self.assertIn('runtime_file_missing',codes)
        for code in codes:self.assertIn(f'fail(@"{code}")',worker)

    def test_a_kept_download_that_changed_is_removed_and_fetched_again(self):
        # REC-94: a kept Battle.net installer that no longer matches its hash used to fail every
        # retry (cached_download_hash_mismatch). It's removed and the download starts again; here
        # the download itself can't connect.
        self.call('status')
        expected='a'*64
        kept=self.root/'downloads'/expected
        kept.parent.mkdir(exist_ok=True);kept.write_bytes(b'changed after it was kept')
        code=self.call('download','--url','https://127.0.0.1:9/Battle.net-Setup.exe','--sha256',expected,success=False)[-1]['code']
        self.assertEqual(code,'download_interrupted_retry_to_resume')
        self.assertFalse(kept.exists())

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

    def test_persistent_setup_contention_times_out_without_mutation(self):
        self.call('status')
        with (self.root/'setup.lock').open('r+') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            started=time.monotonic()
            events=self.call('onboarded',success=False)
            self.assertEqual(events[0]['stage'],'waiting_for_setup')
            self.assertEqual(events[-1]['code'],'setup_already_running')
            self.assertLess(time.monotonic()-started,10)
            self.assertFalse((self.root/'state.json').exists())
        self.assertEqual(self.call('onboarded')[-1]['stage'],'onboarding_complete')

    def waiting_worker(self, command):
        worker=subprocess.Popen([str(self.binary),command,'--root',str(self.root)],
                                stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        def cleanup():
            if worker.poll() is None:worker.kill()
            worker.communicate()
        self.addCleanup(cleanup)
        # Use the worker's own event as a barrier, not a timing guess.
        import select
        self.assertTrue(select.select([worker.stdout],[],[],5)[0],'worker did not reach the lock')
        self.assertEqual(json.loads(worker.stdout.readline())['stage'],'waiting_for_setup')
        return worker

    def test_transient_contention_resumes_once_before_dispatch(self):
        self.call('status')
        with (self.root/'setup.lock').open('r+') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX)
            worker=self.waiting_worker('onboarded')
            self.assertIsNone(worker.poll())
            self.assertFalse((self.root/'state.json').exists())
            fcntl.flock(lock,fcntl.LOCK_UN)
            stdout,stderr=worker.communicate(timeout=5)
        self.assertEqual(worker.returncode,0,stdout+stderr)
        self.assertEqual([json.loads(line)['stage'] for line in stdout.splitlines()],['onboarding_complete'])
        self.assertTrue(json.loads((self.root/'state.json').read_text())['onboarding_complete'])

    def test_cancel_while_waiting_never_dispatches_or_releases_other_workers_lock(self):
        for command in ('onboarded','watch'):
            with self.subTest(command=command):
                self.call('status')
                with (self.root/'setup.lock').open('r+') as lock:
                    fcntl.flock(lock,fcntl.LOCK_EX)
                    worker=self.waiting_worker(command)
                    worker.terminate()
                    stdout,stderr=worker.communicate(timeout=3)
                    self.assertNotEqual(worker.returncode,0,stderr)
                    self.assertEqual(json.loads(stdout.splitlines()[-1])['code'],'cancelled')
                    self.assertFalse((self.root/'state.json').exists())
                    self.assertFalse((self.root/'launch-monitor.lock').exists())
                    with (self.root/'setup.lock').open('r+') as other:
                        with self.assertRaises(BlockingIOError):fcntl.flock(other,fcntl.LOCK_EX|fcntl.LOCK_NB)

    def test_lock_open_failure_is_not_reported_as_temporary_contention(self):
        self.call('status')
        (self.root/'setup.lock').unlink()
        (self.root/'setup.lock').mkdir()
        self.assertEqual(self.call('onboarded',success=False)[-1]['code'],'setup_lock_failed')

    def test_locked_parent_folder_stops_with_a_folder_access_code(self):
        # REC-54: a parent macOS won't let Recall write in stops at once, with a code the app shows
        # as its folder screen, and nothing is created. The player's own locked folder is repaired.
        self.root.parent.chmod(0o555)
        self.addCleanup(self.root.parent.chmod,0o755)
        self.assertEqual(self.call('status',success=False)[-1]['code'],'directory_creation_failed')
        self.assertFalse(self.root.exists())
        self.root.parent.chmod(0o755)
        self.root.mkdir();self.root.chmod(0o555)
        self.call('status')
        self.assertEqual(self.root.stat().st_mode&0o777,0o700)
        # Every code the app treats as a folder problem is one the worker reports.
        app=(ROOT/'app/Sources/SetupService.swift').read_text()
        codes=re.findall(r'"([a-z_]+)"',re.search(r'folderAccessCodes: Set<String>=\[(.*?)\]',app).group(1))
        worker=(ROOT/'scripts/portable_setup.m').read_text()
        self.assertIn('directory_creation_failed',codes)
        for code in codes:self.assertIn(f'fail(@"{code}")',worker)

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

    def test_voice_microphone_points_wine_at_the_built_in_microphone(self):
        # Wine's registry as the game leaves it: the built-in microphone's GUID, no defaults yet.
        self.call('status');(self.root/'environment').mkdir()
        registry=self.root/'environment'/'user.reg'
        device=('[Software\\\\Wine\\\\Drivers\\\\winecoreaudio.drv\\\\devices\\\\1,BuiltInMicrophoneDevice] 1790620772\n'
                '#time=1dd4f78b421c0b8\n"guid"=hex:76,c3,38,12,cf,58,16,4a,81,26,58,3b,91,93,ec,43\n\n')
        registry.write_text('WINE REGISTRY Version 2\n\n'+device)
        endpoint='{0.0.1.00000000}.{1238C376-58CF-4A16-8126-583B9193EC43}'
        result=self.call('voice-microphone','--uid','BuiltInMicrophoneDevice','--apply','0')[-1]
        self.assertEqual((result['device'],result['id'],result['changes']),('built_in',endpoint,['DefaultVoiceInput','DefaultInput']))
        # Already set: nothing to write. Back to macOS's default microphone: both values go.
        registry.write_text(registry.read_text()+'[Software\\\\Wine\\\\Drivers\\\\winecoreaudio.drv] 1790620772\n'
                            f'"DefaultVoiceInput"="{endpoint}"\n"DefaultInput"="{endpoint}"\n\n')
        self.assertEqual(self.call('voice-microphone','--uid','BuiltInMicrophoneDevice','--apply','0')[-1]['changes'],[])
        result=self.call('voice-microphone','--uid','none','--apply','0')[-1]
        self.assertEqual((result['device'],result['changes'],'id' in result),('default',['DefaultVoiceInput','DefaultInput'],False))
        # A microphone Wine has not listed yet gets a GUID first; an odd UID is never used.
        result=self.call('voice-microphone','--uid','OtherMicrophone','--apply','0')[-1]
        self.assertEqual(result['changes'],['guid','DefaultVoiceInput','DefaultInput'])
        self.assertRegex(result['id'],r'^\{0\.0\.1\.00000000\}\.\{[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\}$')
        result=self.call('voice-microphone','--uid','Bad]Name','--apply','0')[-1]
        self.assertEqual((result['device'],result['reason']),('default','unsupported_device'))

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

    # Move (REC-82, portable_move.h). The fixtures hold what a move must keep as it is: Wine's
    # links (never followed: z: is a link to /), modes, dates, attributes and odd names.
    def installation(self,files=0):
        self.call('status')
        env=self.root/'environment';game=env/'drive_c'/'Program Files (x86)'/'Overwatch'
        (env/'dosdevices').mkdir(parents=True);game.mkdir(parents=True)
        os.symlink('../drive_c',env/'dosdevices'/'c:');os.symlink('/',env/'dosdevices'/'z:');os.symlink('/dev/rdisk99s1',env/'dosdevices'/'e::')
        # Link targets are kept byte for byte: a precomposed name (which a string would decompose)
        # and one that is no text at all.
        os.symlink('/Volumes/caf\u00e9 \uac8c\uc784'.encode(),os.fsencode(env/'dosdevices'/'f:'))
        os.symlink(b'/Volumes/\xff\xfe',os.fsencode(env/'dosdevices'/'g:'))
        (game/'data.bin').write_bytes(os.urandom(3*1024*1024+17));os.utime(game/'data.bin',(1700000000,1700000000))
        subprocess.run(['xattr','-w','org.example.kept','value',str(game/'data.bin')],check=True)
        (game/'empty').write_bytes(b'');(game/'한글 파일 é.txt').write_text('names')
        # A file with a hole in it, as a download in progress leaves: its bytes are kept either way.
        with open(game/'sparse.bin','wb') as sparse:sparse.seek(4<<20);sparse.write(b'end')
        (game/'Overwatch.exe').write_bytes(b'MZ fixture');(game/'Overwatch.exe').chmod(0o755)
        (game/'read-only.ini').write_text('keep');(game/'read-only.ini').chmod(0o444)
        (env/'system.reg').write_text('WINE REGISTRY Version 2\n')
        (self.root/'cache'/'shaders').mkdir();(self.root/'cache'/'shaders'/'learned.bin').write_bytes(os.urandom(70000))
        for index in range(files):(self.root/'cache'/'shaders'/f'{index}.bin').write_bytes(os.urandom(4096))
        (self.root/'state.json').write_text(json.dumps({'schema':1,'stage':'battlenet_started','onboarding_complete':True}))
        return game

    def snapshot(self,folder):
        found={}
        for path in sorted(folder.rglob('*')):
            name=unicodedata.normalize('NFC',str(path.relative_to(folder)))
            if path.is_symlink():found[name]=('link',os.readlink(os.fsencode(path)))
            elif path.is_dir():found[name]=('folder',)
            else:found[name]=('file',hashlib.sha256(path.read_bytes()).hexdigest(),path.stat().st_mode&0o777,int(path.stat().st_mtime))
        return found

    def assertMoved(self,before,target,events):
        self.assertEqual([e['stage'] for e in events][-2:],['move_committed','moved'])
        self.assertFalse(self.root.exists());self.assertTrue(Path(events[-1]['to']).samefile(target))
        self.assertFalse(Path(str(target)+'.moving').exists());self.assertFalse((target/'.overwatch-2-mac-move').exists())
        after=self.snapshot(target)
        for name,value in before.items():self.assertEqual(after.get(name),value,name)
        self.assertEqual(os.readlink(target/'environment'/'dosdevices'/'z:'),'/')
        self.assertEqual(os.readlink(os.fsencode(target/'environment'/'dosdevices'/'f:')),'/Volumes/caf\u00e9 \uac8c\uc784'.encode())
        self.assertEqual((target/'.overwatch-2-mac-owner').read_text(),'ow2-native-setup-v1\n')
        # The worker takes the folder for its own from the new place.
        self.root=target
        self.assertTrue(self.call('status')[-1]['state']['onboarding_complete'])

    def test_move_to_another_volume_copies_checks_and_trashes_the_original(self):
        for filesystem,name in [('APFS','Move APFS'),('HFS+','Move HFS')]:
            with self.subTest(filesystem=filesystem):
                self.root=self.base/name/'Overwatch2Mac';self.root.parent.mkdir()
                game=self.installation();before=self.snapshot(self.root);source=self.root
                mount=self.volume(filesystem,name+' Volume');target=mount/'Overwatch2Mac'
                events=self.call('move','--to',target)
                progress=[e for e in events if e['stage']=='move_progress']
                self.assertEqual([e['phase'] for e in progress][0],'copying');self.assertEqual(progress[-1]['phase'],'checking')
                self.assertEqual(progress[-1]['bytes'],progress[-1]['total']);self.assertGreater(progress[-1]['total'],3*1024*1024)
                self.assertEqual([e for e in events if e['stage']=='move_problem'],[])
                self.assertTrue(events[-1]['copied']);trashed=Path(events[-1]['trashed'])
                self.addCleanup(shutil.rmtree,trashed,ignore_errors=True)
                self.assertTrue(trashed.is_relative_to(Path.home()/'.Trash'));self.assertTrue((trashed/'state.json').exists())
                self.assertMoved(before,target,events)
                moved=target/game.relative_to(source)/'data.bin'
                self.assertEqual(subprocess.run(['xattr','-p','org.example.kept',str(moved)],capture_output=True,text=True).stdout.strip(),'value')

    def test_move_on_the_same_volume_renames_the_folder(self):
        self.installation();before=self.snapshot(self.root)
        target=self.base/'Another Folder'/'Overwatch2Mac';target.parent.mkdir()
        # An empty folder of that name (Finder's own note aside) is the destination itself.
        target.mkdir();(target/'.DS_Store').write_bytes(b'finder')
        events=self.call('move','--to',target)
        self.assertFalse(events[-1]['copied']);self.assertNotIn('trashed',events[-1])
        self.assertEqual([e for e in events if e['stage']=='move_progress'],[])
        self.assertMoved(before,target,events)

    def test_move_refuses_a_place_it_cannot_use_and_changes_nothing(self):
        self.installation();before=self.snapshot(self.root)
        def refused(target,code):
            self.assertEqual(self.call('move','--to',target,success=False)[-1]['code'],code)
            self.assertEqual({k:v for k,v in self.snapshot(self.root).items() if k in before},before)
            self.assertFalse(Path(str(target)+'.moving').exists())
        refused(self.root,'move_same_location')
        refused(self.root/'cache'/'Overwatch2Mac','move_destination_inside_source')
        refused(self.base/'Volumes'/'Unplugged SSD'/'Overwatch2Mac','move_destination_unavailable')
        self.assertFalse((self.base/'Volumes').exists())
        # The player's own files, and another installation, are never merged into or replaced.
        personal=self.base/'Personal'/'Overwatch2Mac';personal.mkdir(parents=True);(personal/'notes.txt').write_text('keep')
        refused(personal,'move_destination_in_use');self.assertEqual((personal/'notes.txt').read_text(),'keep')
        apfs=self.volume('APFS','Refusals')
        other=apfs/'Overwatch2Mac';other.mkdir();(other/'.overwatch-2-mac-owner').write_text('ow2-native-setup-v1\n')
        refused(other,'move_destination_in_use')
        # A folder named like a part copy that this worker didn't make.
        foreign=apfs/'Games'/'Overwatch2Mac.moving';foreign.mkdir(parents=True);(foreign/'mine.txt').write_text('keep')
        self.assertEqual(self.call('move','--to',apfs/'Games'/'Overwatch2Mac',success=False)[-1]['code'],'move_destination_in_use')
        self.assertEqual(self.call('move','--to',apfs/'Games'/'Overwatch2Mac','--discard','1')[-1]['stage'],'move_discarded')
        self.assertEqual((foreign/'mine.txt').read_text(),'keep')
        for filesystem,name,code in [('ExFAT','NoExFAT','unsupported_volume_format'),('Case-sensitive APFS','NoCase','case_sensitive_volume')]:
            refused(self.volume(filesystem,name)/'Overwatch2Mac',code)
        # More than the drive has room for: refused before a file is copied, with nothing left there.
        with open(self.root/'cache'/'large.bin','wb') as large:large.truncate(300<<20)
        before=self.snapshot(self.root)
        refused(apfs/'Room'/'Overwatch2Mac','move_destination_unavailable')
        (apfs/'Room').mkdir();refused(apfs/'Room'/'Overwatch2Mac','move_destination_full')
        self.assertEqual(list((apfs/'Room').iterdir()),[])
        self.assertTrue(self.call('status')[-1]['state']['onboarding_complete'])

    def test_a_part_copy_is_finished_by_the_next_move_and_checked_like_any_other(self):
        game=self.installation();before=self.snapshot(self.root);inside=game.relative_to(self.root)
        mount=self.volume('APFS','Resume');target=mount/'Overwatch2Mac';part=mount/'Overwatch2Mac.moving'
        # What an interrupted move can leave: a file with the original's size and date but other
        # bytes, a file the installation no longer has, and a folder where a file is now.
        (part/inside).mkdir(parents=True);(part/'.overwatch-2-mac-move').write_text('ow2-move-v1\n')
        (part/inside/'data.bin').write_bytes(bytes(3*1024*1024+17));os.utime(part/inside/'data.bin',(1700000000,1700000000))
        (part/'removed-since.txt').write_text('old');(part/inside/'empty').mkdir();(part/inside/'empty'/'old').write_text('old')
        # A marker from a move that stopped just before its last step, and a link where the
        # installation has a folder: nothing is ever written through it.
        (part/'.overwatch-2-mac-owner').write_text('ow2-native-setup-v1\n')
        outside=self.base/'Outside';outside.mkdir();(outside/'mine.txt').write_text('keep')
        (part/'cache').mkdir();os.symlink(outside,part/'cache'/'shaders')
        events=self.call('move','--to',target)
        self.assertEqual(sorted(p.name for p in outside.iterdir()),['mine.txt']);self.assertEqual((outside/'mine.txt').read_text(),'keep')
        self.assertTrue((target/'cache'/'shaders').is_dir() and not (target/'cache'/'shaders').is_symlink())
        # The file with other bytes was taken as copied, caught by the check and copied again.
        self.assertEqual([e['file'] for e in events if e['stage']=='move_problem'],[str(inside/'data.bin')])
        self.addCleanup(shutil.rmtree,events[-1]['trashed'],ignore_errors=True)
        self.assertFalse((target/'removed-since.txt').exists())
        self.assertMoved(before,target,events)

    def moving(self,target,pause):
        process=subprocess.Popen([str(self.binary),'move','--root',str(self.root),'--to',str(target)],stdout=subprocess.PIPE,text=True,
                                 env={**os.environ,'OW2_SETUP_TEST_MOVE_PAUSE':str(pause)})
        self.addCleanup(process.kill);self.addCleanup(process.stdout.close)
        events=[]
        for line in process.stdout:
            events.append(json.loads(line))
            if events[-1]['stage']=='move_progress' and events[-1]['bytes']>0:break
        self.assertEqual(events[-1]['stage'],'move_progress',events)
        self.assertLess(events[-1]['bytes'],events[-1]['total'])
        return process,events

    def test_cancelling_a_move_removes_the_part_copy_and_keeps_the_original(self):
        self.installation(files=80);before=self.snapshot(self.root)
        mount=self.volume('APFS','Cancel');target=mount/'Overwatch2Mac'
        process,events=self.moving(target,40)
        self.assertTrue((mount/'Overwatch2Mac.moving'/'.overwatch-2-mac-move').exists())
        process.send_signal(signal.SIGTERM)
        events+=[json.loads(line) for line in process.stdout]
        self.assertNotEqual(process.wait(),0);self.assertEqual((events[-1]['stage'],events[-1]['code']),('error','cancelled'))
        self.assertEqual([p.name for p in mount.iterdir() if not p.name.startswith('.')],[])
        self.assertEqual({k:v for k,v in self.snapshot(self.root).items() if k in before},before)
        self.assertTrue(self.call('status')[-1]['state']['onboarding_complete'])

    def test_a_drive_unplugged_mid_move_keeps_the_original_and_the_next_move_goes_on(self):
        self.installation(files=80);before=self.snapshot(self.root)
        mount=self.volume('APFS','Unplugged');target=mount/'Overwatch2Mac'
        process,events=self.moving(target,40)
        subprocess.run(['hdiutil','detach','-force',str(mount)],check=True,capture_output=True)
        events+=[json.loads(line) for line in process.stdout]
        self.assertNotEqual(process.wait(),0);self.assertEqual((events[-1]['stage'],events[-1]['code']),('error','move_destination_disconnected'))
        self.assertFalse(mount.exists())
        self.assertEqual({k:v for k,v in self.snapshot(self.root).items() if k in before},before)
        self.assertTrue(self.call('status')[-1]['state']['onboarding_complete'])
        # Plugged back in: the part copy is still there, and the move finishes from it.
        subprocess.run(['hdiutil','attach','-nobrowse','-mountpoint',str(mount),str(self.base/'Unplugged.sparseimage')],check=True,capture_output=True)
        self.assertTrue((mount/'Overwatch2Mac.moving'/'.overwatch-2-mac-move').exists())
        events=self.call('move','--to',target)
        self.addCleanup(shutil.rmtree,events[-1]['trashed'],ignore_errors=True)
        self.assertMoved(before,target,events)
        # A move the player gives up on instead: --discard 1 removes the part copy.
        self.root=self.base/'Second'/'Overwatch2Mac';self.root.parent.mkdir();self.installation(files=80)
        (mount/'Given Up').mkdir()
        process,events=self.moving(mount/'Given Up'/'Overwatch2Mac',40)
        process.kill();process.wait()
        self.assertTrue((mount/'Given Up'/'Overwatch2Mac.moving').exists())
        # It needs no data folder: the installation's own drive may be the one that was unplugged.
        self.root=self.base/'Volumes'/'Unplugged SSD'/'Overwatch2Mac'
        self.assertEqual(self.call('status',success=False)[-1]['code'],'install_location_unavailable')
        self.assertEqual(self.call('move','--to',mount/'Given Up'/'Overwatch2Mac','--discard','1')[-1]['stage'],'move_discarded')
        self.assertEqual(list((mount/'Given Up').iterdir()),[]);self.assertFalse((self.base/'Volumes').exists())

    def test_a_move_that_stopped_before_its_first_file_does_not_block_the_next(self):
        self.installation();before=self.snapshot(self.root)
        mount=self.volume('APFS','Empty Part');target=mount/'Overwatch2Mac'
        # The part copy's folder was made and the move ended before its tag was written.
        (mount/'Overwatch2Mac.moving').mkdir();(mount/'Overwatch2Mac.moving'/'.DS_Store').write_bytes(b'finder')
        events=self.call('move','--to',target)
        self.addCleanup(shutil.rmtree,events[-1]['trashed'],ignore_errors=True)
        self.assertMoved(before,target,events)


if __name__=='__main__':unittest.main()
