#!/usr/bin/env python3
"""Save MP4 highlights through Media Foundation in Wine, as Overwatch does, and check each
file the way a Mac player opens it (REC-53, patches/wine-media-foundation.patch).

mf_writer_test.c, built with the pinned LLVM-MinGW, writes an H.264 and AAC file with the
sink writer: uncompressed frames and PCM in, encoder settings through ICodecAPI, then
Finalize. verify_mp4.swift opens the file with AVFoundation: one H.264 and one AAC track,
every frame decoded with its number in order and the test pattern's bars in place, and the
two tones starting with the picture.

  python3 tests/highlights/run.py [--engine DIR] [--work DIR] [--long] [--cocoa] [--keep]

--engine is an unpacked engine; the default is the one app/Resources/release.json pins,
under runtime/phase-2/artifacts. The Wine prefix is made in a scratch folder (--work picks
where, a RAM disk for example) and removed afterwards unless --keep. --long adds a
20-second 1080p60 clip and a 12-second 4K60 one. --cocoa also drives winemacmf's macOS
half without Wine (cocoa_harness.c), built from runtime/source/wine-media.
"""
from pathlib import Path
import argparse
import json
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT/'scripts'))
from build_wine_native import ENV, LLVM_STRIP  # noqa: E402

MINGW_CLANG = LLVM_STRIP.parent/'x86_64-w64-mingw32-clang'
WINEMACMF = ROOT/'runtime/source/wine-media/dlls/winemacmf'
FRAMEWORKS = ('Foundation', 'AVFoundation', 'AudioToolbox', 'CoreMedia', 'CoreVideo', 'VideoToolbox')
HD = (1920, 1080, 60, 3)

# Name, picture format, audio format, size and length, writer options, checker options.
CLIPS = (
    ('rgb32', 'rgb32', 'pcm16', HD, (), ()),
    ('argb32-async', 'argb32', 'pcm16', HD, ('--async',), ()),
    ('bottomup-float', 'rgb32-bottomup', 'float', HD, (), ()),
    ('bottomup-async', 'rgb32-bottomup', 'float', HD, ('--async',), ()),
    ('nostride', 'rgb32-nostride', 'pcm16', HD, (), ()),
    ('nv12', 'nv12', 'pcm16', HD, (), ()),
    ('hardware-defaults', 'rgb32', 'pcm16', HD, ('--hardware', '--no-codecapi'), ()),
    ('surround', 'rgb32', 'float', HD, ('--channels', '6'), ('--channels', '6')),
    ('1440p30', 'rgb32', 'pcm16', (2560, 1440, 30, 2), (), ()),
)
LONG_CLIPS = (
    ('1080p60-20s', 'rgb32', 'pcm16', (1920, 1080, 60, 20), (), ()),
    ('4k60-12s', 'rgb32', 'pcm16', (3840, 2160, 60, 12), (), ()),
)
COCOA_FORMATS = ('bgra', 'nv12', 'i420', 'yv12', 'yuy2')


def pinned_engine():
    version = json.loads((ROOT/'app/Resources/release.json').read_text())['runtimeVersion']
    return ROOT/'runtime/phase-2/artifacts'/version


def build(command, env=None):
    subprocess.run([str(part) for part in command], check=True, env=env)


def last_json(text):
    for line in reversed(text.replace('\r', '').splitlines()):
        if line.startswith('{'):
            try:
                return json.loads(line)
            except ValueError:
                return None
    return None


