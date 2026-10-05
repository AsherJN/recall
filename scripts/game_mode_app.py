#!/usr/bin/env python3
"""The game app bundle that lets macOS turn Game Mode on for Overwatch (1.1 and later).

macOS turns Game Mode on only for a process whose executable is the main executable of
an app bundle that declares itself a game; every Wine process runs Wine's bare loader.
The engine therefore carries lib/wine/game-mode/Overwatch.app: a copy of the loader whose
Info.plist is the loader's embedded one plus the game category and Game Mode keys.
ntdll starts the programs listed in WINE_GAME_MODE from it (patches/wine-ntdll-syscall-log.patch,
game_mode_exec); the copy finds ntdll.so through argv[0], the usual loader's path.

The copy differs from the loader only in its LC_UUID: local network privacy keys apps
by their main executable's UUID, and a shared one would tie Battle.net's Wine processes
to the game's Local Network choice. It is signed as a bundle with the loader's
entitlements and the hardened runtime, so the signature covers the Info.plist.

  game_mode_app.py ENGINE [--identity ID]   (ad hoc without --identity; for test engines)
"""
import argparse
import hashlib
import plistlib
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import uuid

LOADER = 'lib/wine/x86_64-unix/wine'
BUNDLE = 'lib/wine/game-mode/Overwatch.app'
EXECUTABLE = BUNDLE + '/Contents/MacOS/wine'
FILES = [BUNDLE + '/Contents/Info.plist', EXECUTABLE, BUNDLE + '/Contents/_CodeSignature/CodeResources']
IDENTIFIER = 'org.overwatch2mac.overwatch'
GAME_KEYS = {
    'CFBundleIdentifier': IDENTIFIER,
    'CFBundleName': 'Overwatch',
    'CFBundleExecutable': 'wine',
    'LSApplicationCategoryType': 'public.app-category.action-games',
    'LSSupportsGameMode': True,
    'GCSupportsGameMode': True,  # the key's name on macOS 14 and 15
    # The game process is its own app to macOS now, so its permission prompts name it.
    'NSLocalNetworkUsageDescription': "Overwatch looks up your Mac's address on your local network when it starts.",
    'NSMicrophoneUsageDescription': 'Overwatch uses the microphone for voice chat.',
}
LC_SEGMENT_64, LC_UUID = 0x19, 0x1b


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def load_commands(data):
    """(cmd, offset, size) of each load command of a 64-bit little-endian Mach-O file."""
    if data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Not a 64-bit little-endian Mach-O file')
    offset = 32
    for _ in range(int.from_bytes(data[16:20], 'little')):
        cmd, size = (int.from_bytes(data[offset + i:offset + i + 4], 'little') for i in (0, 4))
        yield cmd, offset, size
        offset += size


def embedded_info(data):
    """The Info.plist in the __TEXT,__info_plist section."""
    for cmd, offset, _ in load_commands(data):
        if cmd != LC_SEGMENT_64 or data[offset + 8:offset + 24].rstrip(b'\0') != b'__TEXT':
            continue
        for i in range(int.from_bytes(data[offset + 64:offset + 68], 'little')):
            section = offset + 72 + 80 * i
            if data[section:section + 16].rstrip(b'\0') == b'__info_plist':
                size = int.from_bytes(data[section + 40:section + 48], 'little')
                start = int.from_bytes(data[section + 48:section + 52], 'little')
                return plistlib.loads(data[start:start + size].rstrip(b'\0'))
    raise ValueError('No embedded Info.plist')


def uuid_offset(data):
    for cmd, offset, _ in load_commands(data):
        if cmd == LC_UUID:
            return offset + 8
    raise ValueError('No LC_UUID')


def info_plist(loader_data, minimum_macos, identifier=IDENTIFIER):
    info = embedded_info(loader_data)
    info.update(GAME_KEYS, LSMinimumSystemVersion=minimum_macos, CFBundleIdentifier=identifier)
    return info


