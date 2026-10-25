/* Recall Mouse Probe (REC-52).
 *
 * Counts mouse movement once a second from three sources side by side while a person moves the
 * mouse, clicks and switches apps, with no game running: the mouse's own HID reports (IOHID),
 * Apple's mouse input for games (GCMouse, what the window driver reads today) and the macOS
 * pointer (AppKit's events). A second copy of the probe, started from this one the way Recall
 * starts Wine (a child process, its x86_64 code translated by Rosetta), reads IOHID too: whether a
 * child gets the app's Input Monitoring permission, and IOHID's report rate under Rosetta.
 *
 * Only devices with a mouse collection are opened, and only their X, Y and button elements are
 * read, never keys. One JSON line a second, and a line for each event, go to
 * ~/Library/Logs/Recall Mouse Probe/probe-<UTC>.jsonl. Built by scripts/build_hid_mouse_probe.py.
 */
#import <Cocoa/Cocoa.h>
#import <GameController/GameController.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDUsageTables.h>
#import <QuartzCore/QuartzCore.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <spawn.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

enum { MAX_DEVICES = 16 };

/* One second of one source.  Motion is |dx| + |dy| in mouse counts (points for the pointer).
 * Delays run from the report's time (or the event's) to its arrival here; for IOHID they are
 * worked out twice, with the process's timebase (a) and with Apple silicon's 24 MHz ticks (b),
 * because it is not known which one Rosetta gives a translated process for HID timestamps. */
typedef struct {
    unsigned long long reports, buttons, delays, delays_b;
    double motion, delay_ms, delay_max_ms, delay_b_ms, delay_b_max_ms, gap_max_ms;
} Tally;

static os_unfair_lock tally_lock = OS_UNFAIR_LOCK_INIT;
static Tally hid_tally, gc_tally, pointer_tally;
static Tally device_tally[MAX_DEVICES];
static IOHIDDeviceRef device_refs[MAX_DEVICES];
static char device_names[MAX_DEVICES][200];
static uint64_t device_last_report[MAX_DEVICES];
static int device_count;
static unsigned long long clicks, left_clicks, activations, resigns;
static uint64_t sample_stamp;
static unsigned long long sample_now_ns;
static double gc_sample_event, gc_sample_media;

static double hid_ns_per_tick = 1;                    /* (a): the process's mach timebase */
static const double native_ns_per_tick = 125.0 / 3.0;  /* (b): Apple silicon's 24 MHz ticks */
static BOOL translated;
static IOHIDManagerRef manager;
static IOReturn hid_open_result = kIOReturnNotOpen;
static BOOL hid_started;
static void (*emit)(NSDictionary *line);

static double rounded(double value) { return round(value * 1000) / 1000; }

/* A line as JSON; anything that isn't JSON (an unexpected registry value) as its description. */
static NSMutableData *json_line(NSDictionary *line)
{
    NSMutableData *data = [NSJSONSerialization isValidJSONObject:line]
        ? [[NSJSONSerialization dataWithJSONObject:line options:0 error:nil] mutableCopy]
        : [[NSJSONSerialization dataWithJSONObject:@{@"source": line[@"source"] ?: @"", @"unserializable": line.description}
                                           options:0 error:nil] mutableCopy];
    [data appendBytes:"\n" length:1];
    return data;
}

static void tally_delay(Tally *tally, double ms, BOOL b)
{
    if (!(ms >= 0 && ms < 10000)) return;  /* a clock that doesn't match is left out */
    if (b)
    {
        tally->delays_b++;
        tally->delay_b_ms += ms;
        if (ms > tally->delay_b_max_ms) tally->delay_b_max_ms = ms;
    }
    else
    {
        tally->delays++;
        tally->delay_ms += ms;
        if (ms > tally->delay_max_ms) tally->delay_max_ms = ms;
    }
}

static NSDictionary *tally_json(const Tally *tally, BOOL hid)
{
    NSMutableDictionary *json = [@{@"reports": @(tally->reports), @"motion": @(rounded(tally->motion)),
                                   @"buttons": @(tally->buttons)} mutableCopy];
    if (tally->delays)
    {
        json[@"delay_ms"] = @(rounded(tally->delay_ms / tally->delays));
        json[@"delay_max_ms"] = @(rounded(tally->delay_max_ms));
    }
    if (hid)
    {
        if (tally->delays_b)
        {
            json[@"delay_b_ms"] = @(rounded(tally->delay_b_ms / tally->delays_b));
            json[@"delay_b_max_ms"] = @(rounded(tally->delay_b_max_ms));
        }
        json[@"gap_max_ms"] = @(rounded(tally->gap_max_ms));
    }
    return json;
}

static NSString *access_name(IOHIDAccessType access)
{
    switch (access)
    {
        case kIOHIDAccessTypeGranted: return @"granted";
        case kIOHIDAccessTypeDenied: return @"denied";
        default: return @"unknown";
    }
}

