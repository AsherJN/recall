"""MetalFX upscaling through the real setup worker: what a launch sets up with it on and undoes
with it off. A fixture engine and Wine stand in; no Wine or game runs."""
import hashlib
import json
import re
import subprocess
import time
import unittest

import test_portable_display as display
import test_portable_setup as setup

STAND_IN = b'MZ fixture: the engine\'s signed DLSS stand-in'
PLACEHOLDER = b'MZ fixture: Wine placeholder DLL'
CONTRACT = json.loads((setup.ROOT/'docs/candidate-parity-contract.json').read_text())
NVIDIA = {'GPUName': 'NVIDIA GeForce RTX 4090', 'GPUVenderID': '4318', 'LastUsedGPUVendorID': '4318',
          'GPUDeviceID': '9860', 'LastUsedGPUDeviceID': '9860'}


def mac_gpu():
    """The Mac's GPU as Metal (and so DXMT) names it."""
    shown = json.loads(subprocess.run(['/usr/sbin/system_profiler', '-json', 'SPDisplaysDataType'],
                                      capture_output=True, text=True, check=True).stdout)
    return shown['SPDisplaysDataType'][0]['sppci_model']


def section(text, name):
    body = text.replace('\r\n', '\n').split(name + '\n', 1)[1].split('\n[', 1)[0]
    return dict(re.findall(r'^(\w+) = "([^"]*)"$', body, re.M))


