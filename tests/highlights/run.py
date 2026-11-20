#!/usr/bin/env python3
"""Save MP4 highlights through Media Foundation in Wine, as Overwatch does, and check each
file the way a Mac player opens it (REC-53, patches/wine-media-foundation.patch).

mf_writer_test.c, built with the pinned LLVM-MinGW, writes an H.264 and AAC file with the
sink writer: uncompressed frames and PCM in, encoder settings through ICodecAPI, then
Finalize. verify_mp4.swift opens the file with AVFoundation: one H.264 and one AAC track,
every frame decoded with its number in order and the test pattern's bars in place, and the
two tones starting with the picture.

  python3 tests/highlights/run.py [--engine DIR] [--work DIR] [--long] [--cocoa] [--keep] [--only NAME...]

--engine is an unpacked engine; the default is the one app/Resources/release.json pins,
under runtime/phase-2/artifacts. The Wine prefix is made in a scratch folder (--work picks
where, a RAM disk for example) and removed afterwards unless --keep. --long adds a
20-second 1080p60 clip and a 12-second 4K60 one. --cocoa also drives winemacmf's macOS
half without Wine (cocoa_harness.c), built from runtime/source/wine-media.

The game clips set the encoder as Overwatch does (--game: quality-based rate control, two
B-frames). The software ones run them on Apple's software H.264 encoder, which macOS gives
when the hardware one is unavailable: it keeps back 15 frames before it returns one and has
no quality setting, and before the November 16 fix saving froze on it, leaving players a 0 MB
file. A clip that takes longer than WRITER_TIMEOUT fails.
"""
from pathlib import Path
import argparse
import os
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
FRAMEWORKS = ('Foundation', 'AudioToolbox', 'CoreMedia', 'CoreVideo', 'VideoToolbox')
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
    ('game-720p60', 'nv12', 'pcm16', (1280, 720, 60, 3), ('--game',), ()),
    ('game-720p60-software', 'nv12', 'pcm16', (1280, 720, 60, 3), ('--game', '--software'), ()),
    ('game-1080p60-software', 'nv12', 'pcm16', HD, ('--game', '--software'), ()),
    # The save in a player's log (November 19) that never became a file: 27 s of 720p60 on the
    # hardware encoder, Overwatch's settings and sound, finished through its callback.
    ('overwatch-720p60-27s', 'nv12', 'pcm16', (1280, 720, 60, 27), ('--game', '--audio-per-frame', '--async'), ()),
    # The same save with Media Foundation's shared work queue held from Finalize on.
    ('busy-queue', 'nv12', 'pcm16', (1280, 720, 60, 3), ('--game', '--audio-per-frame', '--busy-queue'), ()),
)
LONG_CLIPS = (
    ('1080p60-20s', 'rgb32', 'pcm16', (1920, 1080, 60, 20), (), ()),
    ('4k60-12s', 'rgb32', 'pcm16', (3840, 2160, 60, 12), (), ()),
)
COCOA_FORMATS = ('bgra', 'nv12', 'i420', 'yv12', 'yuy2')
SOFTWARE = {'WINEMACMF_SOFTWARE_ENCODER': '1'}   # --software: a clip option run.py turns into this
WRITER_TIMEOUT = 300                              # seconds; the longest --long clip takes about a minute
FINISH_LIMIT = 10000                              # ms from Finalize to the finished file; --busy-queue holds 30 s


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