static NSString *hex(IOReturn value) { return [NSString stringWithFormat:@"0x%08x", (unsigned)value]; }

static NSNumber *responsible_pid(void)
{
    pid_t (*responsible)(pid_t) = (pid_t (*)(pid_t))dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid");
    return responsible ? @(responsible(getpid())) : (NSNumber *)[NSNull null];
}

/* Mice as the I/O Registry lists them: read without opening anything, so without Input Monitoring. */
static NSArray *registry_mice(void)
{
    NSMutableArray *list = [NSMutableArray array];
    io_iterator_t iterator = 0;
    io_object_t service;

    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDDevice"), &iterator) != KERN_SUCCESS)
        return list;
    while ((service = IOIteratorNext(iterator)))
    {
        CFMutableDictionaryRef properties = NULL;
        if (IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS && properties)
        {
            NSDictionary *p = CFBridgingRelease(properties);
            BOOL mouse = NO;
            for (NSDictionary *pair in p[@kIOHIDDeviceUsagePairsKey])
                if ([pair[@kIOHIDDeviceUsagePageKey] intValue] == kHIDPage_GenericDesktop &&
                    [pair[@kIOHIDDeviceUsageKey] intValue] == kHIDUsage_GD_Mouse)
                    mouse = YES;
            if (mouse)
                [list addObject:@{@"product": p[@kIOHIDProductKey] ?: @"",
                                  @"primary_usage": [NSString stringWithFormat:@"%@/%@", p[@kIOHIDPrimaryUsagePageKey], p[@kIOHIDPrimaryUsageKey]],
                                  @"transport": p[@kIOHIDTransportKey] ?: @"",
                                  @"report_interval_us": p[@kIOHIDReportIntervalKey] ?: [NSNull null],
                                  @"requires_tcc": p[@"RequiresTCCAuthorization"] ?: [NSNull null],
                                  @"built_in": p[@kIOHIDBuiltInKey] ?: [NSNull null],
                                  @"location": p[@kIOHIDLocationIDKey] ?: [NSNull null]}];
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return list;
}

/* ---------- IOHID ---------- */

static NSString *device_property(IOHIDDeviceRef device, CFStringRef key)
{
    CFTypeRef value = IOHIDDeviceGetProperty(device, key);
    if (value && CFGetTypeID(value) == CFStringGetTypeID()) return (__bridge NSString *)value;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) return [(__bridge NSNumber *)value stringValue];
    return @"";
}

static int device_index(IOHIDDeviceRef device)  /* under tally_lock */
{
    for (int i = 0; i < device_count; i++)
        if (device_refs[i] == device) return i;
    return -1;
}

static void device_matched(void *context __unused, IOReturn result __unused, void *sender __unused, IOHIDDeviceRef device)
{
    NSString *name = [NSString stringWithFormat:@"%@ (usage %@/%@, %@, location %@)",
                      device_property(device, CFSTR(kIOHIDProductKey)),
                      device_property(device, CFSTR(kIOHIDPrimaryUsagePageKey)),
                      device_property(device, CFSTR(kIOHIDPrimaryUsageKey)),
                      device_property(device, CFSTR(kIOHIDTransportKey)),
                      device_property(device, CFSTR(kIOHIDLocationIDKey))];

    os_unfair_lock_lock(&tally_lock);
    if (device_index(device) < 0 && device_count < MAX_DEVICES)
    {
        device_refs[device_count] = device;
        strlcpy(device_names[device_count], name.UTF8String, sizeof(device_names[0]));
        device_count++;
    }
    os_unfair_lock_unlock(&tally_lock);
    emit(@{@"event": @"hid_device", @"device": name});
}

static void device_removed(void *context __unused, IOReturn result __unused, void *sender __unused, IOHIDDeviceRef device)
{
    emit(@{@"event": @"hid_device_removed", @"device": device_property(device, CFSTR(kIOHIDProductKey))});
}

/* Motion: X and Y values of one report share its timestamp, so a new timestamp is a new report. */
static void value_arrived(void *context __unused, IOReturn result __unused, void *sender __unused, IOHIDValueRef value)
{
    IOHIDElementRef element = IOHIDValueGetElement(value);
    uint32_t page = IOHIDElementGetUsagePage(element), usage = IOHIDElementGetUsage(element);
    IOHIDDeviceRef device = IOHIDElementGetDevice(element);
    uint64_t stamp = IOHIDValueGetTimeStamp(value);
    CFIndex amount = IOHIDValueGetIntegerValue(value);
    unsigned long long now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    int i;

    os_unfair_lock_lock(&tally_lock);
    i = device_index(device);
    if (page == kHIDPage_Button)
    {
        hid_tally.buttons++;
        if (i >= 0) device_tally[i].buttons++;
    }
    else if (page == kHIDPage_GenericDesktop && (usage == kHIDUsage_GD_X || usage == kHIDUsage_GD_Y) && amount)
    {
        double size = labs((long)amount);

        hid_tally.motion += size;
        if (i >= 0)
        {
            device_tally[i].motion += size;
            if (stamp != device_last_report[i])
            {
                double ns_per_tick = translated ? native_ns_per_tick : hid_ns_per_tick;
                if (device_last_report[i] && stamp > device_last_report[i])
                {
                    double gap = (stamp - device_last_report[i]) * ns_per_tick / 1e6;
                    if (gap < 50 && gap > hid_tally.gap_max_ms) hid_tally.gap_max_ms = gap;
                }
                device_last_report[i] = stamp;
                device_tally[i].reports++;
                hid_tally.reports++;
                tally_delay(&hid_tally, ((double)now - stamp * hid_ns_per_tick) / 1e6, NO);
                tally_delay(&hid_tally, ((double)now - stamp * native_ns_per_tick) / 1e6, YES);
                sample_stamp = stamp;
                sample_now_ns = now;
            }
        }
    }
    os_unfair_lock_unlock(&tally_lock);
}

static void start_hid(dispatch_queue_t queue)
{
    NSArray *devices = @[@{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_Mouse)}];
    NSArray *elements = @[@{@kIOHIDElementUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDElementUsageKey: @(kHIDUsage_GD_X)},
                          @{@kIOHIDElementUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDElementUsageKey: @(kHIDUsage_GD_Y)},
                          @{@kIOHIDElementUsagePageKey: @(kHIDPage_Button)}];

    if (hid_started) return;
    hid_started = YES;
    manager = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    IOHIDManagerSetDeviceMatchingMultiple(manager, (__bridge CFArrayRef)devices);
    IOHIDManagerSetInputValueMatchingMultiple(manager, (__bridge CFArrayRef)elements);
    IOHIDManagerRegisterDeviceMatchingCallback(manager, device_matched, NULL);
    IOHIDManagerRegisterDeviceRemovalCallback(manager, device_removed, NULL);
    IOHIDManagerRegisterInputValueCallback(manager, value_arrived, NULL);
    IOHIDManagerSetDispatchQueue(manager, queue);
    hid_open_result = IOHIDManagerOpen(manager, kIOHIDOptionsTypeNone);
    IOHIDManagerActivate(manager);
    emit(@{@"event": @"hid_open", @"result": hex(hid_open_result),
           @"access": access_name(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent))});
}

