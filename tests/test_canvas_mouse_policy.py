"""Exercise the real canvas mouse policy from the tracked Wine patch, without a game.

The Objective-C methods are extracted from added patch lines, not copied into the
fixture. AppKit supplies types only; fake app/event/window objects never open UI.
"""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

PATCH = Path(__file__).resolve().parents[1] / 'patches' / 'wine-winemac-activation.patch'
METHODS = ('consumeCanvasMouseButton', 'ownsCanvasMouseDrag')


def production_methods():
    target = False
    added = []
    for line in PATCH.read_text().splitlines():
        if line.startswith('+++ '):
            target = line.split()[1] == 'b/dlls/winemac.drv/cocoa_window.m'
        elif line.startswith('--- '):
            target = False
        elif target and line.startswith('+'):
            added.append(line[1:])
    source = '\n'.join(added)
    methods = []
    for name in METHODS:
        starts = list(re.finditer(r'(?m)^ *- \(BOOL\) ' + name + ':', source))
        if len(starts) != 1:
            raise AssertionError(f'Expected exactly one added {name} implementation, found {len(starts)}')
        start = starts[0].start()
        brace = source.index('{', start)
        depth = 1
        end = brace + 1
        while depth and end < len(source):
            depth += (source[end] == '{') - (source[end] == '}')
            end += 1
        if depth:
            raise AssertionError(f'Incomplete production method: {name}')
        methods.append(source[start:end])
    return methods