def check(verifier, path, size, options):
    """verify_mp4's verdict on PATH: (passed, one-line summary)."""
    result = subprocess.run([str(verifier), str(path), *map(str, size), '--pattern', *options],
                            capture_output=True, text=True)
    report = last_json(result.stdout)
    if report is None:
        return False, 'no report: ' + ((result.stderr.strip().splitlines() or ['no output'])[-1])
    summary = 'frames=%s audio=%.4fs duration=%.4fs' % (
        report.get('video_frames'), report.get('audio_seconds', -1), report.get('duration', -1))
    if report.get('failures'):
        return False, summary + ' | ' + '; '.join(map(str, report['failures']))
    return True, summary


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--engine', type=Path, help='unpacked engine (default: the one release.json pins)')
    parser.add_argument('--work', type=Path, help='folder for the scratch prefix (default: a temporary folder)')
    parser.add_argument('--long', action='store_true', help='add a 20-second 1080p60 and a 12-second 4K60 clip')
    parser.add_argument('--cocoa', action='store_true', help="also drive winemacmf's macOS half without Wine")
    parser.add_argument('--keep', action='store_true', help='keep the scratch folder')
    args = parser.parse_args()
    engine = (args.engine or pinned_engine()).resolve()
    if not (engine/'bin/wine').is_file() or not (engine/'lib/wine/x86_64-unix/winemacmf.so').is_file():
        sys.exit(f'{engine} is not an engine with winemacmf')
    work = Path(tempfile.mkdtemp(prefix='recall-highlights-', dir=args.work))
    tools, prefix = work/'build', work/'prefix'
    env = {'WINEPREFIX': str(prefix), 'WINEARCH': 'win64', 'HOME': str(work/'home'), 'TMPDIR': str(work/'tmp') + '/',
           'USER': 'player', 'WINEDEBUG': 'err+all', 'WINESERVER': str(engine/'bin/wineserver'),
           'WINELOADER': str(engine/'bin/wine'), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'}
    results, finished = [], False

    def report(name, passed, summary):
        results.append(passed)
        print(f'{name:<20} {"PASS" if passed else "FAIL"}  {summary}', flush=True)

    try:
        for folder in (tools, work/'home', work/'tmp'):
            folder.mkdir()
        build([MINGW_CLANG, '-municode', '-O2', '-Wall', '-o', tools/'mf_writer_test.exe', HERE/'mf_writer_test.c',
               '-lmfplat', '-lmfreadwrite', '-lmfuuid', '-lole32', '-loleaut32', '-luuid', '-lstrmiids'])
        build(['/usr/bin/swiftc', '-O', '-o', tools/'verify_mp4', HERE/'verify_mp4.swift'])
        verifier = tools/'verify_mp4'

        if args.cocoa:
            framework_flags = [flag for name in FRAMEWORKS for flag in ('-framework', name)]
            build(['/usr/bin/clang', '-arch', 'x86_64', '-fobjc-arc', '-O2', '-c', WINEMACMF/'macmf_cocoa.m',
                   '-o', tools/'macmf_cocoa.o'], env=ENV)
            build(['/usr/bin/clang', '-arch', 'x86_64', '-O2', '-Wall', '-I', WINEMACMF, '-o', tools/'cocoa_harness',
                   HERE/'cocoa_harness.c', tools/'macmf_cocoa.o', *framework_flags], env=ENV)
            for picture in COCOA_FORMATS:
                output = work/f'cocoa-{picture}.mp4'
                result = subprocess.run([str(tools/'cocoa_harness'), str(output), picture, *map(str, HD)],
                                        capture_output=True, text=True)
                if result.returncode:
                    report(f'cocoa {picture}', False, (result.stderr.strip().splitlines() or ['harness failed'])[-1])
                else:
                    report(f'cocoa {picture}', *check(verifier, output, HD, ()))

        # A fresh prefix: wineboot registers the engine's DLLs from wine.inf, winemacmf included.
        with open(work/'wineboot.log', 'w') as log:
            subprocess.run([str(engine/'bin/wine'), 'wineboot.exe', '-u'], env=env, stdout=log, stderr=log, check=True)
        subprocess.run([str(engine/'bin/wineserver'), '-w'], env=env, check=True)
        shutil.copy(tools/'mf_writer_test.exe', prefix/'drive_c')
        for name, picture, audio, size, options, checks in CLIPS + (LONG_CLIPS if args.long else ()):
            with open(work/f'{name}.wine.log', 'w') as log:
                result = subprocess.run([str(engine/'bin/wine'), 'C:\\mf_writer_test.exe', f'C:\\{name}.mp4', picture,
                                         audio, *map(str, size), *options],
                                        env=env, stdout=subprocess.PIPE, stderr=log, text=True)
            written = last_json(result.stdout)
            if not written or not written.get('ok'):
                report(name, False, f'writer: {written or result.stdout.strip() or "no output"} (see {work/name}.wine.log)')
                continue
            report(name, *check(verifier, prefix/'drive_c'/f'{name}.mp4', size, checks))
        finished = True
    finally:
        if prefix.exists():
            subprocess.run([str(engine/'bin/wineserver'), '-k'], env=env, stderr=subprocess.DEVNULL)
        if args.keep or not finished or not all(results):
            print(f'Scratch folder kept: {work}')
        else:
            shutil.rmtree(work, ignore_errors=True)
    print(f'{sum(results)} of {len(results)} passed with {engine.name}')
    return 0 if results and all(results) else 1


if __name__ == '__main__':
    sys.exit(main())