static dispatch_queue_t hid_queue(void)
{
    static dispatch_queue_t queue;
    if (!queue)
        queue = dispatch_queue_create("org.overwatch2mac.mouse-probe.hid",
                                      dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    return queue;
}

/* A second's IOHID tally, taken and cleared; with each device's share. */
static NSDictionary *take_hid_second(void)
{
    NSMutableDictionary *perDevice = [NSMutableDictionary dictionary];
    Tally hid;

    os_unfair_lock_lock(&tally_lock);
    hid = hid_tally;
    memset(&hid_tally, 0, sizeof(hid_tally));
    for (int i = 0; i < device_count; i++)
    {
        if (device_tally[i].reports || device_tally[i].buttons)
            perDevice[@(device_names[i])] = @{@"reports": @(device_tally[i].reports),
                                               @"motion": @(rounded(device_tally[i].motion)),
                                               @"buttons": @(device_tally[i].buttons)};
        memset(&device_tally[i], 0, sizeof(device_tally[i]));
    }
    os_unfair_lock_unlock(&tally_lock);

    NSMutableDictionary *json = [tally_json(&hid, YES) mutableCopy];
    json[@"open"] = hid_started ? hex(hid_open_result) : (id)[NSNull null];
    json[@"devices"] = perDevice;
    return json;
}

/* ---------- The child: IOHID only, under Rosetta, one JSON line a second on stdout ---------- */

static void child_emit(NSDictionary *line)
{
    static os_unfair_lock write_lock = OS_UNFAIR_LOCK_INIT;
    NSMutableDictionary *tagged = [line mutableCopy];
    if (!tagged[@"source"]) tagged[@"source"] = @"hid-child";
    tagged[@"unix_ms"] = @((long long)([NSDate date].timeIntervalSince1970 * 1000));
    NSMutableData *data = json_line(tagged);
    os_unfair_lock_lock(&write_lock);
    write(STDOUT_FILENO, data.bytes, data.length);
    os_unfair_lock_unlock(&write_lock);
}

static int child_main(void)
{
    static unsigned long long second;
    static char eof_buffer[64];
    dispatch_source_t timer, input;

    emit = child_emit;
    emit(@{@"event": @"start", @"pid": @(getpid()), @"parent": @(getppid()), @"responsible_pid": responsible_pid(),
           @"translated": @(translated), @"access": access_name(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)),
           @"ns_per_tick": @(hid_ns_per_tick)});
    start_hid(hid_queue());

    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{
        NSMutableDictionary *line = [@{@"t": @(++second), @"hid": take_hid_second()} mutableCopy];
        os_unfair_lock_lock(&tally_lock);
        if (sample_stamp) line[@"clock_sample"] = @{@"now_ns": @(sample_now_ns), @"stamp": @(sample_stamp)};
        sample_stamp = 0;
        os_unfair_lock_unlock(&tally_lock);
        emit(line);
    });
    dispatch_resume(timer);

    /* The app keeps our stdin open; when it closes, the probe is over. */
    input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(input, ^{
        if (read(STDIN_FILENO, eof_buffer, sizeof(eof_buffer)) <= 0) exit(0);
    });
    dispatch_resume(input);
    dispatch_main();
}

