#!/usr/bin/env python3
"""Test Wine's actual exclusive-mode method without a game or display access.

The patch's setMode hunk must change only the activity predicate, and the
executable-name selection must match Diablo III alone. Where the driver's source
checkout is present (the engineering tree), the patch is applied to the
checkout's first commit, its base, and the complete before/after setMode methods
are compiled with fake NSApp and CG display boundaries. The patch keeps the
usual three lines of context, as scripts/build_wine_native.py writes it, so the
public tree, which has the patch but not Wine's source, runs the hunk checks
only. No installed runtime is needed; no real display API is called.
"""
import ast
import functools
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PATCH = ROOT / 'patches/wine-winemac-activation.patch'
SOURCES = ROOT / 'docs/SOURCES.json'
if not SOURCES.exists():  # the engineering tree keeps it as docs/public-sources.json
    SOURCES = ROOT / 'docs/public-sources.json'
SOURCE = ROOT / 'runtime/source/wine-winemac'
COCOA_APP = 'dlls/winemac.drv/cocoa_app.m'
MACDRV_MAIN = 'dlls/winemac.drv/macdrv_main.c'
SET_MODE = '- (BOOL) setMode:(CGDisplayModeRef)mode forDisplay:(CGDirectDisplayID)displayID'
PREDICATE = ' || (diablo_eager_initial_mode && !beenActive)'


def hunks(filename):
    """This file's unified-diff hunks: header, before image and after image."""
    marker = 'diff --git a/{0} b/{0}\n'.format(filename)
    section = PATCH.read_text().split(marker, 1)[1].split('\ndiff --git ', 1)[0]
    result = []
    for line in section.splitlines(keepends=True):
        if line.startswith('@@ '):
            result.append(dict(header=line, before=[], after=[]))
        elif result and line[:1] in ' -+':
            if line[:1] in ' -':
                result[-1]['before'].append(line[1:])
            if line[:1] in ' +':
                result[-1]['after'].append(line[1:])
    return result


def patch_image(filename, after=True):
    """Return only source lines from this file's unified-diff hunks."""
    return ''.join('\n' + ''.join(hunk['after' if after else 'before']) for hunk in hunks(filename))


def normalized(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'//[^\n]*', '', text)
    return re.sub(r'\s+', '', text)


def extract(text, signature):
    start = text.index(signature)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]


def process_scope():
    text = patch_image(MACDRV_MAIN)
    declaration = re.search(r'static const WCHAR diablo3W\[\]\s*=\s*\{[^}]+\};', text).group()
    start = text.index('appname = NtCurrentTeb()->Peb->ProcessParameters->ImagePathName.Buffer;')
    end = text.index('diablo_eager_initial_mode =', start)
    end = text.index(';', end) + 1
    return declaration + '\n' + text[start:end]


@functools.lru_cache(maxsize=None)
def patched_source():
    """(before, after) of cocoa_app.m: the source checkout's first commit, and it with the patch applied.

    None without the checkout. Every branch of the checkout shares that first commit, so the
    result depends only on the patch, not on what is checked out."""
    if not (SOURCE / '.git').exists():
        return None
    git = ['git', '-C', str(SOURCE)]
    first = subprocess.run([*git, 'rev-list', '--max-parents=0', 'HEAD'],
                           capture_output=True, text=True, check=True).stdout.split()[0]
    with tempfile.TemporaryDirectory(prefix='recall-eager-source-') as tmp:
        names = sorted({line[len('diff --git a/'):].split(' b/', 1)[0]
                        for line in PATCH.read_text().splitlines() if line.startswith('diff --git a/')})
        for name in names:
            shown = subprocess.run([*git, 'show', f'{first}:{name}'], capture_output=True)
            if shown.returncode == 0:  # otherwise the patch creates the file
                path = Path(tmp) / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(shown.stdout)
        before = (Path(tmp) / COCOA_APP).read_text()
        applied = subprocess.run(['git', 'apply', str(PATCH)], cwd=tmp, capture_output=True, text=True)
        if applied.returncode:
            raise AssertionError('patch does not apply to the checkout base: ' + applied.stderr)
        return before, (Path(tmp) / COCOA_APP).read_text()


def production_method(after=True):
    source = patched_source()
    if source is None:
        raise unittest.SkipTest("needs Wine's source checkout at runtime/source/wine-winemac")
    return extract(source[1] if after else source[0], SET_MODE)


