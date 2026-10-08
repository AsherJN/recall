"""Real native display edits preserve unrelated game preferences and ownership."""
import json
import re
import subprocess
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
        # shader cache; the pipeline helper warms it. Without the app or Game Mode the
        # helper gets the installation only.
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
        self.assertFalse([key for key in launched('--metal-hud','0') if key.startswith('MTL_HUD')])
        # Game Mode is on unless the app's hidden default turns it off, and the HUD does not change it.
        self.assertEqual(hud['WINE_GAME_MODE'],'Overwatch.exe')
        self.assertEqual(launched('--game-mode','1')['WINE_GAME_MODE'],'Overwatch.exe')
        off=launched('--game-mode','0','--metal-hud','1')
        self.assertNotIn('WINE_GAME_MODE',off)
        self.assertEqual((off['MTL_HUD_ENABLED'],off['WINEMAC_MOUSELOOK']),('1','Overwatch.exe'))
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
        # The rest of the display settings are Recall's as before.
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
