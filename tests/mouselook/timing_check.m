// Mouse timing check: what Recall's raw input path depends on, measured outside
// the game with the pointer frozen as in game.
//
//   1. Aim and click (30 s). How many reports a second the mouse sends through
//      GCMouse (the Game Controller framework, Recall's source of motion), and
//      for every click, when it arrives through GCMouse and when it arrives as an
//      AppKit mouse event (Recall's source of clicks today).
//   2. Switch apps. Command-Tab away and back three times, moving the mouse after
//      each return: does GCMouse motion resume?
//
// Records only; timing_check.py analyses. Writes events.csv, marks.csv and
// context.json to --out. Records mouse motion and buttons, never keys.

#import <Cocoa/Cocoa.h>
#import <GameController/GameController.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <sys/sysctl.h>

enum { FEED_GAME, FEED_APP, FEED_COUNT };          /* GCMouse queue, AppKit main thread */
enum { KIND_MOVE, KIND_DOWN, KIND_UP };
enum { PHASE_IDLE, PHASE_CLICKS, PHASE_SWITCH };
enum { CLICK_SECONDS = 30, SWITCH_SECONDS = 90, RETURNS = 3 };
static const char *feed_names[FEED_COUNT] = { "game", "app" };
static const char *kind_names[] = { "move", "down", "up" };
static const size_t capacity = 1 << 21;            /* per feed: 8,000 a second for over 4 minutes */

typedef struct {
    uint64_t recv;       /* mach_absolute_time in ns when this process received it */
    uint64_t recv_cont;  /* mach_continuous_time in ns at the same moment */
    double stamp;        /* the source's own timestamp, seconds: NSEvent.timestamp or GCMouse lastEventTimestamp */
    float dx, dy;
    uint16_t source;     /* GCMouse index; 0 for AppKit */
    uint8_t kind, button, phase, active;
} event_t;

typedef struct { uint64_t at; char what[24]; int value; } mark_t;

static event_t *events[FEED_COUNT];
static _Atomic size_t counts[FEED_COUNT];
static mark_t marks[4096];
static size_t mark_count;                          /* main thread only */
static atomic_bool recording;
static atomic_int phase;
static atomic_bool active;
static mach_timebase_info_data_t timebase;
static dispatch_queue_t game_queue;
static NSMutableArray<GCMouse *> *mice;
static NSMutableArray<NSString *> *mouse_names;
static NSMutableArray *mouse_inputs;               /* the GCMouseInput each handler was set on */

static uint64_t ns_from_ticks(uint64_t ticks) { return ticks * timebase.numer / timebase.denom; }
static uint64_t now_ns(void) { return ns_from_ticks(mach_absolute_time()); }

/* One producer per feed: the GCMouse handler queue or the main thread. */
static void record(int feed, int kind, int button, double dx, double dy, double stamp, unsigned source)
{
    if (!atomic_load_explicit(&recording, memory_order_acquire)) return;
    uint64_t recv = mach_absolute_time(), recv_cont = mach_continuous_time();
    size_t n = atomic_load_explicit(&counts[feed], memory_order_relaxed);
    if (n == capacity) return;
    events[feed][n] = (event_t){ ns_from_ticks(recv), ns_from_ticks(recv_cont), stamp, (float)dx, (float)dy,
                                 (uint16_t)source, (uint8_t)kind, (uint8_t)button,
                                 (uint8_t)atomic_load(&phase), (uint8_t)atomic_load(&active) };
    atomic_store_explicit(&counts[feed], n + 1, memory_order_release);
}

static void mark(const char *what, int value)
{
    if (mark_count == sizeof(marks) / sizeof(marks[0])) return;
    mark_t *m = &marks[mark_count++];
    m->at = now_ns();
    strlcpy(m->what, what, sizeof(m->what));
    m->value = value;
}

static NSString *mouse_name(GCMouse *mouse) { return mouse.vendorName ?: mouse.productCategory ?: @"mouse"; }