/* ---------- The app ---------- */

static NSFileHandle *log_file;
static dispatch_queue_t log_queue;
static NSString *log_path;
static NSDate *started;

static void write_log_data(NSData *data)
{
    dispatch_async(log_queue, ^{ [log_file writeData:data]; });
}

static void app_emit(NSDictionary *line)
{
    NSMutableDictionary *tagged = [line mutableCopy];
    tagged[@"source"] = @"app";
    tagged[@"unix_ms"] = @((long long)([NSDate date].timeIntervalSince1970 * 1000));
    tagged[@"elapsed_s"] = @(rounded(-started.timeIntervalSinceNow));
    write_log_data(json_line(tagged));
}

static BOOL captured;

/* The test needs the hardware read: until it is, the box doesn't take the mouse. */
static BOOL hid_reading(void) { return hid_started && hid_open_result == kIOReturnSuccess; }

static void capture(BOOL on)
{
    if (on == captured) return;
    captured = on;
    if (on)
    {
        [NSCursor hide];
        CGAssociateMouseAndMouseCursorPosition(false);
    }
    else
    {
        CGAssociateMouseAndMouseCursorPosition(true);
        [NSCursor unhide];
    }
    emit(@{@"event": on ? @"captured" : @"released"});
}

/* The area that takes the mouse, as the game does: click to hide the pointer and keep it in place,
 * Esc or switching apps to get it back. */
@interface CaptureView : NSView
@end

@implementation CaptureView
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event __unused { return YES; }
- (void)mouseDown:(NSEvent *)event __unused { if (!captured && hid_reading()) capture(YES); [self setNeedsDisplay:YES]; }
- (void)keyDown:(NSEvent *)event
{
    if (event.keyCode == 53) { capture(NO); [self setNeedsDisplay:YES]; }
    else [super keyDown:event];
}
- (void)drawRect:(NSRect)dirty __unused
{
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, 1, 1) xRadius:12 yRadius:12];
    [(captured ? [NSColor.controlAccentColor colorWithAlphaComponent:0.18] : NSColor.quaternaryLabelColor) setFill];
    [path fill];
    NSString *text = captured ? @"Recording your mouse. Press Esc to get the pointer back."
                   : hid_reading() ? @"Click here to start. The pointer disappears, as it does in the game."
                                   : @"First, allow Input Monitoring (above).";
    NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:15 weight:NSFontWeightMedium],
                                 NSForegroundColorAttributeName: NSColor.secondaryLabelColor};
    NSSize size = [text sizeWithAttributes:attributes];
    [text drawAtPoint:NSMakePoint((self.bounds.size.width - size.width) / 2, (self.bounds.size.height - size.height) / 2)
       withAttributes:attributes];
}
@end

@interface ProbeController : NSObject <NSApplicationDelegate>
@end

@implementation ProbeController
{
    NSWindow *window;
    CaptureView *captureView;
    NSTextField *stats, *permission;
    NSButton *allowButton, *settingsButton;
    dispatch_queue_t gcQueue;
    NSMutableArray<GCMouse *> *gcMice;
    NSMapTable *gcInputs;
    NSTimer *timer;
    unsigned long long second;
    pid_t child;
    int childInput;
    dispatch_source_t childOutput;
    NSMutableData *childBuffer;
    NSDictionary *childSecond;
    unsigned long long totals[4][2];  /* hid, child, gcmouse, pointer: reports, motion */
}