class MetalFX(unittest.TestCase):
    setUpClass = classmethod(setup.NativeSetup.setUpClass.__func__)
    tearDownClass = classmethod(setup.NativeSetup.tearDownClass.__func__)
    setUp = setup.NativeSetup.setUp
    call = setup.NativeSetup.call
    archive = setup.NativeSetup.archive
    install = setup.NativeSetup.install
    M1 = display.DisplaySetup.M1
    profile = display.DisplaySetup.profile
    launchable = display.DisplaySetup.launchable
    played = display.DisplaySetup.played
    resolution = display.DisplaySetup.resolution

    def engine(self, stand_ins=True):
        """The fixture engine with the 1.3 stand-ins in its manifest, and Wine's placeholder in system32."""
        engine = self.root/'runtimes/v1'
        windows = engine/'lib/wine/x86_64-windows'
        manifest = json.loads((engine/'runtime.json').read_text())
        if stand_ins:
            for name, content in (('nvngx.dll', STAND_IN), ('nvapi64.dll', b'MZ fixture: NVAPI stand-in')):
                (windows/name).write_bytes(content)
                manifest['files']['lib/wine/x86_64-windows/'+name] = {'sha256': hashlib.sha256(content).hexdigest()}
        (engine/'runtime.json').write_text(json.dumps(manifest))
        system32 = self.root/'environment/drive_c/windows/system32'
        system32.mkdir(parents=True)
        (system32/'nvngx.dll').write_bytes(PLACEHOLDER)
        return system32/'nvngx.dll'

    def playable(self, settings):
        path = self.launchable(settings)
        seen = self.base/'battlenet-environment'
        wine = self.root/'runtimes/v1/bin/wine'
        # Launches also run Wine's registry tool (proxy, microphone); only Battle.net's start counts.
        wine.write_text(f'#!/bin/sh\ncase "$1" in *Battle.net.exe) env > "{seen}.part" && mv "{seen}.part" "{seen}";; esac\n')
        wine.chmod(0o755)
        self.addCleanup(subprocess.run, ['pkill', '-f', f'ow2-setup watch --root {self.root}'])
        return path

    def play(self, *args):
        """Launches as the app does; returns Battle.net's environment and the worker's events."""
        seen = self.base/'battlenet-environment'
        seen.unlink(missing_ok=True)
        events = self.call('launch', *args)
        self.assertEqual(events[-1]['stage'], 'battlenet_open')
        for _ in range(100):
            if seen.exists():
                break
            time.sleep(0.05)
        env = dict(line.split('=', 1) for line in seen.read_text().splitlines() if '=' in line)
        return env, {e['stage']: e for e in events}

    def test_upscaling_on_then_off(self):
        played = (b'[Render.13]\r\nFullScreenWidth = "1920"\r\nFullScreenHeight = "1200"\r\n'
                  b'HighQualityUpsample = "3"\r\nGFXPresetLevel = "3"\r\n[Input.1]\r\nSensitivity = "9.5"\r\n')
        path = self.playable(self.M1 + played)
        system32 = self.engine()
        self.call('display', '--width', '1920', '--height', '1200')

        env, events = self.play('--metalfx', '1', '--sharpening', 'low')
        self.assertEqual(env['DXMT_ENABLE_NVEXT'], '1')
        self.assertEqual(env['WINEDLLOVERRIDES'], CONTRACT['metalfx_environment']['WINEDLLOVERRIDES'])
        self.assertEqual(env['WINEMAC_MOUSELOOK'], 'Overwatch.exe')  # the rest of the contract stays
        self.assertEqual(events['metalfx'], {'stage': 'metalfx', 'enabled': True, 'available': True, 'nvngx': 'installed',
                                             'settings': sorted(NVIDIA), 'sharpness': '0.4'})
        # NVIDIA's loader finds the signed stand-in; Wine's placeholder is kept for later.
        self.assertEqual(system32.read_bytes(), STAND_IN)
        self.assertEqual((self.root/'metalfx/nvngx.dll').read_bytes(), PLACEHOLDER)
        # The game's record names the card it is about to see, so it keeps the player's settings.
        text = path.read_text()
        self.assertEqual(section(text, '[GPU.6]'), {'GPUIndex': '0', 'GPUScaler': '31.000000', **NVIDIA})
        self.assertEqual(section(text, '[Render.13]')['GFXPresetLevel'], '3')
        self.assertIn('Sensitivity = "9.5"', text)
        self.assertNotIn(b'\n', path.read_bytes().replace(b'\r\n', b''))
        self.assertIn(b'GPUName = "Apple M1 Pro"', (self.root/'settings-backup/before-graphics-card.ini').read_bytes())
        self.assertTrue((self.root/'dxmt.conf').read_text().endswith('\n[Overwatch.exe]\nd3d11.metalfxSharpness = 0.4\n'))
        self.assertEqual(self.call('status')[-1]['state']['game_gpu'], 'NVIDIA GeForce RTX 4090|4318')

        # The same again: nothing left to change.
        env, events = self.play('--metalfx', '1', '--sharpening', 'low')
        self.assertEqual((events['metalfx']['nvngx'], events['metalfx']['settings']), ('kept', []))

        env, events = self.play('--metalfx', '0')
        self.assertNotIn('DXMT_ENABLE_NVEXT', env)
        self.assertEqual(env['WINEDLLOVERRIDES'], 'd3d11,dxgi,d3d10core,winemetal=b;d3d12,nvapi64,nvngx=')
        self.assertEqual(events['metalfx']['nvngx'], 'restored')
        self.assertEqual(system32.read_bytes(), PLACEHOLDER)
        text = path.read_text()
        self.assertEqual(section(text, '[GPU.6]'), {'GPUIndex': '0', 'GPUName': mac_gpu(), 'GPUScaler': '31.000000',
                                                    'GPUVenderID': '4203', 'LastUsedGPUVendorID': '4203'})
        # DLSS isn't on offer now; the game's default upscaler applies. Other choices stay.
        self.assertNotIn('HighQualityUpsample', text)
        self.assertEqual(section(text, '[Render.13]')['GFXPresetLevel'], '3')
        self.assertNotIn('metalfxSharpness', (self.root/'dxmt.conf').read_text())
        self.assertNotIn('metalfx_nvngx', self.call('status')[-1]['state'])

        env, events = self.play()  # the app's default
        self.assertEqual((events['metalfx']['enabled'], events['metalfx']['nvngx'], events['metalfx']['settings']), (False, 'none', []))

    def test_sharpening_levels_and_their_amounts(self):
        self.playable(self.M1 + b'[Render.13]\r\n')
        self.engine()
        for level, amount in (('high', '0.8'), ('low', '0.4'), ('off', None)):
            _, events = self.play('--metalfx', '1', '--sharpening', level)
            config = (self.root/'dxmt.conf').read_text()
            self.assertEqual(events['metalfx'].get('sharpness'), amount)
            self.assertEqual(config.count('metalfxSharpness'), 1 if amount else 0)
            if amount:
                self.assertTrue(config.endswith(f'd3d11.metalfxSharpness = {amount}\n'))
            self.assertIn('dxgi.fullscreenCanvasWidth = ', config)  # the canvas is still set
        # Sharpening needs upscaling; an unknown level is refused before anything changes.
        _, events = self.play('--metalfx', '0', '--sharpening', 'high')
        self.assertNotIn('sharpness', events['metalfx'])
        self.assertEqual(self.call('launch', '--metalfx', '1', '--sharpening', 'max', success=False)[-1]['code'], 'invalid_arguments')

    def test_an_engine_without_the_stand_ins_launches_without_upscaling(self):
        path = self.playable(self.M1 + b'[Render.13]\r\n')
        system32 = self.engine(stand_ins=False)
        env, events = self.play('--metalfx', '1', '--sharpening', 'high')
        self.assertEqual(events['metalfx'], {'stage': 'metalfx', 'enabled': False, 'available': False, 'nvngx': 'none', 'settings': []})
        self.assertNotIn('DXMT_ENABLE_NVEXT', env)
        self.assertEqual(system32.read_bytes(), PLACEHOLDER)
        self.assertIn(b'GPUName = "Apple M1 Pro"', path.read_bytes())

    def test_a_first_game_records_its_own_card(self):
        # No [GPU.6] yet: the game's first start records the card itself.
        path = self.playable(b'[Render.13]\r\n')
        self.engine()
        _, events = self.play('--metalfx', '1')
        self.assertEqual(events['metalfx']['settings'], [])
        self.assertNotIn(b'[GPU.', path.read_bytes())

    def test_report_only_changes_nothing(self):
        path = self.playable(self.M1 + b'[Render.13]\r\n')
        system32 = self.engine()
        before = path.read_bytes()
        report = self.call('metalfx', '--enabled', '1', '--sharpening', 'high', '--apply', '0')[-1]
        self.assertEqual((report['nvngx'], report['settings'], report['sharpness']), ('install', sorted(NVIDIA), '0.8'))
        self.assertEqual((path.read_bytes(), system32.read_bytes()), (before, PLACEHOLDER))
        self.assertFalse((self.root/'metalfx').exists())
        self.assertEqual(self.call('metalfx', '--enabled', 'yes', success=False)[-1]['code'], 'invalid_arguments')

    def test_a_placeholder_wine_put_back_is_replaced_again(self):
        # Setup after an update (wineboot) can put Wine's placeholder back over the stand-in.
        self.playable(self.M1 + b'[Render.13]\r\n')
        system32 = self.engine()
        self.play('--metalfx', '1')
        system32.write_bytes(PLACEHOLDER + b' (new)')
        _, events = self.play('--metalfx', '1')
        self.assertEqual((events['metalfx']['nvngx'], system32.read_bytes()), ('installed', STAND_IN))
        self.assertEqual((self.root/'metalfx/nvngx.dll').read_bytes(), PLACEHOLDER + b' (new)')
        # Turned off after the placeholder came back: Recall leaves Wine's file alone.
        self.play('--metalfx', '1')
        system32.write_bytes(PLACEHOLDER)
        _, events = self.play('--metalfx', '0')
        self.assertEqual((events['metalfx']['nvngx'], system32.read_bytes()), ('none', PLACEHOLDER))

    def test_a_resolution_chosen_in_the_game_survives_the_switch(self):
        path = self.playable(self.M1 + b'[Render.13]\r\n')
        self.engine()
        self.call('display', '--width', '1920', '--height', '1200')
        self.play()
        self.played(path, 2560, 1440)  # chosen in Overwatch's Video settings
        _, events = self.play('--metalfx', '1')
        self.assertIn('display_from_game', events)
        self.assertEqual(self.resolution(path), (2560, 1440))
        # With the NVIDIA card on record, the player's next choice counts too.
        self.played(path, 1920, 1080)
        _, events = self.play('--metalfx', '1')
        self.assertIn('display_from_game', events)
        self.assertEqual(self.resolution(path), (1920, 1080))


if __name__ == '__main__':
    unittest.main()