/* Motion and buttons both come through the mouse's handler queue, in report order. */
static void attach(GCMouse *mouse)
{
    if ([mice containsObject:mouse]) {
        /* Same object again: note whether its input profile was replaced. */
        NSUInteger i = [mice indexOfObject:mouse];
        mark("reattach", (int)i);
        if (mouse.mouseInput != mouse_inputs[i]) mark("input_replaced", (int)i);
        return;
    }
    unsigned source = (unsigned)mice.count;
    [mice addObject:mouse];
    [mouse_names addObject:mouse_name(mouse)];
    GCMouseInput *input = mouse.mouseInput;
    [mouse_inputs addObject:input ?: NSNull.null];
    mark("attach", (int)source);
    mouse.handlerQueue = game_queue;
    __weak GCMouseInput *weak = input;
    input.mouseMovedHandler = ^(GCMouseInput *in, float dx, float dy) {
        if (dx != 0 || dy != 0) record(FEED_GAME, KIND_MOVE, 0, dx, dy, in.lastEventTimestamp, source);
    };
    void (^hook)(GCControllerButtonInput *, int) = ^(GCControllerButtonInput *button, int number) {
        button.pressedChangedHandler = ^(GCControllerButtonInput *b, float value, BOOL pressed) {
            record(FEED_GAME, pressed ? KIND_DOWN : KIND_UP, number, 0, 0, weak.lastEventTimestamp, source);
        };
    };
    if (input.leftButton) hook(input.leftButton, 0);
    if (input.rightButton) hook(input.rightButton, 1);
    if (input.middleButton) hook(input.middleButton, 2);
    int number = 3;
    for (GCControllerButtonInput *aux in input.auxiliaryButtons) hook(aux, number++);
}

static NSDictionary *system_info(void)
{
    char model[64] = "";
    size_t size = sizeof(model);
    sysctlbyname("hw.model", model, &size, NULL, 0);
    id speed = CFBridgingRelease(CFPreferencesCopyValue(CFSTR("com.apple.mouse.scaling"), kCFPreferencesAnyApplication,
                                                        kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    return @{ @"macos": NSProcessInfo.processInfo.operatingSystemVersionString, @"model": @(model),
              @"display_max_fps": @(NSScreen.mainScreen.maximumFramesPerSecond),
              @"tracking_speed": speed ?: NSNull.null,
              @"uptime_s": @(NSProcessInfo.processInfo.systemUptime),
              @"mach_ns": @(now_ns()), @"mach_cont_ns": @(ns_from_ticks(mach_continuous_time())) };
}

static void write_json(id object, NSString *path)
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:NULL];
    if (path) [data writeToFile:path atomically:YES];
    else fwrite(data.bytes, 1, data.length, stdout), fputc('\n', stdout);
}

static void write_events(NSString *dir)
{
    FILE *out = fopen([dir stringByAppendingPathComponent:@"events.csv"].fileSystemRepresentation, "w");
    if (!out) return;
    fprintf(out, "feed,kind,button,source,phase,active,recv_ns,recv_cont_ns,stamp_s,dx,dy\n");
    for (int f = 0; f < FEED_COUNT; f++) {
        size_t n = atomic_load(&counts[f]);
        for (size_t i = 0; i < n; i++) {
            const event_t *e = &events[f][i];
            fprintf(out, "%s,%s,%u,%u,%u,%u,%llu,%llu,%.9f,%g,%g\n", feed_names[f], kind_names[e->kind], e->button,
                    e->source, e->phase, e->active, e->recv, e->recv_cont, e->stamp, e->dx, e->dy);
        }
    }
    fclose(out);
    out = fopen([dir stringByAppendingPathComponent:@"marks.csv"].fileSystemRepresentation, "w");
    if (!out) return;
    fprintf(out, "at_ns,what,value\n");
    for (size_t i = 0; i < mark_count; i++) fprintf(out, "%llu,%s,%d\n", marks[i].at, marks[i].what, marks[i].value);
    fclose(out);
}