- (void)applicationDidFinishLaunching:(NSNotification *)note __unused
{
    NSDateFormatter *format = [NSDateFormatter new];
    NSString *folder = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/Recall Mouse Probe"];
    unsigned long long frequency = 0;
    size_t size = sizeof(frequency);

    started = [NSDate date];
    format.dateFormat = @"yyyyMMdd'T'HHmmss'Z'";
    format.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    format.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    log_path = [folder stringByAppendingPathComponent:[NSString stringWithFormat:@"probe-%@.jsonl", [format stringFromDate:started]]];
    [NSFileManager.defaultManager createFileAtPath:log_path contents:nil attributes:nil];
    log_file = [NSFileHandle fileHandleForWritingAtPath:log_path];
    log_queue = dispatch_queue_create("org.overwatch2mac.mouse-probe.log", DISPATCH_QUEUE_SERIAL);
    emit = app_emit;

    sysctlbyname("hw.tbfrequency", &frequency, &size, NULL, 0);
    emit(@{@"event": @"start", @"probe_version": @3, @"pid": @(getpid()), @"responsible_pid": responsible_pid(),
           @"macos": NSProcessInfo.processInfo.operatingSystemVersionString, @"translated": @(translated),
           @"tb_frequency": @(frequency), @"ns_per_tick": @(hid_ns_per_tick),
           @"access": access_name(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)), @"mice": registry_mice()});

    [self buildMenu];
    [self buildWindow];
    [self startGCMouse];
    [self startPointer];

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *n __unused) { [self becameActive]; }];
    [center addObserverForName:NSApplicationDidResignActiveNotification object:nil queue:NSOperationQueue.mainQueue
                    usingBlock:^(NSNotification *n __unused) { [self resigned]; }];

    [self checkAccess];
    timer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [NSApp activate];
    /* macOS asks right away, rather than waiting for the button. */
    if (IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeUnknown) [self allow:nil];
}

- (void)resigned
{
    os_unfair_lock_lock(&tally_lock);
    resigns++;
    os_unfair_lock_unlock(&tally_lock);
    capture(NO);
    [captureView setNeedsDisplay:YES];
}

- (void)becameActive
{
    os_unfair_lock_lock(&tally_lock);
    activations++;
    os_unfair_lock_unlock(&tally_lock);
    /* As the window driver does: a mouse whose handlers macOS cleared or replaced while another
       app was active is set up again (noted, to compare). */
    for (GCMouse *mouse in gcMice)
        if (!mouse.mouseInput.mouseMovedHandler || [gcInputs objectForKey:mouse] != mouse.mouseInput)
        {
            emit(@{@"event": @"gcmouse_rearmed", @"cleared": @(!mouse.mouseInput.mouseMovedHandler)});
            [self armMouse:mouse];
        }
}

- (void)buildMenu
{
    NSMenu *bar = [NSMenu new], *appMenu = [NSMenu new], *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem *appItem = [NSMenuItem new], *viewItem = [NSMenuItem new];
    [appMenu addItemWithTitle:@"Quit Recall Mouse Probe" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    [bar addItem:appItem];
    [viewMenu addItemWithTitle:@"Enter Full Screen" action:@selector(toggleFullScreen:) keyEquivalent:@"f"].keyEquivalentModifierMask =
        NSEventModifierFlagControl | NSEventModifierFlagCommand;
    viewItem.submenu = viewMenu;
    [bar addItem:viewItem];
    NSApp.mainMenu = bar;
}

- (NSTextField *)label:(NSString *)text size:(CGFloat)size weight:(NSFontWeight)weight
{
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.font = [NSFont systemFontOfSize:size weight:weight];
    label.selectable = NO;
    return label;
}

- (void)buildWindow
{
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 600)
                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                   NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                           backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Recall Mouse Probe";
    window.acceptsMouseMovedEvents = YES;
    window.releasedWhenClosed = NO;
    window.contentMinSize = NSMakeSize(760, 640);
    /* A full-screen space of its own, as the game's Fullscreen mode has (where a tester's aim went wrong). */
    window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    for (NSString *name in @[NSWindowDidEnterFullScreenNotification, NSWindowDidExitFullScreenNotification])
        [NSNotificationCenter.defaultCenter addObserverForName:name object:window queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *n) {
            emit(@{@"event": [n.name isEqual:NSWindowDidEnterFullScreenNotification] ? @"fullscreen_entered" : @"fullscreen_exited"});
        }];

    NSTextField *headline = [self label:@"Mouse test" size:22 weight:NSFontWeightSemibold];
    NSTextField *steps = [self label:@"Once the first line under the box shows your mouse’s updates:\n"
                                      "1. Click inside the box. The pointer disappears, as it does in the game.\n"
                                      "2. Swipe left and right for about 20 seconds without clicking.\n"
                                      "3. Left-click a few times, the way you shoot, then swipe for another 20 seconds.\n"
                                      "4. Cmd-Tab to another app, wait about 10 seconds, then Cmd-Tab back.\n"
                                      "5. Click inside the box again and swipe for 20 seconds.\n"
                                      "6. Press Esc, then Full Screen. When the window fills the screen, do steps 1 to 5 again.\n"
                                      "7. Press Esc, then Finish. Finder opens with the results file."
                                size:13 weight:NSFontWeightRegular];
    captureView = [CaptureView new];
    stats = [self label:@"" size:13 weight:NSFontWeightRegular];
    stats.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular];
    permission = [self label:@"" size:13 weight:NSFontWeightMedium];
    allowButton = [NSButton buttonWithTitle:@"Allow Input Monitoring…" target:self action:@selector(allow:)];
    settingsButton = [NSButton buttonWithTitle:@"Open System Settings" target:self action:@selector(openSettings:)];
    NSStackView *access = [NSStackView stackViewWithViews:@[allowButton, settingsButton]];
    NSButton *fullScreen = [NSButton buttonWithTitle:@"Full Screen" target:nil action:@selector(toggleFullScreen:)];
    NSButton *finish = [NSButton buttonWithTitle:@"Finish" target:self action:@selector(finish:)];
    finish.keyEquivalent = @"\r";
    NSStackView *end = [NSStackView stackViewWithViews:@[fullScreen, finish]];

    NSStackView *stack = [NSStackView stackViewWithViews:@[headline, permission, access, steps, captureView, stats, end]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 14;
    stack.edgeInsets = NSEdgeInsetsMake(24, 28, 24, 28);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    window.contentView = [NSView new];
    [window.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:window.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:window.contentView.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:window.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:window.contentView.bottomAnchor],
        [captureView.heightAnchor constraintEqualToConstant:180],
        [captureView.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-56],
        [steps.widthAnchor constraintEqualToAnchor:captureView.widthAnchor],
        [stats.widthAnchor constraintEqualToAnchor:captureView.widthAnchor],
        [permission.widthAnchor constraintEqualToAnchor:captureView.widthAnchor],
    ]];
    [window center];
    [window makeKeyAndOrderFront:nil];
    [window makeFirstResponder:captureView];
}

