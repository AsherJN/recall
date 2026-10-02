#!/usr/bin/env python3
"""Package a signed, notarized app bundle into a signed, notarized, stapled DMG.

The DMG opens as a fixed window: the app, an Applications shortcut and a
background that shows where to drag it (scripts/dmg_background.swift).
dmgbuild writes that window layout directly, without scripting Finder, and
copies the app with ditto, which preserves its signature and staple. Install
it once (python3 -m pip install dmgbuild==1.6.5) and run this script with
that Python; --plain builds a DMG without the window layout instead. The DMG
itself is then Developer ID signed, submitted with notarytool, stapled and
verified.
"""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
APP_NAME = 'Recall'
# Finder window content size and icon centers, in points from the top left.
# The background is drawn 40 points taller than the content so a taller title
# bar never uncovers Finder's default white.
WINDOW = (640, 380)
APP_X, APPLICATIONS_X, ICON_Y = 170, 470, 190


def run(*args, **kw):
    print('+', ' '.join(str(a) for a in args), flush=True)
    return subprocess.run([str(a) for a in args], check=True, **kw)


def layout_dmg(app, output, volume_name, work):
    try:
        import dmgbuild
    except ImportError:
        raise SystemExit('dmgbuild is required for the window layout: python3 -m pip install dmgbuild==1.6.5, '
                         'then run this script with that Python (or pass --plain)')
    background = work / 'background.png'
    run('/usr/bin/swift', ROOT / 'scripts/dmg_background.swift', ROOT / 'app/Resources/Wordmark.png', background,
        APP_NAME, WINDOW[0], WINDOW[1] + 40, APP_X, APPLICATIONS_X, ICON_Y)
    settings = {
        'format': 'UDZO', 'compression_level': 9, 'filesystem': 'HFS+',
        'files': [str(app)], 'symlinks': {'Applications': '/Applications'},
        'icon_locations': {app.name: (APP_X, ICON_Y), 'Applications': (APPLICATIONS_X, ICON_Y)},
        'background': str(background),
        # The mounted volume shows the app's icon in Finder.
        'icon': str(app / 'Contents/Resources/AppIcon.icns'),
        # Window bounds include the title bar.
        'window_rect': ((200, 140), (WINDOW[0], WINDOW[1] + 28)),
        'default_view': 'icon-view', 'icon_size': 128, 'text_size': 13, 'label_pos': 'bottom',
        'show_status_bar': False, 'show_tab_view': False, 'show_toolbar': False,
        'show_pathbar': False, 'show_sidebar': False, 'show_icon_preview': False,
        'include_icon_view_settings': True, 'include_list_view_settings': False,
    }
    print('+ dmgbuild', output, flush=True)
    dmgbuild.build_dmg(str(output), volume_name, settings=settings)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--app', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--identity', required=True, help='Developer ID Application identity')
    p.add_argument('--notary-profile', default='overwatch-2-mac-notary')
    p.add_argument('--volume-name', default=APP_NAME)
    p.add_argument('--plain', action='store_true', help='no window layout (test images)')
    p.add_argument('--skip-notarize', action='store_true')
    a = p.parse_args()
    if not (a.app / 'Contents/Info.plist').exists():
        raise SystemExit('Not an app bundle: ' + str(a.app))
    if a.output.exists():
        raise SystemExit('Output exists; refusing to overwrite: ' + str(a.output))
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', a.app)
    run('/usr/bin/xcrun', 'stapler', 'validate', a.app)
    a.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        stage = Path(tmp) / 'stage'
        stage.mkdir()
        run('/usr/bin/ditto', a.app, stage / a.app.name)
        if a.plain:
            (stage / 'Applications').symlink_to('/Applications')
            run('/usr/bin/hdiutil', 'create', '-volname', a.volume_name, '-srcfolder', stage,
                '-ov', '-format', 'UDZO', '-imagekey', 'zlib-level=9', a.output)
        else:
            layout_dmg(stage / a.app.name, a.output, a.volume_name, Path(tmp))
    run('/usr/bin/codesign', '--force', '--timestamp', '--sign', a.identity, a.output)
    run('/usr/bin/codesign', '--verify', '--verbose=2', a.output)
    if not a.skip_notarize:
        run('/usr/bin/xcrun', 'notarytool', 'submit', a.output,
            '--keychain-profile', a.notary_profile, '--wait')
        run('/usr/bin/xcrun', 'stapler', 'staple', a.output)
        run('/usr/bin/xcrun', 'stapler', 'validate', a.output)
        run('/usr/sbin/spctl', '-a', '-t', 'open', '--context', 'context:primary-signature',
            '-v', a.output)
    digest = hashlib.sha256(a.output.read_bytes()).hexdigest()
    print('DMG', a.output, a.output.stat().st_size, 'bytes')
    print('SHA256', digest)
    (a.output.with_suffix('.dmg.sha256')).write_text(digest + '  ' + a.output.name + '\n')


if __name__ == '__main__':
    main()