def unsigned(path, folder):
    copy = Path(folder) / (Path(path).name + '-' + hashlib.sha256(str(path).encode()).hexdigest()[:8])
    shutil.copy2(path, copy)
    run('codesign', '--remove-signature', copy)
    return copy.read_bytes()


def entitlements_of(path):
    xml = subprocess.run(['codesign', '-d', '--xml', '--entitlements', '-', str(path)], capture_output=True).stdout
    return plistlib.loads(xml) if xml.strip() else None


def make(engine, minimum_macos, identity='-', identifier=IDENTIFIER):
    """Create BUNDLE in ENGINE from its loader; return the files it added (FILES). Another
    IDENTIFIER is for tests only: macOS asks for permissions afresh for a new identity."""
    engine = Path(engine)
    loader, bundle = engine / LOADER, engine / BUNDLE
    if bundle.exists():
        raise ValueError(f'{BUNDLE} already exists')
    data = loader.read_bytes()
    (bundle / 'Contents/MacOS').mkdir(parents=True)
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info_plist(data, minimum_macos, identifier)))
    copy = bytearray(data)
    at = uuid_offset(data)
    copy[at:at + 16] = uuid.uuid5(uuid.UUID(bytes=bytes(data[at:at + 16])), identifier).bytes
    target = engine / EXECUTABLE
    target.write_bytes(bytes(copy))
    target.chmod(loader.stat().st_mode & 0o777)
    with tempfile.TemporaryDirectory() as folder:
        args = ['codesign', '--force', '--options', 'runtime', '--sign', identity]
        if identity != '-':
            args.append('--timestamp')
        entitlements = entitlements_of(loader)
        if entitlements is not None:
            plist = Path(folder) / 'entitlements.plist'
            plist.write_bytes(plistlib.dumps(entitlements))
            args += ['--entitlements', plist]
        run(*args, bundle, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    check(engine, identifier)
    added = sorted(str(p.relative_to(engine)) for p in bundle.rglob('*') if p.is_file())
    if added != sorted(FILES):
        raise ValueError('Unexpected game app files: ' + ', '.join(added))
    return added


def check(engine, identifier=IDENTIFIER):
    """The bundle is sealed and signed like the loader, and its executable is the loader
    apart from LC_UUID."""
    engine = Path(engine)
    loader, bundle = engine / LOADER, engine / BUNDLE
    run('codesign', '--verify', '--strict', '--deep', bundle)
    info = subprocess.run(['codesign', '-dvv', str(bundle)], capture_output=True, text=True).stderr
    if (not re.search(r'^Identifier=' + re.escape(identifier) + '$', info, re.M)
            or not re.search(r'^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*\bruntime\b', info, re.M)):
        raise ValueError('The game app is not signed with its identifier and the hardened runtime')
    if not re.search(r'^Info\.plist entries=\d+', info, re.M):
        raise ValueError("The game app's signature does not cover its Info.plist")
    if entitlements_of(engine / EXECUTABLE) != entitlements_of(loader):
        raise ValueError('The game app is entitled differently from the loader')
    with tempfile.TemporaryDirectory() as folder:
        a, b = unsigned(loader, folder), unsigned(engine / EXECUTABLE, folder)
    at = uuid_offset(a)
    if len(a) != len(b) or a[:at] != b[:at] or a[at + 16:] != b[at + 16:] or a[at:at + 16] == b[at:at + 16]:
        raise ValueError("The game app's executable differs from the loader beyond its UUID")
    if plistlib.loads((bundle / 'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier') != identifier:
        raise ValueError("The game app's Info.plist names another bundle")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('engine', type=Path)
    parser.add_argument('--identity', default='-')
    parser.add_argument('--minimum-macos', default='15.0')
    parser.add_argument('--identifier', default=IDENTIFIER, help='Another bundle identifier, for tests only')
    args = parser.parse_args()
    print('\n'.join(make(args.engine, args.minimum_macos, args.identity, args.identifier)))