/* ---- Input Monitoring ---- */

- (void)checkAccess
{
    IOHIDAccessType access = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent);

    if (access == kIOHIDAccessTypeGranted && !hid_started)
    {
        start_hid(hid_queue());
        if (hid_open_result == kIOReturnSuccess) [self startChild];
    }
    allowButton.hidden = access != kIOHIDAccessTypeUnknown;
    settingsButton.hidden = access == kIOHIDAccessTypeGranted;
    [captureView setNeedsDisplay:YES];
    if (access == kIOHIDAccessTypeGranted)
        permission.stringValue = hid_open_result == kIOReturnSuccess
            ? @"Input Monitoring is on: the probe reads your mouse directly."
            : [NSString stringWithFormat:@"Input Monitoring is on, but the mouse didn’t open (%@). Quit the probe and open it again.", hex(hid_open_result)];
    else if (access == kIOHIDAccessTypeDenied)
        permission.stringValue = @"Input Monitoring is off for this probe. Turn it on in System Settings › Privacy & Security › Input Monitoring, then quit the probe and open it again.";
    else
        permission.stringValue = @"To read your mouse directly, the probe needs Input Monitoring. In macOS’s request, choose Open System Settings, turn on Recall Mouse Probe, then choose Quit & Reopen. macOS words it as receiving keystrokes; the probe opens only mice and reads only movement and buttons.";
}

- (void)allow:(id)sender __unused
{
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        bool granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
        emit(@{@"event": @"access_requested", @"granted": @(granted)});
    });
}

- (void)openSettings:(id)sender __unused
{
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"]];
}

/* ---- The child under Rosetta ---- */

- (void)startChild
{
    posix_spawnattr_t attributes;
    posix_spawn_file_actions_t actions;
    cpu_type_t preference = CPU_TYPE_X86_64;
    size_t count = 0;
    int output[2], input[2], result;
    const char *path = NSBundle.mainBundle.executablePath.fileSystemRepresentation;
    char *arguments[] = {(char *)path, "--child", NULL};

    if (pipe(output) || pipe(input)) return;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setbinpref_np(&attributes, 1, &preference, &count);
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO);
    posix_spawn_file_actions_addclose(&actions, output[0]);
    posix_spawn_file_actions_addclose(&actions, input[1]);
    result = posix_spawn(&child, path, &actions, &attributes, arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    close(output[1]);
    close(input[0]);
    emit(@{@"event": @"child_started", @"result": @(result), @"pid": @(child)});
    if (result) { close(output[0]); close(input[1]); child = 0; return; }
    childInput = input[1];
    childBuffer = [NSMutableData data];
    childOutput = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, output[0], 0, log_queue);
    int fd = output[0];
    dispatch_source_set_event_handler(childOutput, ^{
        char buffer[16384];
        ssize_t got = read(fd, buffer, sizeof(buffer));
        if (got <= 0) { dispatch_source_cancel(self->childOutput); return; }
        [self->childBuffer appendBytes:buffer length:got];
        for (;;)
        {
            NSRange newline = [self->childBuffer rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0
                                                       range:NSMakeRange(0, self->childBuffer.length)];
            if (newline.location == NSNotFound) break;
            NSData *line = [self->childBuffer subdataWithRange:NSMakeRange(0, newline.location + 1)];
            [self->childBuffer replaceBytesInRange:NSMakeRange(0, newline.location + 1) withBytes:NULL length:0];
            [log_file writeData:line];  /* already on log_queue */
            NSDictionary *parsed = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
            if ([parsed isKindOfClass:NSDictionary.class] && parsed[@"hid"])
                dispatch_async(dispatch_get_main_queue(), ^{ self->childSecond = parsed; });
        }
    });
    dispatch_source_set_cancel_handler(childOutput, ^{ close(fd); });
    dispatch_resume(childOutput);
}

