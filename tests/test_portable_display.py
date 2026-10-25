"""Real native display edits preserve unrelated game preferences and ownership."""
import json
import os
import re
import subprocess
import sys
import time
import test_portable_setup as setup
import unittest

class DisplaySetup(setup.NativeSetup):
    def profile(self,text):
        self.install()
        path=self.root/'environment/drive_c/users/player/Documents/Overwatch/Settings/Settings_v0.ini'
        path.parent.mkdir(parents=True);path.write_bytes(text)
        server=self.root/'runtimes/v1/bin/wineserver';server.write_text('#!/bin/sh\nexit 0\n');server.chmod(0o755)
        return path
    def test_display_preserves_fps_quality_input_and_crlf(self):
        before=b'[Render.13]\r\nFrameRateCap = "237"\r\nTextureQuality = "3"\r\nFullScreenHeight = "1200"\r\n[Input.1]\r\nSensitivity = "9.5"\r\n'
        path=self.profile(before)
        self.call('display','--height','1080')
        after=path.read_bytes()
        for line in [b'FrameRateCap = "237"',b'TextureQuality = "3"',b'Sensitivity = "9.5"']:self.assertIn(line,after)
        self.assertIn(b'FullScreenHeight = "1080"\r\n',after)
        # A height alone (the 0.1.x apps) means 1920 wide.
        self.assertIn(b'FullScreenWidth = "1920"\r\n',after)
        self.assertEqual((self.root/'settings-backup/before-display-change.ini').read_bytes(),before)
        self.assertEqual(self.call('status')[-1]['state']['display_height'],1080)
    def test_each_supported_resolution_sets_width_and_height(self):
        path=self.profile(b'[Render.13]\n')
        for width,height in ((2560,1440),(2560,1600),(3840,2160),(3840,2400),(1920,1200)):
            saved=self.call('display','--width',str(width),'--height',str(height))[-1]
            self.assertEqual((saved['width'],saved['height']),(width,height))
            text=path.read_text()
            for key,value in (('FullScreenWidth',width),('WindowedWidth',width),('FullScreenHeight',height),('WindowedHeight',height)):
                self.assertIn(f'{key} = "{value}"',text)
            state=self.call('status')[-1]['state']
            self.assertEqual((state['display_width'],state['display_height']),(width,height))
    def test_unsupported_resolutions_change_nothing(self):
        path=self.profile(b'[Render.13]\n')
        for width,height in (('2560','1080'),('1920','1440'),('3840','2401'),('wide','1080'),('1920','')):
            self.assertEqual(self.call('display','--width',width,'--height',height,success=False)[-1]['code'],'unsupported_resolution')
        self.assertEqual(path.read_bytes(),b'[Render.13]\n')
    def test_launch_passes_on_only_known_graphics_progress(self):
        # The pipeline helper's progress lines become graphics events for the launcher;
        # anything else it prints, and unknown or malformed fields, stay in its log.
        self.profile(b'[Render.13]\n')
        engine=self.root/'runtimes/v1'
        (engine/'config/dxmt.conf').write_text((setup.ROOT/'config/dxmt-source60-1200.conf').read_text())
        environment=self.root/'environment'
        (environment/'user.reg').write_text('[Software\\\\Wine\\\\Mac Driver]\n"RetinaMode"="Y"\n')
        client=environment/'drive_c/Program Files (x86)/Battle.net/Battle.net.exe'
        client.parent.mkdir(parents=True);client.write_text('fixture')
        helper=self.binary.parent/'ow2-pipeline'
        lines=['Kept learned pipelines from 1 earlier folders','{"graphics":"learned","learned":5,"ready":2}',
               '{"graphics":"warming","target":5,"cache":"/Users/someone"}',
               '{"graphics":"pipelines","items":[["0123456789ab",1.5,true],["../../etc/x",2,true],["abcdefabcdef",-1,false],["fedcba987654",40,false]]}',
               '{"graphics":"unknown","learned":1}','{"graphics":"done","ready":3,"added":1,"warmed":5,"path":"/Users/someone"}','{"stage":"error","code":"forged"}']
        helper.write_text('#!/bin/sh\n'+''.join(f"printf '%s\\n' '{line}'\n" for line in lines));helper.chmod(0o755)
        self.addCleanup(helper.unlink)
        events=self.call('launch',success=False)  # the fixture runtime cannot start Wine
        self.assertEqual([e for e in events if e['stage']=='graphics'],[
            {'stage':'graphics','phase':'learned','learned':5,'ready':2},
            {'stage':'graphics','phase':'warming','target':5},
            {'stage':'graphics','phase':'pipelines','items':[['0123456789ab',1.5,True],['fedcba987654',40,False]]},
            {'stage':'graphics','phase':'done','ready':3,'added':1,'warmed':5}])
        self.assertNotIn('forged',[e.get('code') for e in events])
    def test_launch_names_the_game_app_whose_shaders_are_warmed(self):
        # With Game Mode the game runs as the engine's game app, which keeps its own
        # shader cache; the pipeline helper warms it. Without Game Mode it runs as Wine's
        # own loader, which keeps another (REC-51). With neither in the engine the helper
        # gets the installation only.
        self.profile(b'[Render.13]\n')
        engine=self.root/'runtimes/v1'
        (engine/'config/dxmt.conf').write_text((setup.ROOT/'config/dxmt-source60-1200.conf').read_text())
        environment=self.root/'environment'
        (environment/'user.reg').write_text('[Software\\\\Wine\\\\Mac Driver]\n"RetinaMode"="Y"\n')
        client=environment/'drive_c/Program Files (x86)/Battle.net/Battle.net.exe'
        client.parent.mkdir(parents=True);client.write_text('fixture')
        seen=self.base/'pipeline-arguments'
        helper=self.binary.parent/'ow2-pipeline';helper.write_text(f'#!/bin/sh\nprintf "%s\\n" "$@" > "{seen}"\n');helper.chmod(0o755)
        self.addCleanup(helper.unlink)
        def arguments(*options):
            seen.unlink(missing_ok=True)
            self.call('launch',*options,success=False)  # the fixture runtime cannot start Wine
            return [str(setup.Path(line).resolve()) for line in seen.read_text().splitlines()]
        self.assertEqual(arguments(),[str(self.root)])
        app=engine/'lib/wine/game-mode/Overwatch.app'
        (app/'Contents').mkdir(parents=True);(app/'Contents/Info.plist').write_text('<plist/>')
        self.assertEqual(arguments(),[str(self.root),str(app)])
        self.assertEqual(arguments('--game-mode','0'),[str(self.root)])
        loader=engine/'lib/wine/x86_64-unix/wine'
        loader.parent.mkdir(parents=True,exist_ok=True);loader.write_text('#!/bin/sh\n');loader.chmod(0o755)
        self.assertEqual(arguments('--game-mode','0'),[str(self.root),str(loader)])
        self.assertEqual(arguments('--game-mode','1'),[str(self.root),str(app)])
    def test_launch_first_stops_the_last_sessions_preparation(self):
        # After a match the session's monitor prepares the archive, which takes minutes.
        # A launch stops it (it holds launch-monitor.lock, its pid in the cache) before
        # anything else, and leaves alone a process that only has a pid left behind.
        self.profile(b'[Render.13]\n')
        (self.root/'runtimes/v1/config/dxmt.conf').write_text((setup.ROOT/'config/dxmt-source60-1200.conf').read_text())
        (self.root/'environment/user.reg').write_text('[Software\\\\Wine\\\\Mac Driver]\n"RetinaMode"="Y"\n')
        client=self.root/'environment/drive_c/Program Files (x86)/Battle.net/Battle.net.exe'
        client.parent.mkdir(parents=True);client.write_text('fixture')
        (self.root/'cache').mkdir(exist_ok=True)
        lock,pidfile,ready=self.root/'launch-monitor.lock',self.root/'cache/after-session.pid',self.base/'monitor-ready'
        monitor=subprocess.Popen([sys.executable,'-c','import fcntl,signal,sys,time\n'
            f'f=open({str(lock)!r},"a");fcntl.flock(f,fcntl.LOCK_EX)\n'
            'signal.signal(signal.SIGTERM,lambda *a:sys.exit(0))\n'
            f'open({str(ready)!r},"w").close();time.sleep(60)'])
        self.addCleanup(lambda:(monitor.kill(),monitor.wait()))
        deadline=time.monotonic()+10
        while not ready.exists() and time.monotonic()<deadline:time.sleep(.05)
        pidfile.write_text(str(monitor.pid))
        self.call('launch',success=False)  # the fixture runtime cannot start Wine
        self.assertEqual(monitor.wait(timeout=1),0)
        bystander=subprocess.Popen(['/bin/sleep','60']);self.addCleanup(lambda:(bystander.kill(),bystander.wait()))
        pidfile.write_text(str(bystander.pid))
        self.call('launch',success=False)
        self.assertIsNone(bystander.poll())
    def launchable_fixture(self):
        self.profile(b'[Render.13]\n')
        (self.root/'runtimes/v1/config/dxmt.conf').write_text((setup.ROOT/'config/dxmt-source60-1200.conf').read_text())
        (self.root/'environment/user.reg').write_text('[Software\\\\Wine\\\\Mac Driver]\n"RetinaMode"="Y"\n')
        client=self.root/'environment/drive_c/Program Files (x86)/Battle.net/Battle.net.exe'
        client.parent.mkdir(parents=True);client.write_text('fixture')
    def test_shader_memory_is_kept_and_written_where_the_game_reads_it(self):
        # Settings › Graphics › Shader memory: the worker keeps the choice and writes it beside
        # the shader cache (load.json), which Overwatch reads as it starts. A launch writes it
        # first, so a game started from a Battle.net already open has it too. Without a choice
        # it is all of it, on every Mac.
        self.launchable_fixture()
        load=self.root/'cache/pipelines/load.json'
        self.call('launch',success=False)  # the fixture runtime cannot start Wine
        self.assertEqual(json.loads(load.read_text()),{'schema':1,'limit':'all'})
        for choice,limit in (('first','first'),('450',450),('all','all')):
            self.assertEqual(self.call('shader-memory','--limit',choice)[-1],{'stage':'shader_memory','limit':choice})
            self.assertEqual(json.loads(load.read_text()),{'schema':1,'limit':limit})
            self.assertEqual(self.call('status')[-1]['state']['shader_memory'],choice)
        self.call('shader-memory','--limit','first');load.unlink()
        self.call('launch',success=False)
        self.assertEqual(json.loads(load.read_text()),{'schema':1,'limit':'first'})
        for value in ('0','0450','none','12345678','-1',''):
            self.assertEqual(self.call('shader-memory','--limit',value,success=False)[-1]['code'],'invalid_arguments')
        self.assertEqual(self.call('status')[-1]['state']['shader_memory'],'first')
    def test_delete_shaders_clears_every_shader_cache_and_keeps_the_choice(self):
        # Settings › Graphics › Clear Shader Cache (#37): DXMT's translated shaders, the learned
        # and prepared pipelines with the helper's records, and macOS's own cache for the
        # engine's game app all go, so every shader builds again; the Shader memory choice is
        # kept (load.json is written again for the next launch). Another app's cache stays.
        self.launchable_fixture()
        cache=self.root/'cache'
        load=cache/'pipelines/load.json'
        pack=cache/'pipelines/0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
        pack.mkdir(parents=True);(pack/'archive.json').write_text('{"archives":[]}')
        (cache/'shaders').mkdir();(cache/'shaders/shaders_320.db').write_text('db')
        records=('pack.json','prepared.json','preparing.json','warmed.json','shader-update')
        for name in records:(cache/name).write_text('{}')
        caches=setup.Path(subprocess.run(['/usr/bin/getconf','DARWIN_USER_CACHE_DIR'],capture_output=True,text=True,check=True).stdout.strip())
        tag=self.base.name.replace('_','-')
        game=caches/f'org.overwatch2mac.test-{tag}';other=caches/f'org.example.recall-test-{tag}'
        for folder in (game,other):
            (folder/'com.apple.metal').mkdir(parents=True);(folder/'com.apple.metal/functions.data').write_text('compiled')
            self.addCleanup(subprocess.run,['/bin/rm','-rf','--',str(folder)])
        app=self.root/'runtimes/v1/lib/wine/game-mode/Overwatch.app/Contents'
        app.mkdir(parents=True)
        def identify(identifier):
            (app/'Info.plist').write_text('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
                                          f'<key>CFBundleIdentifier</key><string>{identifier}</string></dict></plist>')
        identify(game.name)
        self.call('shader-memory','--limit','first')
        self.assertEqual(self.call('delete-shaders')[-1],{'stage':'shaders_deleted'})
        self.assertFalse(pack.exists())
        self.assertFalse((cache/'shaders').exists())
        for name in records:self.assertFalse((cache/name).exists(),name)
        self.assertFalse(game.exists())
        self.assertFalse((self.root/'tmp/cleared-shaders').exists())
        self.assertEqual(json.loads(load.read_text()),{'schema':1,'limit':'first'})
        self.assertEqual(self.call('status')[-1]['state']['shader_memory'],'first')
        # Only the engine's own game app: never a cache an app named otherwise keeps.
        identify(other.name)
        self.assertEqual(self.call('delete-shaders')[-1],{'stage':'shaders_deleted'})
        self.assertTrue((other/'com.apple.metal/functions.data').exists())
        # Nothing to clear is not an error, and the choice is written all the same.
        self.assertEqual(json.loads(load.read_text()),{'schema':1,'limit':'first'})
    def test_delete_shaders_refuses_while_battlenet_is_open(self):
        # A Battle.net left open could start Overwatch on half a cache, and the session's
        # monitor would prepare nothing after the match: both must be closed first.
        self.launchable_fixture()
        engine=self.root/'runtimes/v1'
        (self.root/'cache/shaders').mkdir(parents=True);(self.root/'cache/shaders/shaders_320.db').write_text('db')
        source=self.base/'hold.c'
        source.write_text('#include <fcntl.h>\n#include <sys/mman.h>\n#include <unistd.h>\n'
                          'int main(int c,char **v){int f=open(v[1],O_RDONLY);if(f<0||mmap(0,1,PROT_READ,MAP_SHARED,f,0)==MAP_FAILED)return 1;'
                          'write(1,"ready\\n",6);sleep(30);return 0;}\n')
        client=engine/'bin/C:\\Battle.net.exe'
        subprocess.run(['/usr/bin/clang','-o',str(client),str(source)],check=True,capture_output=True)
        mapped=self.root/'environment/drive_c/Program Files (x86)/Battle.net/Battle.net.exe'
        held=subprocess.Popen([str(client),str(mapped)],stdout=subprocess.PIPE,text=True)
        self.addCleanup(lambda:(held.kill(),held.wait(),held.stdout.close()))
        self.assertEqual(held.stdout.readline(),'ready\n')
        self.assertEqual(self.call('delete-shaders',success=False)[-1]['code'],'close_game_before_maintenance')
        self.assertTrue((self.root/'cache/shaders/shaders_320.db').exists())
        held.kill();held.wait()
        self.assertEqual(self.call('delete-shaders')[-1],{'stage':'shaders_deleted'})
        self.assertFalse((self.root/'cache/shaders').exists())
    def test_delete_shaders_refuses_while_a_preparation_runs(self):
        # The cache is written by the preparation that runs after a match, so asking for a
        # deletion while one runs is refused, and works once it has finished.
        self.launchable_fixture()
        (self.root/'cache').mkdir(exist_ok=True)
        helper=self.binary.parent/'ow2-pipeline'
        helper.write_text(f'#!/bin/sh\nprintf "%s\\n" "$@" > "{self.base}/pipeline-arguments"\nsleep 4\n');helper.chmod(0o755)
        self.addCleanup(helper.unlink)
        def stop_monitors():
            for name in ('monitor.pid','after-session.pid'):
                try:pid=int((self.root/'cache'/name).read_text())
                except (OSError,ValueError):continue
                subprocess.run(['/bin/kill',str(pid)],capture_output=True)
        self.addCleanup(stop_monitors)
        self.assertEqual(self.call('prepare-shaders')[-1],{'stage':'shader_preparation_started'})
        deadline=time.monotonic()+15
        while not (self.root/'cache/after-session.pid').exists() and time.monotonic()<deadline:time.sleep(.05)
        self.assertEqual(self.call('delete-shaders',success=False)[-1]['code'],'shader_preparation_running')
        deadline=time.monotonic()+30
        while (self.root/'cache/after-session.pid').exists() and time.monotonic()<deadline:time.sleep(.1)
        self.assertEqual(self.call('delete-shaders')[-1],{'stage':'shaders_deleted'})
        self.assertTrue((self.root/'cache/pipelines/load.json').exists())
    def test_prepare_shaders_prepares_now_in_a_monitor_of_its_own(self):
        # The one-time shader cache update: a monitor runs the after-match preparation now,
        # marked for the app as the update, and replaces a monitor waiting for a match. Asked
        # again while it prepares, it is left to finish.
        self.launchable_fixture()
        (self.root/'cache').mkdir(exist_ok=True)
        seen,marked=self.base/'pipeline-arguments',self.base/'pipeline-marked'
        helper=self.binary.parent/'ow2-pipeline'
        helper.write_text(f'#!/bin/sh\n[ -e "{self.root}/cache/shader-update" ] && touch "{marked}"\n'
                          f'printf "%s\\n" "$@" > "{seen}"\nsleep 4\n');helper.chmod(0o755)
        self.addCleanup(helper.unlink)
        def stop_monitors():
            for name in ('monitor.pid','after-session.pid'):
                try:pid=int((self.root/'cache'/name).read_text())
                except (OSError,ValueError):continue
                subprocess.run(['/bin/kill',str(pid)],capture_output=True)
        self.addCleanup(stop_monitors)
        # A monitor waiting for a match (no Battle.net: it would end after two minutes).
        waiting=subprocess.Popen([str(self.binary),'watch','--root',str(self.root)],stdout=subprocess.DEVNULL)
        self.addCleanup(lambda:(waiting.kill(),waiting.wait()))
        deadline=time.monotonic()+15
        while not (self.root/'cache/monitor.pid').exists() and time.monotonic()<deadline:time.sleep(.05)
        self.assertEqual(int((self.root/'cache/monitor.pid').read_text()),waiting.pid)
        self.assertEqual(self.call('prepare-shaders')[-1],{'stage':'shader_preparation_started'})
        self.assertIsNotNone(waiting.wait(timeout=10))
        deadline=time.monotonic()+30
        while not seen.exists() and time.monotonic()<deadline:time.sleep(.05)
        self.assertEqual([str(setup.Path(line).resolve()) if line.startswith('/') else line for line in seen.read_text().splitlines()],['--after-session',str(self.root)])
        self.assertTrue(marked.exists())
        self.assertEqual(self.call('prepare-shaders')[-1],{'stage':'shader_preparation_running'})
        # Done: the marker and the pid of the preparation are gone; the monitor watches on.
        deadline=time.monotonic()+30
        while (self.root/'cache/after-session.pid').exists() and time.monotonic()<deadline:time.sleep(.1)
        self.assertFalse((self.root/'cache/after-session.pid').exists())
        self.assertFalse((self.root/'cache/shader-update').exists())
        self.assertTrue((self.root/'cache/monitor.pid').exists())
    def test_launch_writes_the_canvas_size_with_dxmt_option_names(self):
        # DXMT matches option names exactly; a case-insensitive edit once wrote
        # "fullScreenCanvasHeight", which turned the canvas off for 1080.
        path=self.profile(b'[Render.13]\n')
        engine=self.root/'runtimes/v1'
        (engine/'config/dxmt.conf').write_text((setup.ROOT/'config/dxmt-source60-1200.conf').read_text())
        environment=self.root/'environment'
        (environment/'user.reg').write_text('[Software\\\\Wine\\\\Mac Driver]\n"RetinaMode"="Y"\n')
        client=environment/'drive_c/Program Files (x86)/Battle.net/Battle.net.exe'
        client.parent.mkdir(parents=True);client.write_text('fixture')
        for width,height in ((1920,1080),(2560,1440)):
            self.call('display','--width',str(width),'--height',str(height))
            self.call('launch',success=False)  # the fixture runtime cannot start Wine
            config=(self.root/'dxmt.conf').read_text()
            self.assertIn(f'dxgi.fullscreenCanvasWidth = {width}\n',config)
            self.assertIn(f'dxgi.fullscreenCanvasHeight = {height}\n',config)
            self.assertNotIn('fullScreenCanvas',config)
            self.assertIn(f'FullScreenWidth = "{width}"',path.read_text())
    def test_launch_ends_a_session_that_started_under_other_displays(self):
        # Battle.net's update Agent can keep a Wine session alive after the client
        # closes. After the owner unplugged their main display, Overwatch started in
        # such a session found no display ("No compatible graphics hardware").
        self.profile(b'[Render.13]\n')
        engine=self.root/'runtimes/v1'
        (engine/'config/dxmt.conf').write_text((setup.ROOT/'config/dxmt-source60-1200.conf').read_text())
        environment=self.root/'environment'
        (environment/'user.reg').write_text('[Software\\\\Wine\\\\Mac Driver]\n"RetinaMode"="Y"\n')
        client=environment/'drive_c/Program Files (x86)/Battle.net/Battle.net.exe'
        client.parent.mkdir(parents=True);client.write_text('fixture')
        calls=self.base/'wineserver-calls'
        server=engine/'bin/wineserver';server.write_text(f'#!/bin/sh\necho "$1" >> "{calls}"\nexit 0\n')
        def ended():
            text=calls.read_text() if calls.exists() else ''
            calls.unlink(missing_ok=True)
            return '-k' in text.split()
        self.call('launch',success=False)  # the fixture runtime cannot start Wine
        displays=self.call('status')[-1]['state'].get('session_displays')
        if not displays:self.skipTest('this environment has no display list')
        self.assertTrue(ended())  # a session of unknown displays
        self.call('launch',success=False)
        self.assertFalse(ended())  # the same displays: a running session is kept
        state=self.root/'state.json';saved=setup.json.loads(state.read_text())
        saved['session_displays']='1 main 0,0 2560x1440 2560x1440 m0';state.write_text(setup.json.dumps(saved))
        self.call('launch',success=False)
        self.assertTrue(ended())
        self.assertEqual(self.call('status')[-1]['state']['session_displays'],displays)
    def test_launch_ends_a_session_before_changing_retina_mode(self):
        # Retina mode follows the main display and changes only between sessions; one kept
        # alive by Battle.net's update Agent is ended first, as for a display change.
        self.profile(b'[Render.13]\n')
        engine=self.root/'runtimes/v1'
        (engine/'config/dxmt.conf').write_text((setup.ROOT/'config/dxmt-source60-1200.conf').read_text())
        environment=self.root/'environment'
        (environment/'user.reg').write_text('[Software\\\\Wine\\\\Mac Driver]\n"RetinaMode"="Y"\n')
        client=environment/'drive_c/Program Files (x86)/Battle.net/Battle.net.exe'
        client.parent.mkdir(parents=True);client.write_text('fixture')
        calls=self.base/'wineserver-calls'
        server=engine/'bin/wineserver';server.write_text(f'#!/bin/sh\necho "$1" >> "{calls}"\nexit 0\n');server.chmod(0o755)
        wine=engine/'bin/wine'
        wine.write_text('#!/bin/sh\ncase "$*" in *RetinaMode*) /usr/bin/sed -i "" "s/RetinaMode\\"=\\"Y/RetinaMode\\"=\\"N/" "$WINEPREFIX/user.reg";; esac\nexit 0\n')
        wine.chmod(0o755)
        self.addCleanup(subprocess.run,['pkill','-f',f'ow2-setup watch --root {self.root}'])
        self.call('launch')  # a first session under these displays
        calls.unlink(missing_ok=True)
        os.environ['OW2_SETUP_TEST_DISPLAY_SCALE']='1'
        self.addCleanup(os.environ.__setitem__,'OW2_SETUP_TEST_DISPLAY_SCALE','2')
        events={e['stage']:e for e in self.call('launch')}
        self.assertIn('-k',calls.read_text().split())
        self.assertEqual(events['retina_configured'],{'stage':'retina_configured','retina':False})
        self.assertIn('"RetinaMode"="N"',(environment/'user.reg').read_text())
    def test_metal_hud_and_game_mode_reach_battlenet_as_chosen(self):
        # Battle.net starts Overwatch with its own environment, so the HUD and Game Mode travel in it.
        self.profile(b'[Render.13]\n')
        engine=self.root/'runtimes/v1'
        (engine/'config/dxmt.conf').write_text((setup.ROOT/'config/dxmt-source60-1200.conf').read_text())
        environment=self.root/'environment'
        (environment/'user.reg').write_text('[Software\\\\Wine\\\\Mac Driver]\n"RetinaMode"="Y"\n')
        client=environment/'drive_c/Program Files (x86)/Battle.net/Battle.net.exe'
        client.parent.mkdir(parents=True);client.write_text('fixture')
        seen=self.base/'battlenet-environment'
        # Launches also run Wine's registry tool (proxy, microphone); only Battle.net's start counts.
        wine=engine/'bin/wine';wine.write_text(f'#!/bin/sh\ncase "$1" in *Battle.net.exe) env > "{seen}.part" && mv "{seen}.part" "{seen}";; esac\n');wine.chmod(0o755)
        # Each launch also starts the client monitor, which waits for a Battle.net that never comes.
        self.addCleanup(subprocess.run,['pkill','-f',f'ow2-setup watch --root {self.root}'])
        def launched(*args):
            seen.unlink(missing_ok=True)
            self.assertEqual(self.call('launch',*args)[-1]['stage'],'battlenet_open')
            for _ in range(100):
                if seen.exists():break
                time.sleep(0.05)
            return dict(line.split('=',1) for line in seen.read_text().splitlines() if '=' in line)
        self.assertFalse([key for key in launched() if key.startswith('MTL_HUD')])
        hud=launched('--metal-hud','1')
        self.assertEqual((hud['MTL_HUD_ENABLED'],hud['MTL_HUD_DISABLE_MENU_BAR']),('1','1'))
        self.assertEqual(hud['MTL_HUD_ELEMENTS'].split(','),['device','rosetta','layersize','memory','gamemode','fps','gputime','frameinterval','frameintervalgraph','shaders'])
        self.assertEqual(hud['WINEMAC_MOUSELOOK'],'Overwatch.exe')  # the contract's environment is unchanged
        self.assertEqual(hud['WINE_APP_DPI'],'192:Battle.net.exe;Battle.net Launcher.exe;BlizzardError.exe')
        self.assertFalse([key for key in launched('--metal-hud','0') if key.startswith('MTL_HUD')])
        # Game Mode is on unless the app passes --game-mode 0 (its switch, off by default from 1.6;
        # REC-51), and the HUD does not change it.
        self.assertEqual(hud['WINE_GAME_MODE'],'Overwatch.exe')
        self.assertEqual(launched('--game-mode','1')['WINE_GAME_MODE'],'Overwatch.exe')
        off=launched('--game-mode','0','--metal-hud','1')
        self.assertNotIn('WINE_GAME_MODE',off)
        self.assertEqual((off['MTL_HUD_ENABLED'],off['WINEMAC_MOUSELOOK']),('1','Overwatch.exe'))
        # The mouse (REC-52, REC-57): Standard keeps the contract's input variant (1.5's); Classic
        # has the window driver keep 1.4's clicks and timing; High-precision has it read the mouse's
        # own reports. Anything else is Standard.
        self.assertEqual((hud['WINEMAC_INPUT_VARIANT'],'WINEMAC_RAW_SOURCE' in hud),('precise',False))
        self.assertEqual(launched('--mouse','standard')['WINEMAC_INPUT_VARIANT'],'precise')
        classic=launched('--mouse','classic')
        self.assertEqual((classic['WINEMAC_INPUT_VARIANT'],'WINEMAC_RAW_SOURCE' in classic),('classic',False))
        precise=launched('--mouse','high-precision')
        self.assertEqual((precise['WINEMAC_INPUT_VARIANT'],precise['WINEMAC_RAW_SOURCE']),('precise','hid'))
        other=launched('--mouse','legacy')
        self.assertEqual((other['WINEMAC_INPUT_VARIANT'],'WINEMAC_RAW_SOURCE' in other),('precise',False))
        # Mouse › Advanced (REC-63): Overwatch gets every report unless the player lowers it, then at
        # most that many a second (the driver's interval in microseconds). Classic keeps the driver's
        # own 1 ms, its 1.4 timing; a rate the app doesn't offer is every report.
        rate='WINEMAC_MOUSELOOK_RAW_INTERVAL_US'
        self.assertEqual((hud[rate],precise[rate],other[rate]),('0','0','0'))
        self.assertNotIn(rate,classic)
        for chosen,interval in [('all','0'),('2000','500'),('1000','1000'),('500','2000'),('250','4000'),('8000','0'),('','0')]:
            self.assertEqual(launched('--mouse-rate',chosen)[rate],interval,chosen)
        lowered=launched('--mouse','high-precision','--mouse-rate','500')
        self.assertEqual((lowered['WINEMAC_RAW_SOURCE'],lowered[rate]),('hid','2000'))
        self.assertNotIn(rate,launched('--mouse','classic','--mouse-rate','500'))
    def test_battlenet_keeps_windows_dpi_on_a_main_display_without_retina(self):
        # Without Retina mode (a main display that isn't Retina, portable_retina.h) a Windows
        # pixel is a point already: Battle.net at 192 DPI would come out twice its size.
        self.profile(b'[Render.13]\n')
        engine=self.root/'runtimes/v1'
        (engine/'config/dxmt.conf').write_text((setup.ROOT/'config/dxmt-source60-1200.conf').read_text())
        environment=self.root/'environment'
        (environment/'user.reg').write_text('[Software\\\\Wine\\\\Mac Driver]\n"RetinaMode"="N"\n')
        client=environment/'drive_c/Program Files (x86)/Battle.net/Battle.net.exe'
        client.parent.mkdir(parents=True);client.write_text('fixture')
        seen=self.base/'battlenet-environment'
        wine=engine/'bin/wine';wine.write_text(f'#!/bin/sh\ncase "$1" in *Battle.net.exe) env > "{seen}.part" && mv "{seen}.part" "{seen}";; esac\n');wine.chmod(0o755)
        self.addCleanup(subprocess.run,['pkill','-f',f'ow2-setup watch --root {self.root}'])
        os.environ['OW2_SETUP_TEST_DISPLAY_SCALE']='1'
        self.addCleanup(os.environ.__setitem__,'OW2_SETUP_TEST_DISPLAY_SCALE','2')
        self.assertEqual(self.call('launch')[-1]['stage'],'battlenet_open')
        for _ in range(100):
            if seen.exists():break
            time.sleep(0.05)
        launched=dict(line.split('=',1) for line in seen.read_text().splitlines() if '=' in line)
        self.assertNotIn('WINE_APP_DPI',launched)
        self.assertIn('"RetinaMode"="N"',(environment/'user.reg').read_text())
    def test_the_mouse_preset_writes_its_report_into_the_sessions_folder(self):
        # Logging's Mouse preset (REC-51) turns on the window driver's mouse report and no Wine
        # logging; the driver adds -<pid>.jsonl to the prefix, in the folder of this Battle.net start.
        self.profile(b'[Render.13]\n')
        engine=self.root/'runtimes/v1'
        (engine/'config/dxmt.conf').write_text((setup.ROOT/'config/dxmt-source60-1200.conf').read_text())
        environment=self.root/'environment'
        (environment/'user.reg').write_text('[Software\\\\Wine\\\\Mac Driver]\n"RetinaMode"="Y"\n')
        client=environment/'drive_c/Program Files (x86)/Battle.net/Battle.net.exe'
        client.parent.mkdir(parents=True);client.write_text('fixture')
        seen=self.base/'battlenet-environment'
        wine=engine/'bin/wine';wine.write_text(f'#!/bin/sh\ncase "$1" in *Battle.net.exe) env > "{seen}.part" && mv "{seen}.part" "{seen}";; esac\n');wine.chmod(0o755)
        self.addCleanup(subprocess.run,['pkill','-f',f'ow2-setup watch --root {self.root}'])
        def launched(*args):
            seen.unlink(missing_ok=True)
            events=self.call('launch',*args)
            self.assertEqual(events[-1]['stage'],'battlenet_open')
            for _ in range(100):
                if seen.exists():break
                time.sleep(0.05)
            return events[-1]['session'],dict(line.split('=',1) for line in seen.read_text().splitlines() if '=' in line)
        _,quiet=launched()
        self.assertNotIn('WINEMAC_INPUT_STATS',quiet)
        session,mouse=launched('--logging','mouse')
        report=lambda env:(str(setup.Path(env['WINEMAC_INPUT_STATS']).parent.resolve()),setup.Path(env['WINEMAC_INPUT_STATS']).name)
        self.assertEqual(report(mouse),(str((self.root/'logs/sessions'/session).resolve()),'input'))
        self.assertEqual(mouse.get('WINEDEBUG'),quiet.get('WINEDEBUG'))  # no Wine logging of its own
        record=setup.json.loads((self.root/'logs/sessions'/session/'session.json').read_text())
        self.assertEqual((record['logging'],record['mouse_input'],record['mouse_rate']),('mouse','standard','all'))
        session,_=launched('--logging','mouse','--mouse-rate','1000')
        record=setup.json.loads((self.root/'logs/sessions'/session/'session.json').read_text())
        self.assertEqual(record['mouse_rate'],'1000')
        session,both=launched('--logging','mouse,crashes','--mouse','classic','--mouse-rate','1000')
        self.assertEqual(report(both),(str((self.root/'logs/sessions'/session).resolve()),'input'))
        self.assertIn('+seh',both['WINEDEBUG'])
        record=setup.json.loads((self.root/'logs/sessions'/session/'session.json').read_text())
        self.assertEqual((record['logging'],record['mouse_input'],record['mouse_rate']),('crashes,mouse','classic','classic'))
    # Overwatch's own record of the graphics card, as on the owner's Mac (CRLF, with the
    # stray line feed an early seed left in [Render.13]).
    M1=b'[GPU.6]\r\nGPUIndex = "0"\r\nGPUName = "Apple M1 Pro"\r\nGPUScaler = "31.000000"\r\nGPUVenderID = "4203"\r\nLastUsedGPUVendorID = "4203"\r\n\r\n'
    def launchable(self,text):
        path=self.profile(text)
        engine=self.root/'runtimes/v1'
        (engine/'config/dxmt.conf').write_text((setup.ROOT/'config/dxmt-source60-1200.conf').read_text())
        environment=self.root/'environment'
        (environment/'user.reg').write_text('[Software\\\\Wine\\\\Mac Driver]\n"RetinaMode"="Y"\n')
        client=environment/'drive_c/Program Files (x86)/Battle.net/Battle.net.exe'
        client.parent.mkdir(parents=True);client.write_text('fixture')
        return path
    def launch(self):
        events=self.call('launch',success=False)  # the fixture runtime cannot start Wine
        return {e['stage']:e for e in events}
    def played(self,path,width,height,gpu=None):
        """The game saved a resolution (chosen in its Video settings) and maybe a new card."""
        text=path.read_bytes()
        text=re.sub(rb'FullScreenWidth = "\d+"',b'FullScreenWidth = "%d"'%width,text)
        text=re.sub(rb'FullScreenHeight = "\d+"',b'FullScreenHeight = "%d"'%height,text)
        if gpu is not None:
            if b'\r\n' not in text:gpu=gpu.replace(b'\r\n',b'\n')  # the game keeps the file's line endings
            text=re.sub(rb'\[GPU\.6\].*?(\r?\n){2}',gpu,text,flags=re.S) if b'[GPU.' in text else gpu+text
        path.write_bytes(text)
    def next(self):
        shown=self.call('status')[-1]['display_next']
        return {key:shown[key] for key in ('width','height','from_game')}
    def resolution(self,path):
        text=path.read_text()
        return tuple(int(re.search(key+r' = "(\d+)"',text).group(1)) for key in ('FullScreenWidth','FullScreenHeight'))
    def test_a_resolution_chosen_in_the_game_stays(self):
        # Recall wrote 1920x1080 at launch; the player then chose another size in
        # Overwatch's Video settings. The next launch keeps it, with the canvas to match.
        path=self.launchable(self.M1+b'[Render.13]\r\n\nDynamicRenderScale = "0"\r\n\r\nDynamicRenderScale = "0"\r\nFrameRateCap = "600"\r\n')
        self.call('display','--width','1920','--height','1080')
        self.launch()
        self.assertEqual(self.resolution(path),(1920,1080))
        for size in ((2560,1440),(2304,1440),(1920,1200)):  # Settings' sizes and the game's own
            self.played(path,*size)
            self.assertEqual(self.next(),{'width':size[0],'height':size[1],'from_game':True})
            events=self.launch()
            self.assertEqual((events['display_from_game']['width'],events['display_from_game']['height']),size)
            self.assertEqual(self.resolution(path),size)
            config=(self.root/'dxmt.conf').read_text()
            self.assertIn(f'dxgi.fullscreenCanvasWidth = {size[0]}\n',config)
            self.assertIn(f'dxgi.fullscreenCanvasHeight = {size[1]}\n',config)
            state=self.call('status')[-1]['state']
            self.assertEqual((state['display_width'],state['display_height']),size)
            self.assertEqual(self.next(),{'width':size[0],'height':size[1],'from_game':False})
        # Unchanged since that launch: nothing new to take.
        self.assertNotIn('display_from_game',self.launch())
        # Settings still sets it, from outside the game; the latest choice wins.
        self.call('display','--width','2560','--height','1600')
        self.assertEqual(self.resolution(path),(2560,1600))
        self.assertNotIn('display_from_game',self.launch())
        self.assertEqual(self.resolution(path),(2560,1600))
        # The rest of the display settings are Recall's as before (the refresh rate is the
        # display's: 120 Hz here, test_the_players_refresh_rate_stays).
        text=path.read_text()
        for line in ('WindowMode = "0"','FullscreenWindow = "0"','DynamicRenderScale = "0"','FullScreenRefresh = "120"','UseCustomWorldScale = "1"'):
            self.assertIn(line,text)
    def test_overwatch_resetting_its_display_settings_is_undone(self):
        # Overwatch resets its display settings for a graphics card it takes to be new
        # (2026-09-29: 1800x1125 at 60 Hz). That is not the player's choice.
        path=self.launchable(self.M1+b'[Render.13]\r\n')
        self.call('display','--width','1920','--height','1200')
        self.launch()
        nvidia=b'[GPU.6]\r\nGPUIndex = "0"\r\nGPUName = "NVIDIA GeForce RTX 4090"\r\nGPUVenderID = "4318"\r\nLastUsedGPUVendorID = "4318"\r\n\r\n'
        self.played(path,1800,1125,gpu=nvidia)
        self.assertEqual(self.next(),{'width':1920,'height':1200,'from_game':False})
        events=self.launch()
        self.assertNotIn('display_from_game',events)
        self.assertEqual((events['display_restored']['width'],events['display_restored']['height']),(1920,1200))
        self.assertEqual(self.resolution(path),(1920,1200))
        # The new card is now the one on record, so the player's next choice counts.
        self.played(path,2560,1600)
        self.assertIn('display_from_game',self.launch())
        self.assertEqual(self.resolution(path),(2560,1600))
    MODE_KEYS=('WindowMode','WindowedFullscreen','WindowedWidth','WindowedHeight','WindowedPosX','WindowedPosY')
    def mode(self,path):
        text=path.read_text()
        return dict(zip(self.MODE_KEYS,(re.search(r'\n'+key+r' = "([^"]*)"',text).group(1) for key in self.MODE_KEYS)))
    def chose_mode(self,path,**values):
        """The game saved a display mode (chosen in its Video settings)."""
        text=path.read_bytes()
        for key,value in values.items():
            text=re.sub(rb'\n'+key.encode()+rb' = "[^"]*"',b'\n'+key.encode()+b' = "'+value.encode()+b'"',text)
        path.write_bytes(text)
    def test_the_players_display_mode_stays(self):
        # REC-45: until 1.6 every launch put Overwatch back in Fullscreen, so Windowed or
        # Borderless lasted one session.
        path=self.launchable(self.M1+b'[Render.13]\r\n')
        self.call('display','--width','1920','--height','1080')
        self.launch()
        self.assertEqual(self.mode(path)['WindowMode'],'0')
        # Windowed, chosen in the game, with the window's size and place it saved.
        windowed={'WindowMode':'2','WindowedFullscreen':'0','WindowedWidth':'1920','WindowedHeight':'1016',
                  'WindowedPosX':'100','WindowedPosY':'164'}
        self.chose_mode(path,**windowed)
        for _ in range(2):  # and again: Recall's own record must not undo it
            self.assertEqual(self.launch()['display_saved']['mode'],'windowed')
            self.assertEqual(self.mode(path),windowed)
        # A resolution chosen in Settings is the window's size; the mode and place stay.
        self.call('display','--width','2560','--height','1440')
        self.assertEqual(self.mode(path),dict(windowed,WindowedWidth='2560',WindowedHeight='1440'))
        # Borderless, chosen in the game (as Overwatch saved it on 2026-10-22).
        self.chose_mode(path,WindowMode='1',WindowedFullscreen='1')
        self.assertEqual(self.launch()['display_saved']['mode'],'borderless')
        self.assertEqual((self.mode(path)['WindowMode'],self.mode(path)['WindowedFullscreen']),('1','1'))
        # Overwatch resetting its display settings for a card it takes to be new is undone,
        # the display mode included.
        nvidia=b'[GPU.6]\r\nGPUIndex = "0"\r\nGPUName = "NVIDIA GeForce RTX 4090"\r\nGPUVenderID = "4318"\r\nLastUsedGPUVendorID = "4318"\r\n\r\n'
        self.played(path,1800,1125,gpu=nvidia)
        self.chose_mode(path,WindowMode='2',WindowedFullscreen='0')
        self.assertIn('display_restored',self.launch())
        self.assertEqual((self.mode(path)['WindowMode'],self.mode(path)['WindowedFullscreen']),('1','1'))
        # Reset Display Settings: Fullscreen, at the resolution it sets.
        self.call('display','--width','1920','--height','1080','--reset','1')
        self.assertEqual({k:self.mode(path)[k] for k in ('WindowMode','WindowedFullscreen','WindowedWidth','WindowedHeight')},
                         {'WindowMode':'0','WindowedFullscreen':'0','WindowedWidth':'1920','WindowedHeight':'1080'})
        # A window larger than the main display as Wine sees it takes the resolution.
        self.chose_mode(path,WindowMode='2',WindowedWidth='16000',WindowedHeight='9000')
        self.launch()
        self.assertEqual((self.mode(path)['WindowMode'],self.mode(path)['WindowedWidth'],self.mode(path)['WindowedHeight']),('2','1920','1080'))
    def refresh(self,path):
        text=path.read_text()
        return tuple(re.search(key+r' = "(\d+)"',text).group(1) for key in ('FullScreenRefresh','WindowedRefresh'))
    def test_the_players_refresh_rate_stays(self):
        # REC-56: until 1.6 every launch wrote FullScreenRefresh 120, so a 144 Hz monitor went
        # back to 120 Hz each session. A new installation starts at the main display's rate.
        os.environ['OW2_SETUP_TEST_DISPLAY_REFRESH']='144'
        self.addCleanup(os.environ.__setitem__,'OW2_SETUP_TEST_DISPLAY_REFRESH','120')
        path=self.launchable(self.M1+b'[Render.13]\r\n')
        self.call('display','--width','1920','--height','1080')
        self.launch()
        self.assertEqual(self.refresh(path),('144','144'))
        # Chosen in the game, kept launch after launch, 120 included.
        for rate in ('60','120','120'):
            text=path.read_text().replace(f'FullScreenRefresh = "{self.refresh(path)[0]}"',f'FullScreenRefresh = "{rate}"')
            path.write_text(text);self.launch()
            self.assertEqual(self.refresh(path)[0],rate)
        # A resolution chosen in Settings keeps it too.
        self.call('display','--width','2560','--height','1440')
        self.assertEqual(self.refresh(path)[0],'120')
        # Overwatch resetting its display settings for a card it takes to be new is undone.
        nvidia=b'[GPU.6]\r\nGPUIndex = "0"\r\nGPUName = "NVIDIA GeForce RTX 4090"\r\nGPUVenderID = "4318"\r\nLastUsedGPUVendorID = "4318"\r\n\r\n'
        self.played(path,1800,1125,gpu=nvidia)
        path.write_text(path.read_text().replace('FullScreenRefresh = "120"','FullScreenRefresh = "60"'))
        self.assertIn('display_restored',self.launch())
        self.assertEqual(self.refresh(path)[0],'120')
        # Reset Display Settings: the display's own rate.
        self.call('display','--width','1920','--height','1080','--reset','1')
        self.assertEqual(self.refresh(path)[0],'144')
        # Nothing usable in the game's settings: the display's rate.
        path.write_text(path.read_text().replace('FullScreenRefresh = "144"','FullScreenRefresh = "fast"'))
        self.launch()
        self.assertEqual(self.refresh(path)[0],'144')
    def test_an_update_replaces_the_120_hz_recall_wrote_before_1_6(self):
        # Recall 1.5 and the 1.6 test builds wrote 120 with no record of it, so 120 there is
        # Recall's, not the player's; once recorded, a 120 chosen later stays.
        path=self.launchable(self.M1+b'[Render.13]\r\n')
        self.call('display','--width','1920','--height','1080')
        self.launch()
        before_1_6={'game_refresh':None,'display_refresh':None}
        self.saved(**before_1_6)
        os.environ['OW2_SETUP_TEST_DISPLAY_REFRESH']='144'
        self.addCleanup(os.environ.__setitem__,'OW2_SETUP_TEST_DISPLAY_REFRESH','120')
        self.launch()
        self.assertEqual(self.refresh(path)[0],'144')
        path.write_text(path.read_text().replace('FullScreenRefresh = "144"','FullScreenRefresh = "120"'))
        self.launch()
        self.assertEqual(self.refresh(path)[0],'120')
        # Another rate in the game under the old record was the player's.
        self.saved(**before_1_6)
        path.write_text(path.read_text().replace('FullScreenRefresh = "120"','FullScreenRefresh = "100"'))
        self.launch()
        self.assertEqual(self.refresh(path)[0],'100')
    def test_each_display_keeps_its_own_refresh_rate(self):
        # A 144 Hz monitor and a MacBook's 120 Hz screen: moving between them needs no trip to
        # Overwatch's Video settings. The test Mac has one main display ("lg" here, 144 Hz); the
        # other ("macbook") is played on through Recall's records, as for the resolution.
        os.environ['OW2_SETUP_TEST_DISPLAY_REFRESH']='144'
        self.addCleanup(os.environ.__setitem__,'OW2_SETUP_TEST_DISPLAY_REFRESH','120')
        path=self.launchable(self.M1+b'[Render.13]\r\n')
        screen=self.screen()
        self.call('display','--width','1920','--height','1080')
        self.launch()
        self.assertEqual(self.refresh(path)[0],'144')
        # The last game opened on the MacBook, where Recall wrote 120 and the player then chose
        # 100. Back here: this display's 144, and the MacBook keeps its 100.
        self.saved(game_display_screen='macbook',game_refresh='120')
        path.write_text(path.read_text().replace('FullScreenRefresh = "144"','FullScreenRefresh = "100"'))
        self.launch()
        self.assertEqual(self.refresh(path)[0],'144')
        state=json.loads((self.root/'state.json').read_text())
        self.assertEqual(state['display_refresh'],{'macbook':'100'})
        self.assertEqual((state['game_display_screen'],state['game_refresh']),(screen,'144'))
        # A choice in the game here stays with this display only, launch after launch.
        path.write_text(path.read_text().replace('FullScreenRefresh = "144"','FullScreenRefresh = "120"'))
        for _ in range(2):
            self.launch()
            self.assertEqual(self.refresh(path)[0],'120')
        self.assertEqual(json.loads((self.root/'state.json').read_text())['display_refresh'],{'macbook':'100',screen:'120'})
        # A display with no choice gets its own rate; Reset Display Settings forgets this one's.
        self.saved(display_refresh={'macbook':'100'})
        self.launch()
        self.assertEqual(self.refresh(path)[0],'144')
        self.saved(display_refresh={'macbook':'100',screen:'120'})
        self.call('display','--width','1920','--height','1080','--reset','1')
        self.assertEqual(self.refresh(path)[0],'144')
        self.assertEqual(json.loads((self.root/'state.json').read_text())['display_refresh'],{'macbook':'100'})
        # Display memory off concerns the resolution: refresh rates stay each display's.
        self.call('display-memory','--enabled','0')
        self.saved(game_display_screen='macbook',game_refresh='100')
        path.write_text(path.read_text().replace('FullScreenRefresh = "144"','FullScreenRefresh = "100"'))
        self.launch()
        self.assertEqual(self.refresh(path)[0],'144')
    def test_a_first_game_and_an_update_from_1_0_keep_the_choice(self):
        # A new installation: Recall seeds the game's settings before Overwatch first
        # runs, and Overwatch records the card (and may pick its own size) on that start.
        path=self.launchable(b'[Render.13]\n')
        self.call('display','--width','1920','--height','1200')
        self.launch()
        self.played(path,3024,1964,gpu=self.M1)
        self.assertIn('display_restored',self.launch())
        self.assertEqual(self.resolution(path),(1920,1200))
        self.played(path,2560,1600)
        self.assertIn('display_from_game',self.launch())
        self.assertEqual(self.resolution(path),(2560,1600))
        # 1.0 kept no record of what it wrote: its last choice stands once.
        state=self.root/'state.json';saved=setup.json.loads(state.read_text())
        for key in ('game_display_width','game_display_height','game_gpu'):del saved[key]
        state.write_text(setup.json.dumps(saved))
        self.played(path,1920,1080)
        events=self.launch()
        self.assertFalse({'display_from_game','display_restored'}&set(events))
        self.assertEqual(self.resolution(path),(2560,1600))
        self.played(path,1920,1080)
        self.assertIn('display_from_game',self.launch())
    def test_a_choice_larger_than_this_display_comes_back_on_a_larger_one(self):
        # A size from the game that no main display here can hold is lowered for the
        # launch; the game's settings then hold the lowered size, which was Recall's
        # doing, so the choice is kept for the next launch.
        path=self.launchable(self.M1+b'[Render.13]\r\n')
        self.call('display','--width','1920','--height','1200')
        self.launch()
        self.played(path,16000,6750)
        events=self.launch()
        fitted=(events['display_fitted']['width'],events['display_fitted']['height'])
        self.assertEqual((events['display_fitted']['chosen_width'],events['display_fitted']['chosen_height']),(16000,6750))
        self.assertEqual(self.resolution(path),fitted)
        self.assertIn(f'dxgi.fullscreenCanvasWidth = {fitted[0]}\n',(self.root/'dxmt.conf').read_text())
        events=self.launch()
        self.assertNotIn('display_from_game',events)
        self.assertEqual((events['display_fitted']['chosen_width'],events['display_fitted']['chosen_height']),(16000,6750))
        # Sizes the canvas cannot show are not taken from the game.
        for width,height in ((17000,7000),(600,400)):
            self.played(path,width,height)
            self.assertNotIn('display_from_game',self.launch())
            self.assertEqual(self.resolution(path),fitted)
    def saved(self,**changes):
        state=self.root/'state.json';values=json.loads(state.read_text())
        for key,value in changes.items():
            if value is None:values.pop(key,None)
            else:values[key]=value
        state.write_text(json.dumps(values))
        return values
    def screen(self):
        screen=self.call('status')[-1]['display_next'].get('screen')
        if not screen:self.skipTest('this environment has no main display')
        return screen
    def test_each_display_keeps_its_own_resolution(self):
        # Display memory, on by default: the built-in screen and each monitor keep the
        # resolution last chosen on them. The test Mac has one main display; the other
        # display ("macbook") is played on through Recall's records.
        path=self.launchable(self.M1+b'[Render.13]\r\n')
        screen=self.screen()
        self.assertTrue(self.call('status')[-1]['display_next']['per_display'])
        self.call('display','--width','2560','--height','1440')
        self.launch()
        self.assertEqual(json.loads((self.root/'state.json').read_text())['displays'],{screen:[2560,1440]})
        # The last game opened on the MacBook at 1920x1200, where the player then chose
        # 1680x1050 in Overwatch. Back on this display: its own resolution, and the
        # MacBook keeps the one chosen there.
        self.saved(displays={screen:[2560,1440],'macbook':[1920,1200]},game_display_screen='macbook',game_display_width=1920,game_display_height=1200)
        self.played(path,1680,1050)
        self.assertEqual(self.next(),{'width':2560,'height':1440,'from_game':False})
        events=self.launch()
        self.assertNotIn('display_from_game',events)
        self.assertEqual(self.resolution(path),(2560,1440))
        self.assertIn('dxgi.fullscreenCanvasWidth = 2560\n',(self.root/'dxmt.conf').read_text())
        state=json.loads((self.root/'state.json').read_text())
        self.assertEqual(state['displays'],{screen:[2560,1440],'macbook':[1680,1050]})
        self.assertEqual(state['game_display_screen'],screen)
        # A change in the game here stays with this display only.
        self.played(path,1920,1080)
        self.assertIn('display_from_game',self.launch())
        self.assertEqual(json.loads((self.root/'state.json').read_text())['displays'],{screen:[1920,1080],'macbook':[1680,1050]})
        # So does a choice in Settings, and Troubleshooting's reset (the same command).
        self.call('display','--width','3840','--height','2160')
        self.assertEqual(json.loads((self.root/'state.json').read_text())['displays'],{screen:[3840,2160],'macbook':[1680,1050]})
        # A display Recall hasn't seen starts at 1080p in its shape.
        self.saved(displays={'macbook':[1680,1050]})
        first=self.next()
        self.assertIn((first['width'],first['height']),((1920,1080),(1920,1200)))
        self.launch()
        self.assertEqual(self.resolution(path),(first['width'],first['height']))
        self.assertEqual(json.loads((self.root/'state.json').read_text())['displays'],{screen:[first['width'],first['height']],'macbook':[1680,1050]})
    def test_display_memory_off_uses_one_resolution_everywhere(self):
        path=self.launchable(self.M1+b'[Render.13]\r\n')
        screen=self.screen()
        self.call('display','--width','2560','--height','1440')
        self.launch()
        self.saved(displays={screen:[2560,1440],'macbook':[1920,1200]},display_width=1920,display_height=1200)
        self.assertEqual(self.call('display-memory','--enabled','0')[-1],{'stage':'display_memory','enabled':False})
        shown=self.call('status')[-1]['display_next']
        self.assertEqual((shown['width'],shown['height'],shown['per_display']),(1920,1200,False))
        self.launch()
        self.assertEqual(self.resolution(path),(1920,1200))
        self.played(path,2560,1600)
        self.assertIn('display_from_game',self.launch())
        state=json.loads((self.root/'state.json').read_text())
        self.assertEqual((state['display_width'],state['display_height']),(2560,1600))
        self.assertEqual(state['displays'],{screen:[2560,1440],'macbook':[1920,1200]})  # left as they were
        # On again: each display's own resolution comes back.
        self.call('display-memory','--enabled','1')
        self.assertEqual(self.next(),{'width':2560,'height':1440,'from_game':False})
        for value in ('2','on',''):
            self.assertEqual(self.call('display-memory','--enabled',value,success=False)[-1]['code'],'invalid_arguments')
    def test_earlier_choices_belong_to_the_display_of_the_next_launch(self):
        # 1.0 and the first 1.1 builds kept one resolution: it stays with the main
        # display of the first launch. An installation that never saved one starts in
        # the main display's shape.
        path=self.launchable(self.M1+b'[Render.13]\r\n')
        screen=self.screen()
        self.call('display','--width','2560','--height','1600')
        self.saved(displays=None,game_display_screen=None)
        self.launch()
        self.assertEqual(self.resolution(path),(2560,1600))
        self.assertEqual(json.loads((self.root/'state.json').read_text())['displays'],{screen:[2560,1600]})
        self.saved(displays=None,game_display_screen=None,display_width=None,display_height=None,game_display_width=None,game_display_height=None,game_gpu=None)
        first=self.next()
        self.assertIn((first['width'],first['height']),((1920,1080),(1920,1200)))
        self.launch()
        self.assertEqual(self.resolution(path),(first['width'],first['height']))
    def test_restoring_the_baseline_keeps_the_game_resolution(self):
        path=self.launchable(self.M1+b'[Render.13]\r\nFrameRateCap = "237"\r\n')
        self.call('display','--width','1920','--height','1080')
        self.launch()
        self.played(path,2560,1440)
        self.call('restore-candidate')
        self.assertEqual(self.resolution(path),(2560,1440))
        self.assertIn('FrameRateCap = "600"',path.read_text())
    def test_duplicate_render_section_is_preserved(self):
        before=b'[Render.13]\n[Render.13]\n'
        path=self.profile(before)
        self.assertEqual(self.call('display','--height','1080',success=False)[-1]['code'],'invalid_game_settings')
        self.assertEqual(path.read_bytes(),before)
    def test_preferences_cannot_escape_into_personal_documents(self):
        path=self.profile(b'[Render.13]\n');path.unlink()
        external=self.base/'personal.ini';external.write_text('[Render.13]\n')
        path.symlink_to(external)
        self.assertEqual(self.call('display','--height','1080',success=False)[-1]['code'],'settings_outside_installation')
        self.assertEqual(external.read_text(),'[Render.13]\n')

if __name__=='__main__':unittest.main()
