"""Custom renderer settings (REC-85, Settings › Advanced): the list of settings the app checks the
player's lines against, and what the real setup worker writes into dxmt.conf with them, at a launch
that opens Battle.net and at one handed to a Battle.net already open. A fixture engine, Wine and
Battle.net stand in; no Wine or game runs."""
import os
import subprocess
import time
import unittest
from unittest import mock

import test_portable_metalfx as metalfx
import test_portable_setup as setup

MARKER = '# Custom renderer settings (Settings › Advanced)'


class EngineSettings(unittest.TestCase):
    @unittest.skipUnless((setup.ROOT/'runtime/source/dxmt-ow2/.git').exists(), 'needs the DXMT checkout')
    def test_the_apps_list_is_the_engines(self):
        # The app's list is generated from DXMT at its pinned commit with the build's patches; a new
        # patch that reads another setting makes it stale.
        run = subprocess.run(['python3', str(setup.ROOT/'scripts/renderer_settings.py'), '--check'], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stdout+run.stderr)
        text = (setup.ROOT/'app/Sources/RendererEngineSettings.swift').read_text()
        # The ones Recall's own profile and launch set are all there, with the frame rate cap players ask for.
        for name in ('dxgi.fullscreenCanvasWidth', 'd3d11.metalfxSharpness', 'dxgi.presentPacingMode', 'd3d11.releaseShaderIR'):
            self.assertIn(f'"{name}":', text)
        self.assertIn('"d3d11.preferredMaxFrameRate":.int,', text)