def ffmpeg_check(path, size):
    """The same file through FFmpeg, as Discord, browsers and most editors read it: every frame
    decodes, both streams start at zero and the tone starts with the picture. None without FFmpeg."""
    ffmpeg, ffprobe = shutil.which('ffmpeg'), shutil.which('ffprobe')
    if not ffmpeg or not ffprobe:
        return None
    width, height, fps, seconds = size
    failures = []
    probe = subprocess.run([ffprobe, '-v', 'error', '-count_frames', '-show_entries',
                            'stream=codec_type,start_time,nb_read_frames', '-of', 'json', str(path)],
                           capture_output=True, text=True)
    try:
        streams = json.loads(probe.stdout)['streams']
    except (ValueError, KeyError):
        return ['ffprobe could not read the file']
    for stream in streams:
        if abs(float(stream.get('start_time', 0))) > 0.001:
            failures.append(f"{stream['codec_type']} starts at {stream['start_time']}")
        if stream['codec_type'] == 'video' and int(stream.get('nb_read_frames', 0)) != fps * seconds:
            failures.append(f"ffmpeg decodes {stream.get('nb_read_frames')} frames")
    decoded = subprocess.run([ffmpeg, '-v', 'error', '-i', str(path), '-map', '0:a:0', '-f', 'f32le', '-ac', '2', '-'],
                             capture_output=True)
    if decoded.returncode or decoded.stderr.strip():
        failures.append('ffmpeg audio decode: ' + decoded.stderr.decode(errors='replace').strip()[:120])
    samples = memoryview(decoded.stdout[:len(decoded.stdout) // 8 * 8]).cast('f')[0::2] if len(decoded.stdout) >= 8 else []
    rate = 48000
    # The left tone, as verify_mp4 hears it: about sample 3 when it starts with the picture.
    first = next((i for i, value in enumerate(samples) if abs(value) > 0.05), None)
    if first is None:
        failures.append('ffmpeg hears no sound')
    elif first < 2 or first > rate * 0.005:
        failures.append(f'ffmpeg hears the tone start at sample {first}')
    if abs(len(samples) / rate - seconds) > 0.05:
        failures.append(f'ffmpeg hears {len(samples) / rate:.4f} s of sound')
    full = subprocess.run([ffmpeg, '-v', 'error', '-i', str(path), '-f', 'null', '-'], capture_output=True, text=True)
    if full.stderr.strip():
        failures.append('ffmpeg decode: ' + full.stderr.strip().splitlines()[0][:120])
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--engine', type=Path, help='unpacked engine (default: the one release.json pins)')
    parser.add_argument('--work', type=Path, help='folder for the scratch prefix (default: a temporary folder)')
    parser.add_argument('--long', action='store_true', help='add a 20-second 1080p60 and a 12-second 4K60 clip')
    parser.add_argument('--cocoa', action='store_true', help="also drive winemacmf's macOS half without Wine")
    parser.add_argument('--keep', action='store_true', help='keep the scratch folder')
    parser.add_argument('--only', nargs='+', metavar='NAME', help='run only these clips')
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
            build(['/usr/bin/clang', '-arch', 'x86_64', '-O2', '-Wall', '-c', WINEMACMF/'mp4_writer.c',
                   '-o', tools/'mp4_writer.o'], env=ENV)
            build(['/usr/bin/clang', '-arch', 'x86_64', '-O2', '-Wall', '-I', WINEMACMF, '-o', tools/'cocoa_harness',
                   HERE/'cocoa_harness.c', tools/'macmf_cocoa.o', tools/'mp4_writer.o', *framework_flags], env=ENV)
            for picture in COCOA_FORMATS:
                output = work/f'cocoa-{picture}.mp4'
                result = subprocess.run([str(tools/'cocoa_harness'), str(output), picture, *map(str, HD)],
                                        capture_output=True, text=True)
                if result.returncode:
                    report(f'cocoa {picture}', False, (result.stderr.strip().splitlines() or ['harness failed'])[-1])
                else:
                    report(f'cocoa {picture}', *check(verifier, output, HD, ()))
            for name, extra in (('cocoa game', {}), ('cocoa game software', SOFTWARE)):
                output = work/(name.replace(' ', '-') + '.mp4')
                try:
                    result = subprocess.run([str(tools/'cocoa_harness'), str(output), 'nv12', *map(str, HD), '--game'],
                                            capture_output=True, text=True, env=dict(os.environ, **extra),
                                            timeout=WRITER_TIMEOUT)
                except subprocess.TimeoutExpired:
                    report(name, False, f'no file after {WRITER_TIMEOUT} s: the encoder stopped')
                    continue
                if result.returncode:
                    report(name, False, (result.stderr.strip().splitlines() or ['harness failed'])[-1])
                else:
                    report(name, *check(verifier, output, HD, ()))

        # A fresh prefix: wineboot registers the engine's DLLs from wine.inf, winemacmf included.
        with open(work/'wineboot.log', 'w') as log:
            subprocess.run([str(engine/'bin/wine'), 'wineboot.exe', '-u'], env=env, stdout=log, stderr=log, check=True)
        subprocess.run([str(engine/'bin/wineserver'), '-w'], env=env, check=True)
        shutil.copy(tools/'mf_writer_test.exe', prefix/'drive_c')
        for name, picture, audio, size, options, checks in CLIPS + (LONG_CLIPS if args.long else ()):
            if args.only and name not in args.only:
                continue
            clip_env = dict(env, **SOFTWARE) if '--software' in options else env
            options = [option for option in options if option != '--software']
            with open(work/f'{name}.wine.log', 'w') as log:
                try:
                    result = subprocess.run([str(engine/'bin/wine'), 'C:\\mf_writer_test.exe', f'C:\\{name}.mp4',
                                             picture, audio, *map(str, size), *options],
                                            env=clip_env, stdout=subprocess.PIPE, stderr=log, text=True,
                                            timeout=WRITER_TIMEOUT)
                except subprocess.TimeoutExpired:
                    subprocess.run([str(engine/'bin/wineserver'), '-k'], env=env, stderr=subprocess.DEVNULL)
                    report(name, False, f'no file after {WRITER_TIMEOUT} s: the encoder stopped (see {work/name}.wine.log)')
                    continue
            written = last_json(result.stdout)
            if not written or not written.get('ok'):
                report(name, False, f'writer exit {result.returncode}: {written or result.stdout.strip() or "no output"} '
                                    f'(see {work/name}.wine.log)')
                continue
            passed, summary = check(verifier, prefix/'drive_c'/f'{name}.mp4', size, checks)
            others = ffmpeg_check(prefix/'drive_c'/f'{name}.mp4', size) if '--channels' not in options else None
            if others:
                passed, summary = False, summary + ' | ' + '; '.join(others)
            elif others is not None:
                summary += ' ffmpeg=ok'
            finish_ms = written.get('finalize_ms', 0)
            summary += f' finish={finish_ms}ms'
            if finish_ms > FINISH_LIMIT:
                passed, summary = False, summary + f' | finishing took over {FINISH_LIMIT} ms'
            report(name, passed, summary)
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