HARNESS=r'''
#import <AppKit/AppKit.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
static unsigned assertions;
static void check(BOOL yes,const char*m){assertions++;if(!yes){fprintf(stderr,"FAIL: %s\n",m);exit(1);}}
static bool diablo_eager_initial_mode;
typedef uint16_t WCHAR;
static struct Params{struct{WCHAR*Buffer;}ImagePathName;}params;
static struct Peb{struct Params*ProcessParameters;}peb={&params};
static struct Teb{struct Peb*Peb;}teb={&peb};
static struct Teb*NtCurrentTeb(void){return&teb;}
static WCHAR*fake_wcsrchr(const WCHAR*s,WCHAR c){WCHAR*last=NULL;while(*s){if(*s==c)last=(WCHAR*)s;s++;}return last;}
static int fake_wcsicmp(const WCHAR*a,const WCHAR*b){while(*a&&*b&&tolower(*a)==tolower(*b)){a++;b++;}return tolower(*a)-tolower(*b);}
#define wcsrchr fake_wcsrchr
#define wcsicmp fake_wcsicmp
static void select_process(const char*path){
 WCHAR name[512],*p,*appname;size_t n=strlen(path);check(n<511,"bounded executable path");
 for(size_t i=0;i<=n;i++)name[i]=(unsigned char)path[i];params.ImagePathName.Buffer=name;
 __SCOPE__
}

@interface FixtureMode:NSObject
@property unsigned token;
@end
@implementation FixtureMode
@end
@interface FakeApplication:NSObject
@property(getter=isActive)BOOL active;
@end
@implementation FakeApplication
@end
static FakeApplication*fixture_app;
#define NSApp fixture_app
#define CGDisplayModeRef FixtureMode*
static FixtureMode*desktop_mode,*game_mode,*physical_mode;
static BOOL captured;
static unsigned capture_calls,set_calls,restore_calls,release_calls;
static int capture_result,set_result;
static FixtureMode*fixture_retain_mode(FixtureMode*mode){return[mode retain];}
static void fixture_release_mode(FixtureMode*mode){[mode release];}
static FixtureMode*fixture_copy_mode(CGDirectDisplayID display){(void)display;return[physical_mode retain];}
static int fixture_capture(void){capture_calls++;if(!capture_result)captured=YES;return capture_result;}
static int fixture_set(CGDirectDisplayID display,FixtureMode*mode,const void*options){(void)display;(void)options;set_calls++;if(!set_result)physical_mode=mode;return set_result;}
static void fixture_restore(void){restore_calls++;physical_mode=desktop_mode;}
static int fixture_release(void){release_calls++;captured=NO;return 0;}
#define CGDisplayModeRetain fixture_retain_mode
#define CGDisplayModeRelease fixture_release_mode
#define CGDisplayCopyDisplayMode fixture_copy_mode
#define CGCaptureAllDisplays fixture_capture
#define CGDisplaySetDisplayMode fixture_set
#define CGRestorePermanentDisplayConfiguration fixture_restore
#define CGReleaseAllDisplays fixture_release
@interface Controller:NSObject{
@public
 NSMutableDictionary*originalDisplayModes;
 NSMutableDictionary*latentDisplayModes;
 BOOL displaysCapturedForFullscreen,beenActive;
 BOOL modesAvailable;
 unsigned adjustments,foregroundTransforms;
}
- (BOOL)mode:(FixtureMode*)a matchesMode:(FixtureMode*)b;
- (NSArray*)modesMatchingMode:(FixtureMode*)mode forDisplay:(CGDirectDisplayID)display;
- (void)transformProcessToForeground:(BOOL)yes;
- (void)adjustWindowLevels;
- (BOOL)setMode:(FixtureMode*)mode forDisplay:(CGDirectDisplayID)displayID;
@end
@implementation Controller
- (BOOL)mode:(FixtureMode*)a matchesMode:(FixtureMode*)b{return a&&b&&a.token==b.token;}
- (NSArray*)modesMatchingMode:(FixtureMode*)mode forDisplay:(CGDirectDisplayID)display{(void)display;return modesAvailable?@[mode]:@[];}
- (void)transformProcessToForeground:(BOOL)yes{(void)yes;foregroundTransforms++;}
- (void)adjustWindowLevels{adjustments++;}
__METHOD__
@end
static Controller*fresh(const char*name,BOOL active,BOOL hadActivation){
 select_process(name);fixture_app.active=active;physical_mode=desktop_mode;captured=NO;
 capture_calls=set_calls=restore_calls=release_calls=0;capture_result=set_result=0;
 Controller*c=[Controller new];c->originalDisplayModes=[NSMutableDictionary new];c->latentDisplayModes=[NSMutableDictionary new];
 c->beenActive=hadActivation;c->modesAvailable=YES;return c;
}
int main(void){@autoreleasepool{
 desktop_mode=[FixtureMode new];desktop_mode.token=1;game_mode=[FixtureMode new];game_mode.token=2;
 fixture_app=[FakeApplication new];
 const struct{const char*name;BOOL match;}names[]={
  {"Diablo III64.exe",YES},{"C:\\Games\\Diablo III64.EXE",YES},{"c:/games/diablo iii64.exe",YES},
  {"Battle.net.exe",NO},{"Battle.net Launcher.exe",NO},{"Overwatch.exe",NO},
  {"xDiablo III64.exe",NO},{"Diablo III64.exe.bak",NO},{"DiabloIII64.exe",NO}
 };
 for(unsigned i=0;i<sizeof(names)/sizeof(names[0]);i++){select_process(names[i].name);check(diablo_eager_initial_mode==names[i].match,"exact case-insensitive executable scope");}

 Controller*c=fresh("Diablo III64.exe",NO,NO);
 BOOL result=[c setMode:game_mode forDisplay:1];
 // This assertion executes immediately after the actual method returns, before
 // any simulated activation or display notification is allowed to run.
 check(result,"initial fullscreen request reports success");
 if(__EAGER__){
  check(physical_mode==game_mode,"physical game mode realized BEFORE initial inactive call returns");
  check(capture_calls==1&&set_calls==1&&captured,"startup uses ordinary synchronous capture and mode-set branch");
  check(c->originalDisplayModes.count==1&&c->latentDisplayModes.count==0,"initial real switch records original mode, no latent request");
  check(c->originalDisplayModes[@1]==desktop_mode,"restore record retains pre-switch desktop mode");
  check(c->adjustments==1,"successful eager switch preserves window-level adjustment");
  fixture_app.active=YES;c->beenActive=YES;
  unsigned sets=set_calls,captures=capture_calls;
  check([c setMode:game_mode forDisplay:1]&&set_calls==sets&&capture_calls==captures,"first activation cannot repeat already realized mode");
  fixture_app.active=NO;
  check([c setMode:desktop_mode forDisplay:1],"restoring original mode succeeds");
  check(physical_mode==desktop_mode&&!captured&&restore_calls==1&&release_calls==1&&c->originalDisplayModes.count==0,"original restore releases capture and bookkeeping");
  check([c setMode:game_mode forDisplay:1]&&physical_mode==desktop_mode&&c->latentDisplayModes.count==1,"after first activation, background changes defer normally");
 }else{
  check(physical_mode==desktop_mode&&capture_calls==0&&set_calls==0,"baseline returns success while physical desktop mode remains unchanged");
  check(c->latentDisplayModes.count==1&&c->originalDisplayModes.count==0,"baseline queues initial inactive request");
 }

 // A new game process repeats the same startup ordering independently.
 c=fresh("C:/Games/Diablo III64.exe",NO,NO);result=[c setMode:game_mode forDisplay:1];
 check(result&&physical_mode==(__EAGER__?game_mode:desktop_mode),"fresh second game process retains startup behavior");
 // Other apps and a Diablo process the user already switched away from defer.
 const char*other[]={"Battle.net.exe","Overwatch.exe"};
 for(unsigned i=0;i<2;i++){
  c=fresh(other[i],NO,NO);result=[c setMode:game_mode forDisplay:1];
  check(result&&physical_mode==desktop_mode&&c->latentDisplayModes.count==1&&capture_calls==0,"other inactive applications preserve deferred path");
 }
 c=fresh("Diablo III64.exe",NO,YES);result=[c setMode:game_mode forDisplay:1];
 check(result&&physical_mode==desktop_mode&&c->latentDisplayModes.count==1&&capture_calls==0,"previously active Diablo preserves background deferral");
 // Any genuinely active application keeps the old synchronous behavior.
 const char*all[]={"Diablo III64.exe","Battle.net.exe","Overwatch.exe"};
 for(unsigned i=0;i<3;i++){
  c=fresh(all[i],YES,YES);result=[c setMode:game_mode forDisplay:1];
  check(result&&physical_mode==game_mode&&capture_calls==1&&set_calls==1,"active applications retain original actual switch behavior");
  check([c setMode:desktop_mode forDisplay:1]&&!captured&&physical_mode==desktop_mode,"active application original-mode restore retained");
 }
 // Failure handling is exercised on the real path: eager inactive Diablo for
 // the candidate, active Diablo for the unchanged baseline.
 c=fresh("Diablo III64.exe",__EAGER__?NO:YES,NO);capture_result=1;
 check(![c setMode:game_mode forDisplay:1],"capture failure propagates failure");
 check(physical_mode==desktop_mode&&!captured&&set_calls==0&&c->originalDisplayModes.count==0&&c->latentDisplayModes.count==0,"capture failure leaves no false deferred success or ownership");
 c=fresh("Diablo III64.exe",__EAGER__?NO:YES,NO);set_result=1;
 check(![c setMode:game_mode forDisplay:1],"mode-set failure propagates failure");
 check(physical_mode==desktop_mode&&!captured&&restore_calls==1&&release_calls==1&&c->originalDisplayModes.count==0,"mode-set failure restores desktop and releases capture");
 c=fresh("Diablo III64.exe",__EAGER__?NO:YES,NO);c->modesAvailable=NO;
 check(![c setMode:game_mode forDisplay:1]&&capture_calls==0&&physical_mode==desktop_mode,"unsupported mode fails before capture");
 c=fresh("Diablo III64.exe",NO,NO);
 check([c setMode:desktop_mode forDisplay:1]&&capture_calls==0&&set_calls==0&&c->latentDisplayModes.count==0,"already-current mode is an unchanged no-op");
 printf("PASS: %u %s full-method assertions\n",assertions,__EAGER__?"eager-initial":"pristine baseline");return 0;
}}
'''