class Worker(unittest.TestCase):
    setUpClass = classmethod(setup.NativeSetup.setUpClass.__func__)
    tearDownClass = classmethod(setup.NativeSetup.tearDownClass.__func__)
    setUp = setup.NativeSetup.setUp
    call = setup.NativeSetup.call
    archive = setup.NativeSetup.archive
    install = setup.NativeSetup.install
    M1 = metalfx.MetalFX.M1
    profile = metalfx.MetalFX.profile
    launchable = metalfx.MetalFX.launchable
    playable = metalfx.MetalFX.playable
    play = metalfx.MetalFX.play

    def config(self):
        return (self.root/'dxmt.conf').read_text()

    def test_a_launch_adds_the_players_lines_after_recalls(self):
        self.playable(self.M1+b'[Render.13]\r\n')
        self.call('display', '--width', '2560', '--height', '1440')
        lines = ('d3d11.preferredMaxFrameRate=45\n'
                 '  dxgi.maxFrameLatency   =  2  \r\n'
                 '# a note\n\n'
                 'dxgi.fullscreenCanvasWidth = 800\n'     # Recall's: the resolution
                 'd3d11.metalfxSharpness = 1\n'           # Recall's: Sharpening
                 '[Battle.net.exe]\n'                     # would move what follows out of Overwatch's section
                 'not a setting\n'
                 'dxgi.maxframerate = 60\n')              # kept: the app flags it, DXMT ignores it
        _, events = self.play('--renderer-custom', lines)
        self.assertEqual(events['renderer_custom'], {'stage': 'renderer_custom', 'lines': 3, 'ignored': 4})
        recalls, custom = self.config().split('\n'+MARKER+'\n')
        self.assertIn('dxgi.fullscreenCanvasWidth = 2560\n', recalls)
        self.assertEqual(custom, '[Overwatch.exe]\nd3d11.preferredMaxFrameRate = 45\ndxgi.maxFrameLatency = 2\ndxgi.maxframerate = 60\n')

        # Off (the app sends nothing): Recall's profile alone, as before 1.6.4.
        _, events = self.play()
        self.assertNotIn('renderer_custom', events)
        self.assertNotIn(MARKER, self.config())
        self.assertIn('dxgi.fullscreenCanvasWidth = 2560\n', self.config())

        # Only lines the worker leaves out: nothing is added.
        _, events = self.play('--renderer-custom', 'dxgi.fullscreenCanvasHeight = 1\n[x]')
        self.assertEqual((events['renderer_custom']['lines'], events['renderer_custom']['ignored']), (0, 2))
        self.assertNotIn(MARKER, self.config())

    def test_with_sharpening_the_players_lines_come_last(self):
        self.playable(self.M1+b'[Render.13]\r\n')
        metalfx.MetalFX.engine(self)
        self.play('--metalfx', '1', '--sharpening', 'low', '--renderer-custom', 'dxgi.presentPacing = False')
        config = self.config()
        self.assertLess(config.index('d3d11.metalfxSharpness = 0.4'), config.index(MARKER))
        self.assertTrue(config.endswith(MARKER+'\n[Overwatch.exe]\ndxgi.presentPacing = False\n'))

    def battlenet_open(self):
        """A process the worker takes for this installation's Battle.net: named Battle.net.exe in the
        Windows environment, with a library from the engine loaded, as Wine's processes have."""
        client = self.root/'environment/drive_c/Program Files (x86)/Battle.net/Battle.net.exe'
        library = self.root/'runtimes/v1/lib/fixture.dylib'
        source = self.base/'fixture.c'
        source.write_text('int fixture(void) { return 0; }\n')
        subprocess.run(['/usr/bin/clang', '-dynamiclib', str(source), '-o', str(library)], check=True)
        source.write_text('#include <dlfcn.h>\n#include <unistd.h>\n'
                          'int main(int argc, char **argv) { if (!dlopen(argv[1], RTLD_NOW)) return 1; for (;;) pause(); }\n')
        subprocess.run(['/usr/bin/clang', str(source), '-o', str(client)], check=True)
        process = subprocess.Popen([str(client), str(library)])
        self.addCleanup(process.wait)
        self.addCleanup(process.kill)
        for _ in range(100):
            if 'session_existing' in str(self.call('launch', '--play', '0')):
                return
            time.sleep(0.05)
        self.fail('the stand-in Battle.net was not taken for this installation\'s')

    def test_a_hand_over_to_an_open_battlenet_rewrites_the_players_lines(self):
        # The Overwatch a hand-over starts reads dxmt.conf when it starts, so the lines are the ones
        # the player has now; Recall's own part is the one the session started with.
        self.playable(self.M1+b'[Render.13]\r\n')
        self.call('display', '--width', '2560', '--height', '1440')
        self.play('--renderer-custom', 'dxgi.maxFrameLatency = 2')
        recalls = self.config().split(MARKER)[0]
        self.battlenet_open()

        events = {e['stage']: e for e in self.call('launch', '--play', '1', '--renderer-custom', 'd3d11.preferredMaxFrameRate = 45')}
        self.assertEqual(events['session_existing']['kind'], 'client')
        self.assertEqual(events['renderer_custom']['lines'], 1)
        self.assertEqual(self.config(), recalls+MARKER+'\n[Overwatch.exe]\nd3d11.preferredMaxFrameRate = 45\n')

        # Turned off: Recall's part alone, without touching its canvas.
        self.call('launch', '--play', '1')
        self.assertEqual(self.config(), recalls)

    # Display sync on a Mac with an iPhone chip (REC-93): macOS 26.6.2's WindowServer crashes on the
    # MacBook Neo while a game is shown with vsync off, so Recall's part of dxmt.conf turns display
    # sync on there, once, ahead of the player's lines; other Macs keep the engine's vsync off.
    NEO = 'Apple A18 Pro'
    SYNC = '[Overwatch.exe]\ndxgi.displaySyncEnabled = True'

    def chip(self, name):
        """Stands NAME in for this Mac's chip for the rest of the test."""
        patcher = mock.patch.dict(os.environ, {'OW2_SETUP_TEST_CHIP': name})
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_a_macbook_neo_launch_turns_display_sync_on_and_a_players_line_still_wins(self):
        self.chip(self.NEO)
        self.playable(self.M1+b'[Render.13]\r\n')
        _, events = self.play()
        self.assertEqual(events['display_sync'], {'stage': 'display_sync', 'enabled': True, 'chip': self.NEO})
        self.assertTrue(self.config().endswith(self.SYNC+'\n'), self.config())
        self.assertEqual(self.config().count('dxgi.displaySyncEnabled'), 1)

        # The player's own line comes after Recall's, and DXMT keeps the last one it reads.
        self.play('--renderer-custom', 'dxgi.displaySyncEnabled = False\nd3d11.preferredMaxFrameRate = 45')
        recalls, custom = self.config().split('\n'+MARKER+'\n')
        self.assertTrue(recalls.endswith(self.SYNC), recalls)
        self.assertEqual(custom, '[Overwatch.exe]\ndxgi.displaySyncEnabled = False\nd3d11.preferredMaxFrameRate = 45\n')

    def test_with_sharpening_on_a_macbook_neo_display_sync_comes_before_the_players_lines(self):
        self.chip(self.NEO)
        self.playable(self.M1+b'[Render.13]\r\n')
        metalfx.MetalFX.engine(self)
        self.play('--metalfx', '1', '--sharpening', 'low', '--renderer-custom', 'dxgi.presentPacing = False')
        config = self.config()
        self.assertLess(config.index('d3d11.metalfxSharpness = 0.4'), config.index(self.SYNC))
        self.assertLess(config.index(self.SYNC), config.index(MARKER))
        self.assertTrue(config.endswith(MARKER+'\n[Overwatch.exe]\ndxgi.presentPacing = False\n'))

    def test_other_macs_keep_vsync_off(self):
        self.playable(self.M1+b'[Render.13]\r\n')
        for chip in ('Apple M1 Pro', 'Apple M4 Max'):
            with self.subTest(chip=chip):
                self.chip(chip)
                _, events = self.play('--renderer-custom', 'dxgi.maxFrameLatency = 2')
                self.assertNotIn('display_sync', events)
                self.assertNotIn('dxgi.displaySyncEnabled', self.config())

    def test_a_hand_over_on_a_macbook_neo_keeps_one_display_sync_line(self):
        self.chip(self.NEO)
        self.playable(self.M1+b'[Render.13]\r\n')
        self.call('display', '--width', '2560', '--height', '1440')
        self.play()
        self.battlenet_open()
        # A Battle.net an earlier Recall opened read a dxmt.conf without the line; the Overwatch a
        # hand-over starts gets it, and every later hand-over keeps it to one.
        (self.root/'dxmt.conf').write_text(self.config().replace(self.SYNC+'\n', ''))
        events = {e['stage']: e for e in self.call('launch', '--play', '1', '--renderer-custom', 'dxgi.maxFrameLatency = 2')}
        self.assertEqual(events['session_existing']['kind'], 'client')
        self.assertEqual(events['display_sync']['chip'], self.NEO)
        config = self.config()
        self.assertEqual(config.count(self.SYNC), 1)
        self.assertLess(config.index(self.SYNC), config.index(MARKER))
        self.assertIn('dxgi.fullscreenCanvasWidth = 2560\n', config)

        self.call('launch', '--play', '1')
        self.assertEqual(self.config().count(self.SYNC), 1)
        self.assertNotIn(MARKER, self.config())


if __name__ == '__main__':
    unittest.main()
