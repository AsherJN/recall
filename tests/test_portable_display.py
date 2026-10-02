"""Real native display edits preserve unrelated game preferences and ownership."""
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
