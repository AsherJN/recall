/* Test-only driver of our own named graphics fixture. Never installed in the
 * game engine. Exercises actual NSWindow fullscreen/focus methods in-process. */
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#include <unistd.h>
#include "cocoa_event.h"

static NSString *folder;
static unsigned expectedClicks;
static void capture(NSWindow *window, NSString *event) {
    NSMutableArray *views = [NSMutableArray array];
    NSMutableArray *layers = [NSMutableArray array];
    for (NSView *view in window.contentView.subviews) {
        NSRect shown = [view convertRect:view.bounds toView:nil];
        for (NSView *child in view.subviews) if ([child.layer isKindOfClass:CAMetalLayer.class]) {
            CAMetalLayer *layer=(CAMetalLayer *)child.layer;
            [layers addObject:@{@"drawable":@[@(layer.drawableSize.width),@(layer.drawableSize.height)],
                                @"maximum_drawables":@(layer.maximumDrawableCount)}];
        }
        [views addObject:@{ @"class":NSStringFromClass(view.class),
            @"frame":NSStringFromRect(view.frame), @"bounds":NSStringFromRect(view.bounds),
            @"shown":NSStringFromRect(shown) }];
    }
    // The overlay presentation window (a child window) hosts the metal view while fullscreen.
    NSMutableArray *overlays = [NSMutableArray array];
    for (NSWindow *child in NSApp.windows) {
        if (![NSStringFromClass(child.class) isEqualToString:@"OWOverlayWindow"]) continue;
        for (NSView *view in child.contentView.subviews) if ([view.layer isKindOfClass:CAMetalLayer.class]) {
            CAMetalLayer *layer=(CAMetalLayer *)view.layer;
            NSRect shown = [view convertRect:view.bounds toView:nil];
            [layers addObject:@{@"drawable":@[@(layer.drawableSize.width),@(layer.drawableSize.height)],
                                @"maximum_drawables":@(layer.maximumDrawableCount), @"overlay":@YES}];
            [overlays addObject:@{ @"class":NSStringFromClass(child.class), @"frame":NSStringFromRect(child.frame),
                @"view_frame":NSStringFromRect(view.frame), @"shown":NSStringFromRect(shown),
                @"ignores_mouse":@(child.ignoresMouseEvents), @"key":@(child.isKeyWindow), @"visible":@(child.isVisible),
                @"contents_scale":@(layer.contentsScale), @"level":@(child.level), @"on_screen":@(child.isOnActiveSpace) }];
        }
    }
    NSDictionary *record = @{ @"event":event, @"unix_s":@(NSDate.date.timeIntervalSince1970),
        @"fullscreen":@((window.styleMask & NSWindowStyleMaskFullScreen)!=0), @"window_number":@(window.windowNumber),
        @"frame":NSStringFromRect(window.frame), @"root_frame":NSStringFromRect(window.contentView.frame),
        @"root_bounds":NSStringFromRect(window.contentView.bounds), @"views":views, @"layers":layers,
        @"overlays":overlays, @"key_window":@(window.isKeyWindow) };
    NSData *data=[NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    FILE *file=fopen([[folder stringByAppendingPathComponent:@"native-fixture.jsonl"] fileSystemRepresentation],"a");
    if(file) { fwrite(data.bytes,1,data.length,file); fputc('\n',file); fclose(file); }
    NSView *client=window.contentView.subviews.firstObject;
    for(NSNumber *fraction in @[@.1,@.5,@.9]) {
        double t=fraction.doubleValue;
        NSPoint location=[client convertPoint:NSMakePoint(client.bounds.size.width*t,client.bounds.size.height*t) toView:nil];
        // Feed physical screen coordinates into the actual Wine event queue;
        // the production mapping must deliver logical Win32 client clicks.
        NSPoint screen=[window convertPointToScreen:location];
        double desktopHeight=NSScreen.screens.firstObject.frame.size.height;
        for(unsigned pressed=1;;pressed=0) {
            macdrv_event *mouse=calloc(1,sizeof(*mouse));
            mouse->refs=1; mouse->deliver=INT_MAX; mouse->type=MOUSE_BUTTON;
            mouse->window=(macdrv_window)[window retain];
            mouse->mouse_button.button=0; mouse->mouse_button.pressed=pressed;
            mouse->mouse_button.x=llround(screen.x*2);
            mouse->mouse_button.y=llround((desktopHeight-screen.y)*2);
            mouse->mouse_button.time_ms=NSProcessInfo.processInfo.systemUptime*1000;
            [(WineEventQueue *)[window valueForKey:@"queue"] postEvent:mouse];
            if(__sync_sub_and_fetch(&mouse->refs,1)==0) {[(id)mouse->window release];free(mouse);}
            if(!pressed) break;
        }
    }
    if ([event isEqualToString:@"fullscreen_refocused"]) {
        NSPoint center=[client convertPoint:NSMakePoint(client.bounds.size.width*.5,client.bounds.size.height*.5) toView:nil];
        center=[window convertPointToScreen:center];
        [(WineEventQueue *)[window valueForKey:@"queue"] resetMouseEventPositions:
            CGPointMake(center.x,NSScreen.screens.firstObject.frame.size.height-center.y)];
    }
    expectedClicks += 3;
    [[NSString stringWithFormat:@"cursor:%u",expectedClicks] writeToFile:[folder stringByAppendingPathComponent:@"checkpoints.command"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static void later(double seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(seconds*NSEC_PER_SEC)),dispatch_get_main_queue(),block);
}
static void switchMode(NSWindow *window, BOOL enabled) {
    if (!getenv("DXMT_V1_GAME_FULLSCREEN")) { [window toggleFullScreen:nil]; return; }
    [(enabled ? @"fullscreen_on" : @"fullscreen_off")
        writeToFile:[folder stringByAppendingPathComponent:@"checkpoints.command"]
        atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
static void awaitWindow(unsigned attempts) {
    for(NSWindow *window in NSApp.windows) {
        if(![window.title isEqualToString:@"DXMT shader render diagnostic"]) continue;
        [window retain];
        if (getenv("DXMT_V1_FOCUS_RECOVERY")) {
            later(3, ^{ capture(window,@"windowed_start"); later(.5,^{switchMode(window,YES);}); });
            later(7, ^{ capture(window,@"fullscreen_first"); });
            // Overwatch changes DXGI fullscreen state when focus changes. The
            // old fixture hid/unhid without those requests and missed the bug.
            for (unsigned cycle=0; cycle<3; ++cycle) {
                double began=8+cycle*7;
                later(began, ^{ [NSApp hide:nil]; later(.05,^{switchMode(window,NO);}); });
                later(began+2, ^{ [NSApp unhide:nil]; [window makeKeyAndOrderFront:nil];
                    later(.05,^{switchMode(window,YES);}); });
                later(began+5, ^{ capture(window,[NSString stringWithFormat:@"fullscreen_refocused_%u",cycle+1]); });
            }
            later(28, ^{ switchMode(window,NO); });
            later(31, ^{ capture(window,@"windowed_final"); });
            later(34, ^{ [@"finish" writeToFile:[folder stringByAppendingPathComponent:@"checkpoints.command"] atomically:YES encoding:NSUTF8StringEncoding error:nil]; [window release]; });
            return;
        }
        later(3, ^{ capture(window,@"windowed_start"); later(.5,^{switchMode(window,YES);}); });
        later(7, ^{ capture(window,@"fullscreen_first"); });
        later(10, ^{ switchMode(window,NO); });
        later(13, ^{ capture(window,@"windowed_return"); later(.5,^{switchMode(window,YES);}); });
        later(17, ^{ capture(window,@"fullscreen_second"); later(.5,^{[NSApp hide:nil];}); });
        later(19, ^{ [NSApp unhide:nil]; [window makeKeyAndOrderFront:nil]; });
        later(22, ^{ capture(window,@"fullscreen_refocused"); later(.5,^{switchMode(window,NO);}); });
        later(25, ^{ capture(window,@"windowed_final"); });
        later(28, ^{ [@"finish" writeToFile:[folder stringByAppendingPathComponent:@"checkpoints.command"] atomically:YES encoding:NSUTF8StringEncoding error:nil]; [window release]; });
        return;
    }
    if(attempts) later(.5, ^{awaitWindow(attempts-1);});
}
__attribute__((constructor)) static void startFixture(void) {
    const char *path=getenv("DXMT_V1_OWNED_FIXTURE");
    if(!path) return;
    folder=[[NSString alloc] initWithUTF8String:path];
    later(2, ^{awaitWindow(120);});
}