static NSTextField *text(NSString *string, CGFloat size, NSFontWeight weight)
{
    NSTextField *field = [NSTextField wrappingLabelWithString:string];
    field.font = [NSFont systemFontOfSize:size weight:weight];
    field.preferredMaxLayoutWidth = 520;
    return field;
}

@interface Check : NSObject <NSApplicationDelegate, NSWindowDelegate>
@end

@implementation Check {
    NSString *outDir;
    NSWindow *window;
    NSTextField *heading, *instructions, *status;
    NSProgressIndicator *progress;
    NSButton *button;
    uint64_t started, switchStarted, lastReturn;
    int returns;
    BOOL frozen;
}

- (instancetype)initWithOutput:(NSString *)output
{
    if ((self = [super init])) outDir = output;
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    NSMenu *menu = [NSMenu new], *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"Quit Mouse Timing Check" action:@selector(terminate:) keyEquivalent:@"q"];
    [menu addItemWithTitle:@"" action:NULL keyEquivalent:@""].submenu = appMenu;
    NSApp.mainMenu = menu;

    /* As Recall's driver does: a serial queue at user-interactive priority. */
    game_queue = dispatch_queue_create("mouse-timing-check.game",
                                       dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    for (GCMouse *mouse in GCMouse.mice) attach(mouse);
    [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidConnectNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { attach(n.object); }];
    [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) {
        NSUInteger i = [mice indexOfObject:n.object];
        mark("detach", i == NSNotFound ? -1 : (int)i);
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidBecomeCurrentNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) {
        NSUInteger i = [mice indexOfObject:n.object];
        mark("current", i == NSNotFound ? -1 : (int)i);
    }];

    NSEventMask clicks = NSEventMaskLeftMouseDown | NSEventMaskLeftMouseUp | NSEventMaskRightMouseDown |
                         NSEventMaskRightMouseUp | NSEventMaskOtherMouseDown | NSEventMaskOtherMouseUp;
    [NSEvent addLocalMonitorForEventsMatchingMask:clicks handler:^NSEvent *(NSEvent *event) {
        BOOL down = event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeRightMouseDown ||
                    event.type == NSEventTypeOtherMouseDown;
        record(FEED_APP, down ? KIND_DOWN : KIND_UP, (int)event.buttonNumber, 0, 0, event.timestamp, 0);
        return event;
    }];
    NSEventMask moves = NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged | NSEventMaskRightMouseDragged |
                        NSEventMaskOtherMouseDragged;
    [NSEvent addLocalMonitorForEventsMatchingMask:moves handler:^NSEvent *(NSEvent *event) {
        if (event.deltaX != 0 || event.deltaY != 0)
            record(FEED_APP, KIND_MOVE, 0, event.deltaX, event.deltaY, event.timestamp, 0);
        return event;
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        if (event.keyCode != 53 || atomic_load(&phase) == PHASE_IDLE) return event; /* Esc */
        [self finish:NO];
        return nil;
    }];

    [self buildWindow];
    [window center];
    [window makeKeyAndOrderFront:nil];
    [NSTimer scheduledTimerWithTimeInterval:0.25 target:self selector:@selector(tick:) userInfo:nil repeats:YES];
    [NSApp activate];
}