HARNESS = r'''
#import <AppKit/AppKit.h>
#include <stdio.h>
#include <stdlib.h>
@interface NSEvent (WineTestDeclaration)
- (BOOL)wine_commandKeyDown;
@end
@interface FakeEvent : NSObject
@property NSInteger buttonNumber;
@property NSEventType type;
@property BOOL command;
- (BOOL)wine_commandKeyDown;
@end
@implementation FakeEvent
- (BOOL)wine_commandKeyDown { return self.command; }
@end
@interface FakeApplication : NSObject
@property BOOL active;
- (BOOL)isActive;
@end
@implementation FakeApplication
- (BOOL)isActive { return self.active; }
@end
static FakeApplication *testApp;
#define NSApp testApp
@interface WineWindow : NSObject {
@public
    NSUInteger canvasConsumedButtons;
    BOOL testKey;
    BOOL testOwnsFrame;
}
- (BOOL)isKeyWindow;
__PROTOTYPES__
@end
static BOOL macdrv_v1_canvas_owns_frame(WineWindow *window) { return window->testOwnsFrame; }
@implementation WineWindow
- (BOOL)isKeyWindow { return testKey; }
__METHODS__
@end
static unsigned assertions;
static void check(BOOL value,const char *message) {
    ++assertions;
    if(!value){fprintf(stderr,"FAIL: %s\n",message);exit(1);}
}
static WineWindow *fresh(void) {
    WineWindow *w=[WineWindow new];w->testKey=YES;w->testOwnsFrame=YES;testApp.active=YES;return w;
}
static NSEvent *event(NSEventType type,NSInteger button,BOOL command) {
    FakeEvent *e=[FakeEvent new];e.type=type;e.buttonNumber=button;e.command=command;return (NSEvent *)e;
}
static BOOL down(WineWindow *w,NSInteger button,BOOL delivered,BOOL command) {
    NSEventType type=button==0?NSEventTypeLeftMouseDown:button==1?NSEventTypeRightMouseDown:NSEventTypeOtherMouseDown;
    return [w consumeCanvasMouseButton:event(type,button,command) delivered:delivered];
}
static BOOL up(WineWindow *w,NSInteger button,BOOL delivered,BOOL command) {
    NSEventType type=button==0?NSEventTypeLeftMouseUp:button==1?NSEventTypeRightMouseUp:NSEventTypeOtherMouseUp;
    return [w consumeCanvasMouseButton:event(type,button,command) delivered:delivered];
}
static BOOL drag(WineWindow *w,NSInteger button,BOOL command) {
    NSEventType type=button==0?NSEventTypeLeftMouseDragged:button==1?NSEventTypeRightMouseDragged:NSEventTypeOtherMouseDragged;
    return [w ownsCanvasMouseDrag:event(type,button,command)];
}
int main(void) { @autoreleasepool {
    testApp=[FakeApplication new];
    // Full pairs: drags do not clear ownership; releases do, once, for each button family.
    for(NSInteger b=0;b<3;b++) {
        WineWindow *w=fresh();
        check(!drag(w,b,NO),"unowned drag remains native");
        check(!up(w,b,YES,NO),"unmatched release remains native");
        check(down(w,b,YES,NO),"eligible press is consumed");
        check(drag(w,b,NO),"owned drag is consumed");
        check(drag(w,b,NO),"repeated drag retains ownership");
        check(up(w,b,YES,NO),"matching release is consumed");
        check(!drag(w,b,NO),"release clears drag ownership");
        check(!up(w,b,YES,NO),"duplicate release remains native");
    }
    // Rejection gates: background app, non-key/first click, native/windowed transition,
    // Command modifier, and no Wine delivery (titlebar/grow box/raw duplicate/redirect).
    for(unsigned gate=0;gate<5;gate++) {
        WineWindow *w=fresh();BOOL delivered=YES,command=NO;
        if(gate==0)testApp.active=NO;
        if(gate==1)w->testKey=NO;
        if(gate==2)w->testOwnsFrame=NO;
        if(gate==3)command=YES;
        if(gate==4)delivered=NO;
        check(!down(w,0,delivered,command),"ineligible press remains native");
        check(!drag(w,0,command),"rejected press owns no drag");
        check(!up(w,0,YES,command),"rejected press owns no release");
    }
    // Abandoned old pair must not eat a later ineligible gesture's release.
    for(unsigned gate=0;gate<5;gate++) {
        WineWindow *w=fresh();BOOL delivered=YES,command=NO;
        check(down(w,0,YES,NO),"old press is owned");
        if(gate==0)testApp.active=NO;
        if(gate==1)w->testKey=NO;
        if(gate==2)w->testOwnsFrame=NO;
        if(gate==3)command=YES;
        if(gate==4)delivered=NO;
        check(!down(w,0,delivered,command),"new rejected press resets stale ownership");
        check(!drag(w,0,command),"stale sequence no longer owns drag");
        check(!up(w,0,YES,command),"new native press keeps its release");
    }
    // Accepted sequence remains owned after fullscreen exit/focus loss/Cmd changes.
    {
        WineWindow *w=fresh();check(down(w,0,YES,NO),"press before fullscreen exit");
        testApp.active=NO;w->testKey=NO;w->testOwnsFrame=NO;
        check(drag(w,0,YES),"owned drag survives changed eligibility");
        check(up(w,0,NO,YES),"owned release survives changed eligibility/delivery");
        check(!up(w,0,NO,YES),"changed-eligibility release clears state");
    }
    // Buttons and windows are independent; releasing one cannot release another.
    {
        WineWindow *a=fresh(),*b=fresh();
        check(down(a,0,YES,NO),"own left");check(down(a,1,YES,NO),"own right");
        check(down(a,4,YES,NO),"own extra button");
        check(!drag(b,0,NO)&&!up(b,0,YES,NO),"ownership is per window");
        check(up(a,1,YES,NO),"release right");
        check(drag(a,0,NO)&&drag(a,4,NO),"other buttons remain owned");
        check(!drag(a,1,NO),"released right no longer owned");
        check(up(a,0,YES,NO)&&up(a,4,YES,NO),"release remaining buttons");
        check(a->canvasConsumedButtons==0,"all owned buttons cleared");
    }
    // New native left press clears only the abandoned left bit, preserving right.
    {
        WineWindow *w=fresh();check(down(w,0,YES,NO)&&down(w,1,YES,NO),"two presses owned");
        check(!down(w,0,YES,YES),"new Cmd-left remains native");
        check(!up(w,0,YES,NO),"Cmd-left release remains native");
        check(drag(w,1,NO)&&up(w,1,YES,NO),"right sequence unaffected");
    }
    // Bounds checks prevent negative/oversized shifts and preserve an existing pair.
    {
        WineWindow *w=fresh();check(down(w,0,YES,NO),"valid sequence for range tests");
        NSInteger bad[]={-1,(NSInteger)(sizeof(NSUInteger)*8),1000};
        for(unsigned i=0;i<sizeof(bad)/sizeof(bad[0]);i++) {
            check(!down(w,bad[i],YES,NO),"invalid press rejected");
            check(!drag(w,bad[i],NO),"invalid drag rejected");
            check(!up(w,bad[i],YES,NO),"invalid release rejected");
        }
        check(up(w,0,YES,NO),"invalid button did not corrupt valid state");
    }
    printf("PASS: %u assertions against extracted production method bodies\n",assertions);
    return 0;
} }
'''


class CanvasMousePolicy(unittest.TestCase):
    def test_production_methods_are_available(self):
        self.assertEqual(len(production_methods()), len(METHODS))

    @unittest.skipUnless(sys.platform == 'darwin', 'Objective-C policy harness requires macOS AppKit')
    def test_native_button_ownership(self):
        clang = shutil.which('clang')
        if not clang:
            self.skipTest('clang is required for the native policy harness')
        methods = production_methods()
        prototypes = '\n'.join(m.split('{', 1)[0].strip() + ';' for m in methods)
        source = HARNESS.replace('__PROTOTYPES__', prototypes).replace('__METHODS__', '\n'.join(methods))
        with tempfile.TemporaryDirectory(prefix='recall-canvas-policy-') as directory:
            path = Path(directory) / 'policy.m'
            binary = Path(directory) / 'policy'
            path.write_text(source)
            compile_result = subprocess.run(
                [clang, '-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-framework', 'AppKit',
                 str(path), '-o', str(binary)],
                capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(compile_result.returncode, 0, compile_result.stdout + compile_result.stderr)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn('PASS: 87 assertions', result.stdout)


if __name__ == '__main__':
    unittest.main()
