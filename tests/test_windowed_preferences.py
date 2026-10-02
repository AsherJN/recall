import sys
from pathlib import Path
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from set_windowed_1080 import update_preferences


class WindowPreferences(unittest.TestCase):
    def test_edit_is_scoped_and_preserves_other_settings_and_newlines(self):
        original = ('[Input.1]\r\nWindowMode = "7"\r\n\r\n[Render.13]\r\n'
                    'WindowMode = "2"\r\nWindowedWidth = "3016"\r\n'
                    'FrameRateCap = "90"\r\nVerticalSyncEnabled = "0"\r\n'
                    '\r\n[Sound.3]\r\nVolume = "80"\r\n')
        updated, changes = update_preferences(original)
        self.assertIn('[Input.1]\r\nWindowMode = "7"\r\n', updated)
        self.assertIn('WindowedWidth = "1920"\r\n', updated)
        self.assertIn('WindowedHeight = "1080"\r\n', updated)
        self.assertIn('FrameRateCap = "90"\r\nVerticalSyncEnabled = "0"\r\n', updated)
        self.assertTrue(updated.endswith('[Sound.3]\r\nVolume = "80"\r\n'))
        self.assertNotIn('\n', updated.replace('\r\n', ''))
        self.assertEqual(changes['WindowedWidth'], dict(before='3016', after='1920'))
        self.assertEqual(changes['WindowMode'], dict(before='2', after='0'))
        self.assertIn('FullScreenWidth = "1920"',updated)
        self.assertIn('FullScreenHeight = "1080"',updated)
        self.assertEqual(update_preferences(updated), (updated, {}))

    def test_ambiguous_render_settings_are_rejected(self):
        for text in ('[Input.1]\nX=1\n', '[Render.13]\n[Render.13]\n',
                     '[Render.13]\nWindowMode="0"\nWindowMode="2"\n'):
            with self.subTest(text=text), self.assertRaises(ValueError):
                update_preferences(text)


if __name__ == '__main__':
    unittest.main()