/* ---- GCMouse, as the window driver sets it up ---- */

- (void)startGCMouse
{
    gcQueue = dispatch_queue_create("org.overwatch2mac.mouse-probe.gcmouse",
                                    dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_USER_INTERACTIVE, 0));
    gcMice = [NSMutableArray array];
    gcInputs = [NSMapTable strongToStrongObjectsMapTable];
    [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidConnectNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { [self attachMouse:n.object]; }];
    [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) {
        emit(@{@"event": @"gcmouse_disconnected", @"vendor": ((GCMouse *)n.object).vendorName ?: @""});
        [self->gcMice removeObject:n.object];
    }];
    for (GCMouse *mouse in GCMouse.mice) [self attachMouse:mouse];
}

- (void)attachMouse:(GCMouse *)mouse
{
    if ([gcMice containsObject:mouse]) return;
    if ([mouse.vendorName rangeOfString:@"Trackpad" options:NSCaseInsensitiveSearch].location != NSNotFound)
    {
        emit(@{@"event": @"gcmouse_skipped", @"vendor": mouse.vendorName ?: @""});
        return;
    }
    [gcMice addObject:mouse];
    [self armMouse:mouse];
    emit(@{@"event": @"gcmouse_attached", @"vendor": mouse.vendorName ?: @""});
}

- (void)armMouse:(GCMouse *)mouse
{
    GCMouseInput *input = mouse.mouseInput;
    void (^press)(GCControllerButtonInput *, float, BOOL) = ^(GCControllerButtonInput *b __unused, float v __unused, BOOL p __unused) {
        os_unfair_lock_lock(&tally_lock);
        gc_tally.buttons++;
        os_unfair_lock_unlock(&tally_lock);
    };

    mouse.handlerQueue = gcQueue;
    input.mouseMovedHandler = ^(GCMouseInput *profile, float deltaX, float deltaY) {
        double media = CACurrentMediaTime(), event = profile.lastEventTimestamp;
        os_unfair_lock_lock(&tally_lock);
        gc_tally.reports++;
        gc_tally.motion += fabs(deltaX) + fabs(deltaY);
        tally_delay(&gc_tally, (media - event) * 1000, NO);
        gc_sample_event = event;  /* which clock lastEventTimestamp keeps isn't documented */
        gc_sample_media = media;
        os_unfair_lock_unlock(&tally_lock);
    };
    input.leftButton.pressedChangedHandler = press;
    input.rightButton.pressedChangedHandler = press;
    input.middleButton.pressedChangedHandler = press;
    for (GCControllerButtonInput *button in input.auxiliaryButtons) button.pressedChangedHandler = press;
    [gcInputs setObject:input forKey:mouse];
}

/* ---- The macOS pointer and clicks, as AppKit gives them to this app ---- */

- (void)startPointer
{
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged |
                                                  NSEventMaskRightMouseDragged | NSEventMaskOtherMouseDragged
                                          handler:^NSEvent *(NSEvent *event) {
        double delay = (CACurrentMediaTime() - event.timestamp) * 1000;
        os_unfair_lock_lock(&tally_lock);
        pointer_tally.reports++;
        pointer_tally.motion += fabs(event.deltaX) + fabs(event.deltaY);
        tally_delay(&pointer_tally, delay, NO);
        os_unfair_lock_unlock(&tally_lock);
        return event;
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskOtherMouseDown
                                          handler:^NSEvent *(NSEvent *event) {
        os_unfair_lock_lock(&tally_lock);
        clicks++;
        if (event.type == NSEventTypeLeftMouseDown) left_clicks++;
        os_unfair_lock_unlock(&tally_lock);
        return event;
    }];
}

/* ---- Once a second ---- */

static NSString *grouped(unsigned long long value)
{
    return [NSNumberFormatter localizedStringFromNumber:@(value) numberStyle:NSNumberFormatterDecimalStyle];
}