class EagerInitialMode(unittest.TestCase):
    def test_set_mode_hunk_changes_only_initial_activity_predicate(self):
        found = [hunk for hunk in hunks(COCOA_APP) if PREDICATE in ''.join(hunk['after'])]
        self.assertEqual(len(found), 1)
        hunk = found[0]
        self.assertIn(SET_MODE, hunk['header'])
        after, before = ''.join(hunk['after']), ''.join(hunk['before'])
        self.assertEqual(after.count(PREDICATE), 1)
        self.assertEqual(normalized(after.replace(PREDICATE, '')), normalized(before))
        main = patch_image(MACDRV_MAIN)
        self.assertEqual(main.count('bool diablo_eager_initial_mode = false;'), 1)
        self.assertIn('extern bool diablo_eager_initial_mode;',
                      patch_image('dlls/winemac.drv/macdrv_cocoa.h'))
        self.assertIn('static void setup_options(void)', main)

    def test_set_mode_method_changes_only_initial_activity_predicate(self):
        method = production_method()
        self.assertEqual(method.count(PREDICATE), 1)
        self.assertEqual(normalized(method.replace(PREDICATE, '')),
                         normalized(production_method(after=False)))

    def test_patch_hashes_match_build_and_source_manifest(self):
        digest = hashlib.sha256(PATCH.read_bytes()).hexdigest()
        manifest = json.loads(SOURCES.read_text())
        self.assertEqual(next(p['sha256'] for p in manifest['sources']['wine']['v1_patches']
                              if p['patch'] == 'patches/' + PATCH.name), digest)
        self.assertEqual(next(p['sha256'] for p in manifest['patches']
                              if p['path'] == 'patches/' + PATCH.name), digest)
        recipe = ast.parse((ROOT / 'scripts/build_portable_runtime.py').read_text())
        pins = next(ast.literal_eval(node.value) for node in recipe.body
                    if isinstance(node, ast.Assign) and any(
                        isinstance(target, ast.Name) and target.id == 'V1_PATCHES'
                        for target in node.targets))
        self.assertEqual(pins[PATCH.name], digest)

    @unittest.skipUnless(sys.platform == 'darwin', 'Objective-C fixture needs macOS AppKit')
    def test_initial_mode_and_lifecycle(self):
        self.run_method(after=True)

    @unittest.skipUnless(sys.platform == 'darwin', 'Objective-C fixture needs macOS AppKit')
    def test_before_patch_inactive_success_is_deferred(self):
        self.run_method(after=False)

    def run_method(self, after):
        text = (HARNESS.replace('__SCOPE__', process_scope())
                .replace('__METHOD__', production_method(after))
                .replace('__EAGER__', '1' if after else '0'))
        with tempfile.TemporaryDirectory(prefix='recall-eager-mode-') as tmp:
            unit, binary = Path(tmp) / 'mode.m', Path(tmp) / 'mode'
            unit.write_text(text)
            built = subprocess.run([
                '/usr/bin/clang', '-fno-objc-arc', '-Wall', '-Wextra', '-Werror',
                '-framework', 'AppKit', str(unit), '-o', str(binary)],
                capture_output=True, text=True, timeout=45)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            result = subprocess.run([str(binary)], capture_output=True,
                                    text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout.strip())


if __name__ == '__main__':
    unittest.main()