- (void)buildWindow
{
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 568, 420)
                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                           backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Mouse Timing Check";
    window.delegate = self;
    window.releasedWhenClosed = NO;
    window.acceptsMouseMovedEvents = YES;
    heading = text(@"Two short steps, about two minutes in all.", 15, NSFontWeightSemibold);
    instructions = text(@"Step 1 (30 seconds): aim and click. The pointer disappears, as in game. Swipe the mouse "
                        @"quickly left and right, like flicking between targets, and click during each swipe. "
                        @"Mix in a few right clicks and a few clicks while holding still.\n\n"
                        @"Step 2: switch apps. When asked, press Command-Tab to go to another app, Command-Tab back "
                        @"here, then move the mouse for two seconds. Three times.\n\n"
                        @"Press Esc to stop early. Only mouse movement and buttons are recorded.",
                        13, NSFontWeightRegular);
    progress = [NSProgressIndicator new];
    progress.indeterminate = NO;
    progress.minValue = 0;
    progress.maxValue = CLICK_SECONDS;
    status = text(@"", 13, NSFontWeightRegular);
    button = [NSButton buttonWithTitle:@"Start" target:self action:@selector(start:)];
    button.keyEquivalent = @"\r";
    NSStackView *stack = [NSStackView stackViewWithViews:@[ heading, instructions, progress, status, button ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 16;
    stack.edgeInsets = NSEdgeInsetsMake(24, 24, 24, 24);
    [progress.widthAnchor constraintEqualToConstant:520].active = YES;
    window.contentView = stack;
    [self fit];
}

- (void)fit
{
    NSRect frame = window.frame;
    NSSize size = [window frameRectForContentRect:(NSRect){ NSZeroPoint, window.contentView.fittingSize }].size;
    [window setFrame:NSMakeRect(frame.origin.x, NSMaxY(frame) - size.height, size.width, size.height) display:YES];
}

/* Freezes the pointer over the window and hides it, as a game does. */
- (void)freeze
{
    if (frozen) return;
    if (!NSPointInRect(NSEvent.mouseLocation, window.frame)) {
        CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
        CGWarpMouseCursorPosition(CGPointMake(NSMidX(window.frame), top - NSMidY(window.frame)));
        CGAssociateMouseAndMouseCursorPosition(true);
    }
    CGAssociateMouseAndMouseCursorPosition(false);
    [NSCursor hide];
    frozen = YES;
}

- (void)thaw
{
    if (!frozen) return;
    CGAssociateMouseAndMouseCursorPosition(true);
    [NSCursor unhide];
    frozen = NO;
}

- (void)start:(id)sender
{
    if (atomic_load(&phase) != PHASE_IDLE) return;
    for (int f = 0; f < FEED_COUNT; f++) atomic_store(&counts[f], 0);
    mark_count = 0;
    returns = 0;
    started = now_ns();
    atomic_store(&active, NSApp.isActive);
    atomic_store(&phase, PHASE_CLICKS);
    atomic_store_explicit(&recording, true, memory_order_release);
    mark("start", 1);
    [self freeze];
    button.enabled = NO;
    button.title = @"Running…";
    heading.stringValue = @"Step 1: aim and click";
    instructions.stringValue = @"Swipe quickly left and right and click during each swipe. Mix in a few right clicks "
                               @"and a few clicks while holding still.";
    [self fit];
}

- (void)beginSwitching
{
    atomic_store(&phase, PHASE_SWITCH);
    mark("start", 2);
    switchStarted = now_ns();
    progress.maxValue = RETURNS;
    progress.doubleValue = 0;
    heading.stringValue = @"Step 2: switch apps";
    instructions.stringValue = @"Press Command-Tab to go to another app, then Command-Tab back here and move the "
                               @"mouse for two seconds. Do this three times.";
    NSBeep();
    [self fit];
}

- (void)finish:(BOOL)completed
{
    if (atomic_load(&phase) == PHASE_IDLE) return;
    mark("finish", completed);
    atomic_store(&phase, PHASE_IDLE);
    atomic_store_explicit(&recording, false, memory_order_release);
    [self thaw];
    dispatch_sync(game_queue, ^{});
    NSMutableArray *names = [NSMutableArray array];
    for (NSUInteger i = 0; i < mice.count; i++)
        [names addObject:@{ @"name": mouse_names[i], @"buttons": @(2 + (mice[i].mouseInput.middleButton != nil) +
                                                                      mice[i].mouseInput.auxiliaryButtons.count) }];
    if (outDir) {
        [NSFileManager.defaultManager createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:NULL];
        write_events(outDir);
        write_json(@{ @"schema": @1, @"completed": @(completed), @"returns": @(returns), @"mice": names,
                      @"started_ns": @(started), @"system": system_info(),
                      @"click_seconds": @(CLICK_SECONDS) },
                   [outDir stringByAppendingPathComponent:@"context.json"]);
    }
    heading.stringValue = completed ? @"Done" : @"Stopped early";
    instructions.stringValue = @"Thanks! The results are in the Terminal window. You can close this window.";
    status.stringValue = @"";
    button.title = @"Close";
    button.action = @selector(close:);
    button.enabled = YES;
    [self fit];
}

- (void)close:(id)sender { [NSApp terminate:nil]; }

- (void)tick:(NSTimer *)timer
{
    int current = atomic_load(&phase);
    uint64_t now = now_ns();
    if (current == PHASE_CLICKS) {
        double elapsed = (now - started) / 1e9;
        progress.doubleValue = fmin(elapsed, CLICK_SECONDS);
        status.stringValue = [NSString stringWithFormat:@"%.0f seconds left.", fmax(0, ceil(CLICK_SECONDS - elapsed))];
        if (elapsed >= CLICK_SECONDS) [self beginSwitching];
    } else if (current == PHASE_SWITCH) {
        progress.doubleValue = returns;
        status.stringValue = [NSString stringWithFormat:@"Returned %d of %d times.%@", returns, RETURNS,
                                       NSApp.isActive && returns ? @" Move the mouse for two seconds." : @""];
        if ((returns >= RETURNS && NSApp.isActive && now - lastReturn > 3000000000ull) ||
            now - switchStarted > SWITCH_SECONDS * 1000000000ull)
            [self finish:returns >= RETURNS];
    }
}

- (void)applicationDidResignActive:(NSNotification *)note
{
    atomic_store(&active, false);
    if (atomic_load(&phase) == PHASE_IDLE) return;
    mark("resign", returns);
    [self thaw];
}

- (void)applicationDidBecomeActive:(NSNotification *)note
{
    atomic_store(&active, true);
    if (atomic_load(&phase) == PHASE_IDLE) return;
    if (atomic_load(&phase) == PHASE_SWITCH) {
        returns++;
        lastReturn = now_ns();
    }
    mark("activate", returns);
    /* As after a Command-Tab in Recall: the handlers stay attached, nothing is re-armed. */
    for (GCMouse *mouse in mice) {
        NSUInteger i = [mice indexOfObject:mouse];
        if (mouse.mouseInput != mouse_inputs[i]) mark("input_replaced", (int)i);
        if (!mouse.mouseInput.mouseMovedHandler) mark("handler_cleared", (int)i);
    }
    [self freeze];
}

- (void)windowWillClose:(NSNotification *)note { [self finish:NO]; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }
- (void)applicationWillTerminate:(NSNotification *)note { [self finish:NO]; }
@end

/* Lists the mice GCMouse sees and their buttons. No window. */
static int selftest(void)
{
    [NSApplication sharedApplication];
    NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;
    [NSApp finishLaunching];
    NSMutableArray<GCMouse *> *connected = [NSMutableArray array];
    [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidConnectNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *n) { [connected addObject:n.object]; }];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:3]];
    NSMutableArray *list = [NSMutableArray array];
    for (GCMouse *mouse in GCMouse.mice.count ? GCMouse.mice : connected)
        [list addObject:@{ @"name": mouse_name(mouse), @"category": mouse.productCategory ?: @"",
                           @"right": @(mouse.mouseInput.rightButton != nil), @"middle": @(mouse.mouseInput.middleButton != nil),
                           @"auxiliary": @(mouse.mouseInput.auxiliaryButtons.count) }];
    write_json(@{ @"game_mice": list, @"system": system_info() }, nil);
    return 0;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        mach_timebase_info(&timebase);
        for (int f = 0; f < FEED_COUNT; f++) events[f] = calloc(capacity, sizeof(event_t));
        mice = [NSMutableArray array];
        mouse_names = [NSMutableArray array];
        mouse_inputs = [NSMutableArray array];
        NSString *output = nil;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--selftest")) return selftest();
            if (!strcmp(argv[i], "--out") && i + 1 < argc) output = @(argv[++i]);
        }
        NSApplication *app = [NSApplication sharedApplication];
        Check *check = [[Check alloc] initWithOutput:output];
        app.delegate = check;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        [app run];
    }
    return 0;
}