- (void)tick
{
    Tally gc, pointer;
    unsigned long long secondClicks, secondLeft, secondActivations, secondResigns;
    double gcEvent, gcMedia;
    NSDictionary *hid = hid_started ? take_hid_second() : nil;

    os_unfair_lock_lock(&tally_lock);
    gc = gc_tally;
    pointer = pointer_tally;
    memset(&gc_tally, 0, sizeof(gc_tally));
    memset(&pointer_tally, 0, sizeof(pointer_tally));
    secondClicks = clicks; secondLeft = left_clicks; secondActivations = activations; secondResigns = resigns;
    clicks = left_clicks = activations = resigns = 0;
    gcEvent = gc_sample_event; gcMedia = gc_sample_media;
    gc_sample_event = gc_sample_media = 0;
    os_unfair_lock_unlock(&tally_lock);

    second++;
    NSMutableDictionary *line = [@{@"t": @(second), @"active": @(NSApp.isActive), @"captured": @(captured),
                                   @"fullscreen": @((window.styleMask & NSWindowStyleMaskFullScreen) != 0),
                                   @"clicks": @(secondClicks), @"left_clicks": @(secondLeft),
                                   @"activations": @(secondActivations), @"resigns": @(secondResigns),
                                   @"gcmouse": tally_json(&gc, NO), @"gcmouse_mice": @(gcMice.count),
                                   @"pointer": tally_json(&pointer, NO)} mutableCopy];
    if (hid) line[@"hid"] = hid;
    if (gcMedia) line[@"gcmouse_clock_sample"] = @{@"last_event": @(gcEvent), @"media_time": @(gcMedia)};
    emit(line);

    unsigned long long hidReports = [hid[@"reports"] unsignedLongLongValue], hidMotion = [hid[@"motion"] unsignedLongLongValue];
    unsigned long long childReports = [childSecond[@"hid"][@"reports"] unsignedLongLongValue];
    unsigned long long childMotion = [childSecond[@"hid"][@"motion"] unsignedLongLongValue];
    unsigned long long values[4][2] = {{hidReports, hidMotion}, {childReports, childMotion},
                                       {gc.reports, (unsigned long long)gc.motion}, {pointer.reports, (unsigned long long)pointer.motion}};
    for (int i = 0; i < 4; i++) { totals[i][0] += values[i][0]; totals[i][1] += values[i][1]; }
    childSecond = nil;

    NSMutableString *text = [NSMutableString string];
    [text appendFormat:@"Mouse hardware, read directly:              %@ updates a second\n",
     hid ? grouped(hidReports) : @"not yet (needs Input Monitoring)"];
    [text appendFormat:@"The same, as Recall would read it (Rosetta): %@ updates a second\n", child ? grouped(childReports) : @"–"];
    [text appendFormat:@"Apple’s game layer (what Recall uses today): %@ updates a second", grouped(gc.reports)];
    if (hid && hidMotion >= 500)
        [text appendFormat:@", %.0f%% of the hardware’s movement", 100.0 * gc.motion / hidMotion];
    [text appendFormat:@"\nmacOS pointer:                               %@ updates a second\n", grouped(pointer.reports)];
    [text appendFormat:@"Recording for %llu:%02llu", second / 60, second % 60];
    stats.stringValue = text;
    if (!hid_started || hid_open_result != kIOReturnSuccess) [self checkAccess];
}

- (void)finishLog
{
    static BOOL finished;
    if (finished) return;
    finished = YES;
    capture(NO);
    emit(@{@"event": @"finish", @"seconds": @(second),
           @"totals": @{@"hid": @{@"reports": @(totals[0][0]), @"motion": @(totals[0][1])},
                        @"hid_child": @{@"reports": @(totals[1][0]), @"motion": @(totals[1][1])},
                        @"gcmouse": @{@"reports": @(totals[2][0]), @"motion": @(totals[2][1])},
                        @"pointer": @{@"reports": @(totals[3][0]), @"motion": @(totals[3][1])}}});
    if (childInput) close(childInput);
    if (child) kill(child, SIGTERM);
    dispatch_sync(log_queue, ^{ [log_file synchronizeFile]; });
}

- (void)finish:(id)sender __unused
{
    [self finishLog];
    /* The results file, ready to drag into a message. */
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:log_path]]];
    [NSApp terminate:nil];
}

- (void)applicationWillTerminate:(NSNotification *)note __unused { [self finishLog]; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app __unused { return YES; }
@end

int main(int argc, const char *argv[])
{
    @autoreleasepool
    {
        mach_timebase_info_data_t timebase;
        int value = 0;
        size_t size = sizeof(value);

        mach_timebase_info(&timebase);
        hid_ns_per_tick = (double)timebase.numer / timebase.denom;
        if (sysctlbyname("sysctl.proc_translated", &value, &size, NULL, 0) == 0) translated = value == 1;
        if (argc > 1 && !strcmp(argv[1], "--child")) return child_main();
        /* What the probe would find, without opening anything (so without Input Monitoring). */
        if (argc > 1 && !strcmp(argv[1], "--self-check"))
        {
            unsigned long long frequency = 0;
            size_t length = sizeof(frequency);
            sysctlbyname("hw.tbfrequency", &frequency, &length, NULL, 0);
            child_emit(@{@"source": @"self-check", @"translated": @(translated), @"ns_per_tick": @(hid_ns_per_tick),
                         @"tb_frequency": @(frequency), @"uptime_ns": @(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)),
                         @"mach_absolute_time": @(mach_absolute_time()), @"responsible_pid": responsible_pid(),
                         @"access": access_name(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)), @"mice": registry_mice()});
            return 0;
        }

        static ProbeController *controller;
        NSApplication *app = NSApplication.sharedApplication;
        controller = [ProbeController new];
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        app.delegate = controller;
        [app run];
    }
    return 0;
}
