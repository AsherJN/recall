// Mouse rate check: how many movement updates a second reach an app from each
// macOS source, with the pointer frozen as in a game.
//
//   pointer  AppKit mouse events (NSEvent deltaX/deltaY): Wine's source today.
//   game     GCMouse from the Game Controller framework: the raw-input candidate.
//   mouse    the mouse's own HID reports. Only with --direct, because macOS needs
//            Input Monitoring permission to read a mouse directly.
//
// The player clicks Start and moves the mouse for 30 seconds. The pointer is
// hidden and frozen, and AppKit's merging of mouse events (coalescing) switches
// on and off every 5 seconds. The check writes summary.json and samples.csv to
// --out. tests/mouselook/rate_check.py builds and opens it.

#import <Cocoa/Cocoa.h>
#import <GameController/GameController.h>
#import <IOKit/hid/IOHIDLib.h>
#import <IOKit/hid/IOHIDUsageTables.h>
#import <IOKit/hidsystem/IOHIDLib.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdatomic.h>
#include <sys/sysctl.h>

enum { FEED_MOUSE, FEED_POINTER, FEED_GAME, FEED_COUNT };
static NSString *const feed_keys[FEED_COUNT] = { @"mouse", @"pointer", @"game" };
static NSString *const feed_titles[FEED_COUNT] = {
    @"Your mouse, read directly", @"macOS pointer events (Wine today)", @"Game-controller input (raw input)" };

enum { TEST_SECONDS = 30, PHASE_SECONDS = 5, MAX_SOURCES = 16, MAX_TOGGLES = 32, SNAPSHOTS = 5 };
static const size_t capacity = 1 << 20; /* per feed; 8,000 a second for 30 s is 240,000 */
static const uint64_t second_ns = 1000000000ull, window_ns = 250000000ull, late_ns = 250000000ull;

typedef struct {
    uint64_t recv;   /* ns on the mach clock when this process received it */
    uint64_t stamp;  /* ns of the hardware event as the source reports it; 0 if none */
    float dx, dy;
    uint16_t source; /* device within the feed */
    uint8_t merging; /* AppKit mouse coalescing was on */
} sample;

static struct { sample *samples; _Atomic size_t count; } feeds[FEED_COUNT];
static atomic_bool recording;
static atomic_int merging_on = 1;
static mach_timebase_info_data_t timebase;
static uint64_t toggle_at[MAX_TOGGLES];
static int toggle_state[MAX_TOGGLES], toggles;
static dispatch_queue_t hid_queue, game_queue;
static NSMutableArray *hid_devices;                  /* opened IOHIDDeviceRefs */
static NSMutableArray<NSString *> *mouse_names, *game_names;
static NSMutableArray<GCMouse *> *game_mice;

static uint64_t ns_from_ticks(uint64_t ticks) { return ticks * timebase.numer / timebase.denom; }
static uint64_t now_ns(void) { return ns_from_ticks(mach_absolute_time()); }
static uint64_t ns_from_seconds(double seconds) { return seconds > 0 ? (uint64_t)llround(seconds * 1e9) : 0; }

/* Runs only on the feed's own thread or queue. The X and Y values of one mouse
   report arrive separately with the same timestamp and become one sample. */
static void record(int which, uint64_t stamp, double dx, double dy, unsigned source, bool join_report)
{
    if (!atomic_load_explicit(&recording, memory_order_acquire)) return;
    size_t n = atomic_load_explicit(&feeds[which].count, memory_order_relaxed);
    sample *last = n ? &feeds[which].samples[n - 1] : NULL;
    if (join_report && last && last->stamp == stamp && last->source == source) {
        last->dx += (float)dx;
        last->dy += (float)dy;
        return;
    }
    if (n == capacity) return;
    feeds[which].samples[n] = (sample){ now_ns(), stamp, (float)dx, (float)dy, (uint16_t)source,
                                        (uint8_t)atomic_load(&merging_on) };
    atomic_store_explicit(&feeds[which].count, n + 1, memory_order_release);
}

static void log_merging(uint64_t at, int on)
{
    if (toggles < MAX_TOGGLES) { toggle_at[toggles] = at; toggle_state[toggles++] = on; }
}

static void set_merging(int on)
{
    NSEvent.mouseCoalescingEnabled = on;
    atomic_store(&merging_on, on);
    log_merging(now_ns(), on);
}

/* ---- Sources ---- */

static void hid_value(void *context, IOReturn result, void *sender, IOHIDValueRef value)
{
    IOHIDElementRef element = IOHIDValueGetElement(value);
    uint32_t usage = IOHIDElementGetUsage(element);
    if (IOHIDElementGetUsagePage(element) != kHIDPage_GenericDesktop || !IOHIDElementIsRelative(element) ||
        (usage != kHIDUsage_GD_X && usage != kHIDUsage_GD_Y))
        return;
    CFIndex delta = IOHIDValueGetIntegerValue(value);
    if (delta)
        record(FEED_MOUSE, ns_from_ticks(IOHIDValueGetTimeStamp(value)), usage == kHIDUsage_GD_X ? delta : 0,
               usage == kHIDUsage_GD_Y ? delta : 0, (unsigned)(uintptr_t)context, true);
}

static id registry_value(io_service_t service, NSString *key)
{
    return CFBridgingRelease(IORegistryEntryCreateCFProperty(service, (__bridge CFStringRef)key, kCFAllocatorDefault, 0));
}

static BOOL has_usage(NSArray *pairs, uint32_t page, uint32_t usage)
{
    for (NSDictionary *pair in pairs)
        if ([pair isKindOfClass:[NSDictionary class]] && [pair[@kIOHIDDeviceUsagePageKey] unsignedIntValue] == page &&
            [pair[@kIOHIDDeviceUsageKey] unsignedIntValue] == usage)
            return YES;
    return NO;
}

/* Pointing interfaces on this Mac, from the device registry. With open, starts
   reading every one that cannot type. */
static NSArray<NSDictionary *> *pointing_devices(BOOL open)
{
    NSMutableArray *found = [NSMutableArray array];
    io_iterator_t iterator;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOHIDDeviceKey), &iterator) != KERN_SUCCESS)
        return found;
    for (io_service_t service; (service = IOIteratorNext(iterator)); IOObjectRelease(service)) {
        NSArray *pairs = registry_value(service, @kIOHIDDeviceUsagePairsKey);
        if (![pairs isKindOfClass:[NSArray class]] ||
            !(has_usage(pairs, kHIDPage_GenericDesktop, kHIDUsage_GD_Mouse) ||
              has_usage(pairs, kHIDPage_GenericDesktop, kHIDUsage_GD_Pointer)))
            continue;
        BOOL types = has_usage(pairs, kHIDPage_GenericDesktop, kHIDUsage_GD_Keyboard) ||
                     has_usage(pairs, kHIDPage_GenericDesktop, kHIDUsage_GD_Keypad);
        NSString *name = [NSString stringWithFormat:@"%@ (%@)", registry_value(service, @kIOHIDProductKey) ?: @"?",
                                   registry_value(service, @kIOHIDTransportKey) ?: @"?"];
        NSMutableDictionary *info = [@{ @"name": name, @"can_type": @(types),
                                        @"needs_permission": @([registry_value(service, @"RequiresTCCAuthorization") isEqual:@YES]) }
                                        mutableCopy];
        /* An interface that can type would also see keystrokes: never open one. */
        IOHIDDeviceRef device = open && !types && hid_devices.count < MAX_SOURCES ? IOHIDDeviceCreate(kCFAllocatorDefault, service) : NULL;
        if (device) {
            IOReturn result = IOHIDDeviceOpen(device, kIOHIDOptionsTypeNone);
            info[@"open_result"] = [NSString stringWithFormat:@"0x%08x", result];
            if (result == kIOReturnSuccess) {
                info[@"source"] = @(hid_devices.count);
                IOHIDDeviceRegisterInputValueCallback(device, hid_value, (void *)(uintptr_t)hid_devices.count);
                IOHIDDeviceSetDispatchQueue(device, hid_queue);
                IOHIDDeviceActivate(device);
                [hid_devices addObject:(__bridge id)device];
                [mouse_names addObject:name];
            }
            CFRelease(device);
        }
        [found addObject:info];
    }
    IOObjectRelease(iterator);
    return found;
}

static NSString *game_mouse_name(GCMouse *mouse) { return mouse.vendorName ?: mouse.productCategory ?: @"mouse"; }

static void attach_game_mouse(GCMouse *mouse)
{
    if ([game_mice containsObject:mouse] || game_mice.count >= MAX_SOURCES) return;
    unsigned source = (unsigned)game_mice.count;
    [game_mice addObject:mouse];
    [game_names addObject:game_mouse_name(mouse)];
    mouse.handlerQueue = game_queue;
    mouse.mouseInput.mouseMovedHandler = ^(GCMouseInput *input, float dx, float dy) {
        if (dx != 0 || dy != 0)
            record(FEED_GAME, ns_from_seconds(input.lastEventTimestamp), dx, dy, source, false);
    };
}

static NSString *input_monitoring(void)
{
    switch (IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)) {
    case kIOHIDAccessTypeGranted: return @"granted";
    case kIOHIDAccessTypeDenied: return @"denied";
    default: return @"not asked";
    }
}

static NSDictionary *system_info(void)
{
    char model[64] = "";
    size_t size = sizeof(model);
    sysctlbyname("hw.model", model, &size, NULL, 0);
    id speed = CFBridgingRelease(CFPreferencesCopyValue(CFSTR("com.apple.mouse.scaling"), kCFPreferencesAnyApplication,
                                                        kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    id linear = CFBridgingRelease(CFPreferencesCopyValue(CFSTR("com.apple.mouse.linear"), kCFPreferencesAnyApplication,
                                                         kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    return @{ @"macos": NSProcessInfo.processInfo.operatingSystemVersionString, @"model": @(model),
              @"display_max_fps": @(NSScreen.mainScreen.maximumFramesPerSecond),
              @"tracking_speed": speed ?: NSNull.null, @"acceleration_off": linear ?: NSNull.null,
              @"input_monitoring": input_monitoring() };
}

/* ---- Analysis ---- */

typedef struct { sample *s; size_t n; unsigned source; } series;
typedef struct { double *v; size_t n, cap; } list;

static void push(list *l, double x)
{
    if (l->n == l->cap) l->v = realloc(l->v, (l->cap = l->cap ? l->cap * 2 : 1024) * sizeof(double));
    l->v[l->n++] = x;
}

static int by_value(const void *a, const void *b)
{
    double x = *(const double *)a, y = *(const double *)b;
    return (x > y) - (x < y);
}

static double quantile(list *l, double q) /* sorts in place */
{
    if (!l->n) return NAN;
    qsort(l->v, l->n, sizeof(double), by_value);
    return l->v[(size_t)fmin(l->n - 1, floor(q * l->n))];
}

static double mean(const list *l)
{
    double sum = 0;
    for (size_t i = 0; i < l->n; i++) sum += l->v[i];
    return l->n ? sum / l->n : NAN;
}

static id number(double value, int digits)
{
    if (!isfinite(value)) return NSNull.null;
    return [NSDecimalNumber decimalNumberWithString:[NSString stringWithFormat:@"%.*f", digits, value]
                                             locale:@{ NSLocaleDecimalSeparator: @"." }];
}

/* The busiest device's samples. Pointer events carry no device, so all of them. */
static series select_series(int which)
{
    size_t n = atomic_load(&feeds[which].count), counts[MAX_SOURCES] = { 0 };
    const sample *all = feeds[which].samples;
    for (size_t i = 0; i < n; i++) counts[all[i].source % MAX_SOURCES]++;
    series out = { malloc((n ? n : 1) * sizeof(sample)), 0, 0 };
    for (unsigned i = 1; i < MAX_SOURCES; i++)
        if (counts[i] > counts[out.source]) out.source = i;
    for (size_t i = 0; i < n; i++)
        if (which == FEED_POINTER || all[i].source == out.source) out.s[out.n++] = all[i];
    return out;
}

/* Whether a series carries hardware timestamps on this process's clock. */
static bool hardware_stamps(series s)
{
    size_t ok = 0;
    for (size_t i = 0; i < s.n; i++) {
        int64_t age = (int64_t)(s.s[i].recv - s.s[i].stamp);
        ok += s.s[i].stamp && age > -1000000 && age < (int64_t)late_ns;
    }
    return s.n && ok * 10 >= s.n * 9;
}

/* 1 if merging was on for at least 90% of [from, to), 0 if off, -1 if mixed. */
static int merging_during(uint64_t from, uint64_t to)
{
    uint64_t on = 0;
    for (int i = 0; i < toggles; i++) {
        uint64_t a = MAX(from, toggle_at[i]), b = MIN(to, i + 1 < toggles ? toggle_at[i + 1] : to);
        if (toggle_state[i] && b > a) on += b - a;
    }
    double share = (double)on / (double)(to - from);
    return share >= 0.9 ? 1 : share <= 0.1 ? 0 : -1;
}

/* For each reference report, the time until the delivery that carried it, by merging state. */
static void match_delays(series ref, series f, bool f_stamped, list out[2])
{
    size_t j = 0;
    for (size_t i = 0; i < ref.n; i++) {
        const sample *r = &ref.s[i];
        while (j < f.n && (f_stamped ? f.s[j].stamp < r->stamp : f.s[j].recv < r->recv)) j++;
        if (j == f.n) break;
        int64_t delay = (int64_t)(f.s[j].recv - r->stamp);
        if (delay >= 0 && delay < (int64_t)late_ns) push(&out[f.s[j].merging ? 1 : 0], delay / 1e6);
    }
}

static void own_delays(series s, list *out)
{
    for (size_t i = 0; i < s.n; i++) {
        int64_t age = (int64_t)(s.s[i].recv - s.s[i].stamp);
        if (s.s[i].stamp && age >= 0 && age < (int64_t)late_ns) push(out, age / 1e6);
    }
}

static void window_sums(series s, bool stamped, uint64_t start, size_t windows, double *sums, int offset)
{
    for (size_t i = 0; i < s.n; i++) {
        int64_t at = (int64_t)((stamped ? s.s[i].stamp : s.s[i].recv) - start);
        if (at < 0 || (uint64_t)at >= windows * window_ns) continue;
        sums[(at / window_ns) * 4 + offset] += s.s[i].dx;
        sums[(at / window_ns) * 4 + offset + 1] += s.s[i].dy;
    }
}

/* Feed units per reference unit (least squares over 250 ms windows) and how well that fits (1 = exactly). */
static NSDictionary *unit_fit(series ref, bool ref_stamped, series f, bool f_stamped, uint64_t start, size_t seconds)
{
    size_t windows = seconds * (second_ns / window_ns);
    double *sums = calloc(windows * 4 + 4, sizeof(double)), fm[2] = { 0 }, mm[2] = { 0 }, ff[2] = { 0 };
    window_sums(ref, ref_stamped, start, windows, sums, 0);
    window_sums(f, f_stamped, start, windows, sums, 2);
    for (size_t w = 0; w < windows; w++)
        for (int axis = 0; axis < 2; axis++) {
            double m = sums[w * 4 + axis], v = sums[w * 4 + 2 + axis];
            fm[axis] += v * m;
            mm[axis] += m * m;
            ff[axis] += v * v;
        }
    free(sums);
    return @{ @"x": number(fm[0] / mm[0], 4), @"y": number(fm[1] / mm[1], 4),
              @"fit_x": number(fabs(fm[0]) / sqrt(ff[0] * mm[0]), 3), @"fit_y": number(fabs(fm[1]) / sqrt(ff[1] * mm[1]), 3) };
}

static double median_rate(double *counts, const bool *moving, const int *mode, size_t seconds, int wanted, size_t *used)
{
    list l = { 0 };
    for (size_t b = 0; b < seconds; b++)
        if (moving[b] && (wanted < 0 || mode[b] == wanted)) push(&l, counts[b]);
    double median = quantile(&l, 0.5);
    if (used) *used = l.n;
    free(l.v);
    return median;
}

static NSString *whole(double value)
{
    return [NSNumberFormatter localizedStringFromNumber:@(round(value)) numberStyle:NSNumberFormatterDecimalStyle];
}

static NSString *behind(double delay_ms)
{
    return isfinite(delay_ms) ? [NSString stringWithFormat:@", %.1f ms behind the mouse on average", delay_ms] : @"";
}

static NSArray<NSString *> *verdict(double mouse, double on, double off, double game, double on_ms, double off_ms,
                                    double game_ms, size_t moving)
{
    if (moving < 6)
        return @[ @"Not enough movement was measured. Click Run Again and keep the mouse moving in circles until the bar fills." ];
    NSMutableArray *lines = [NSMutableArray array];
    if (isfinite(mouse)) [lines addObject:[NSString stringWithFormat:@"Your mouse sent about %@ updates a second.", whole(mouse)]];
    if (isfinite(on))
        [lines addObject:[NSString stringWithFormat:@"macOS pointer events, which Wine uses today, arrived about %@ times a second%@.",
                                   whole(on), behind(on_ms)]];
    if (isfinite(off))
        [lines addObject:[NSString stringWithFormat:@"With macOS merging turned off, they arrived about %@ times a second%@.",
                                   whole(off), behind(off_ms)]];
    if (isfinite(game) && game > 0)
        [lines addObject:[NSString stringWithFormat:@"Game-controller input, the raw-input candidate, arrived about %@ times a second%@.",
                                   whole(game), behind(game_ms)]];
    else
        [lines addObject:@"No game-controller input arrived."];
    if (isfinite(game) && isfinite(on) && on > 0 && game >= 2 * on)
        [lines addObject:[NSString stringWithFormat:@"Raw input would give the game about %.0f times as many updates as it gets today.", game / on]];
    else if (isfinite(game) && isfinite(on) && game > 0)
        [lines addObject:@"Game-controller input was not faster than pointer events on this Mac."];
    if (isfinite(off) && isfinite(on) && on > 0 && off >= 2 * on)
        [lines addObject:@"Turning merging off also lets pointer events keep up."];
    return lines;
}

static NSDictionary *analyse(uint64_t start, uint64_t end, BOOL completed, NSDictionary *context)
{
    size_t seconds = (size_t)((end - start) / second_ns);
    series s[FEED_COUNT];
    bool stamped[FEED_COUNT];
    double *count[FEED_COUNT];
    for (int f = 0; f < FEED_COUNT; f++) {
        s[f] = select_series(f);
        stamped[f] = hardware_stamps(s[f]);
        count[f] = calloc(seconds + 1, sizeof(double));
        for (size_t i = 0; i < s[f].n; i++) {
            int64_t at = (int64_t)(s[f].s[i].recv - start);
            if (at >= 0 && (uint64_t)at < seconds * second_ns) count[f][at / second_ns] += 1;
        }
    }

    /* A second counts as moving when the most direct source delivered something in
       at least 80% of its 20 ms slots, whatever that source's rate. */
    int motion = s[FEED_MOUSE].n ? FEED_MOUSE : s[FEED_GAME].n ? FEED_GAME : FEED_POINTER;
    const uint64_t slot_ns = 20000000;
    const size_t slots = second_ns / slot_ns;
    bool *occupied = calloc(seconds * slots + 1, sizeof(bool));
    for (size_t i = 0; i < s[motion].n; i++) {
        int64_t at = (int64_t)(s[motion].s[i].recv - start);
        if (at >= 0 && (uint64_t)at < seconds * second_ns) occupied[at / slot_ns] = true;
    }
    bool *moving = calloc(seconds + 1, sizeof(bool));
    int *mode = calloc(seconds + 1, sizeof(int));
    size_t moving_seconds = 0;
    NSMutableArray *per_second = [NSMutableArray array];
    for (size_t b = 0; b < seconds; b++) {
        size_t busy = 0;
        for (size_t k = 0; k < slots; k++) busy += occupied[b * slots + k];
        moving[b] = busy * 10 >= slots * 8;
        moving_seconds += moving[b];
        mode[b] = merging_during(start + b * second_ns, start + (b + 1) * second_ns);
        [per_second addObject:@{ @"second": @(b), @"moving": @((BOOL)moving[b]),
                                 @"merging": mode[b] < 0 ? @"mixed" : mode[b] ? @"on" : @"off",
                                 @"mouse": @(count[FEED_MOUSE][b]), @"pointer": @(count[FEED_POINTER][b]),
                                 @"game": @(count[FEED_GAME][b]) }];
    }

    size_t on_seconds = 0, off_seconds = 0;
    double rate_mouse = s[FEED_MOUSE].n ? median_rate(count[FEED_MOUSE], moving, mode, seconds, -1, NULL) : NAN;
    double rate_game = game_mice.count || s[FEED_GAME].n ? median_rate(count[FEED_GAME], moving, mode, seconds, -1, NULL) : NAN;
    double rate_on = median_rate(count[FEED_POINTER], moving, mode, seconds, 1, &on_seconds);
    double rate_off = median_rate(count[FEED_POINTER], moving, mode, seconds, 0, &off_seconds);

    /* Delays are measured from the hardware time of each report of the fastest
       stamped source: the mouse itself, or game-controller input if it is at
       least twice as fast as merged pointer events. */
    int reference = s[FEED_MOUSE].n ? FEED_MOUSE
                    : stamped[FEED_GAME] && isfinite(rate_game) && rate_game >= 2 * rate_on ? FEED_GAME : -1;
    list pointer_delay[2] = { { 0 }, { 0 } }, game_delay[2] = { { 0 }, { 0 } }, reference_delay = { 0 };
    list pointer_age[2] = { { 0 }, { 0 } }, game_age = { 0 };
    if (reference >= 0) {
        own_delays(s[reference], &reference_delay);
        match_delays(s[reference], s[FEED_POINTER], stamped[FEED_POINTER], pointer_delay);
        if (reference == FEED_MOUSE) match_delays(s[FEED_MOUSE], s[FEED_GAME], stamped[FEED_GAME], game_delay);
    }
    if (stamped[FEED_POINTER])
        for (size_t i = 0; i < s[FEED_POINTER].n; i++)
            push(&pointer_age[s[FEED_POINTER].s[i].merging ? 1 : 0],
                 (int64_t)(s[FEED_POINTER].s[i].recv - s[FEED_POINTER].s[i].stamp) / 1e6);
    if (stamped[FEED_GAME]) own_delays(s[FEED_GAME], &game_age);
    for (size_t i = 0; i < game_delay[1].n; i++) push(&game_delay[0], game_delay[1].v[i]);
    double delay_on = mean(&pointer_delay[1]), delay_off = mean(&pointer_delay[0]);
    double delay_game = reference == FEED_GAME ? mean(&reference_delay) : mean(&game_delay[0]);

    NSMutableDictionary *units = [NSMutableDictionary dictionary];
    if (s[FEED_MOUSE].n) {
        units[@"pointer_per_mouse"] = unit_fit(s[FEED_MOUSE], stamped[FEED_MOUSE], s[FEED_POINTER], stamped[FEED_POINTER], start, seconds);
        if (s[FEED_GAME].n)
            units[@"game_per_mouse"] = unit_fit(s[FEED_MOUSE], stamped[FEED_MOUSE], s[FEED_GAME], stamped[FEED_GAME], start, seconds);
    }
    if (s[FEED_GAME].n)
        units[@"pointer_per_game"] = unit_fit(s[FEED_GAME], stamped[FEED_GAME], s[FEED_POINTER], stamped[FEED_POINTER], start, seconds);

    NSArray *mouse_list = context[@"mouse_names"], *game_list = context[@"game_names"];
    NSDictionary *summary = @{
        @"schema": @1,
        @"completed": @(completed),
        @"seconds": @(seconds),
        @"moving_seconds": @(moving_seconds),
        @"reference": reference >= 0 ? feed_keys[reference] : NSNull.null,
        @"mouse": @{ @"available": @((BOOL)(s[FEED_MOUSE].n > 0)),
                     @"device": s[FEED_MOUSE].n && s[FEED_MOUSE].source < mouse_list.count ? mouse_list[s[FEED_MOUSE].source] : NSNull.null,
                     @"per_s": number(rate_mouse, 0),
                     @"delay_ms": number(reference == FEED_MOUSE ? mean(&reference_delay) : NAN, 2) },
        @"pointer": @{ @"stamps": stamped[FEED_POINTER] ? @"hardware" : @"receive",
                       @"merging_on": @{ @"per_s": number(rate_on, 0), @"seconds": @(on_seconds),
                                         @"delay_ms": number(delay_on, 2), @"age_ms": number(mean(&pointer_age[1]), 2) },
                       @"merging_off": @{ @"per_s": number(rate_off, 0), @"seconds": @(off_seconds),
                                          @"delay_ms": number(delay_off, 2), @"age_ms": number(mean(&pointer_age[0]), 2) } },
        @"game": @{ @"available": @((BOOL)(s[FEED_GAME].n > 0)),
                    @"device": s[FEED_GAME].n && s[FEED_GAME].source < game_list.count ? game_list[s[FEED_GAME].source] : NSNull.null,
                    @"stamps": stamped[FEED_GAME] ? @"hardware" : @"receive",
                    @"per_s": number(rate_game, 0), @"delay_ms": number(delay_game, 2),
                    @"age_ms": number(mean(&game_age), 2) },
        @"units": units,
        @"per_second": per_second,
        @"verdict": verdict(rate_mouse, rate_on, rate_off, rate_game, delay_on, delay_off, delay_game, moving_seconds),
        @"context": context[@"system"] ?: @{},
        @"devices": @{ @"pointing": context[@"pointing"] ?: @[], @"game": game_list ?: @[] },
    };
    for (int f = 0; f < FEED_COUNT; f++) { free(s[f].s); free(count[f]); }
    for (int m = 0; m < 2; m++) { free(pointer_delay[m].v); free(game_delay[m].v); free(pointer_age[m].v); }
    free(reference_delay.v); free(game_age.v); free(occupied); free(moving); free(mode);
    return summary;
}

static void write_samples(NSString *path, uint64_t start)
{
    FILE *out = fopen(path.fileSystemRepresentation, "w");
    if (!out) return;
    fprintf(out, "feed,source,recv_us,stamp_us,dx,dy,merging\n");
    for (int f = 0; f < FEED_COUNT; f++) {
        size_t n = atomic_load(&feeds[f].count);
        for (size_t i = 0; i < n; i++) {
            const sample *x = &feeds[f].samples[i];
            fprintf(out, "%s,%u,%.1f,", feed_keys[f].UTF8String, x->source, (int64_t)(x->recv - start) / 1e3);
            if (x->stamp) fprintf(out, "%.1f", (int64_t)(x->stamp - start) / 1e3);
            fprintf(out, ",%g,%g,%u\n", x->dx, x->dy, x->merging);
        }
    }
    fclose(out);
}

static void write_json(id object, NSString *path)
{
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:NULL];
    if (path) [data writeToFile:path atomically:YES];
    else fwrite(data.bytes, 1, data.length, stdout), fputc('\n', stdout);
}

/* ---- Window ---- */

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
    BOOL direct, running;
    NSWindow *window;
    NSTextField *rates[FEED_COUNT], *merging, *status, *results;
    NSProgressIndicator *progress;
    NSButton *button;
    NSTimer *phaseTimer;
    NSArray *pointing;
    uint64_t started, snapshotAt[SNAPSHOTS];
    size_t snapshot[SNAPSHOTS][FEED_COUNT], ticks;
}

- (instancetype)initWithOutput:(NSString *)output direct:(BOOL)readMouse
{
    if ((self = [super init])) { outDir = output; direct = readMouse; }
    return self;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    NSMenu *menu = [NSMenu new], *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"Quit Mouse Rate Check" action:@selector(terminate:) keyEquivalent:@"q"];
    [menu addItemWithTitle:@"" action:NULL keyEquivalent:@""].submenu = appMenu;
    NSApp.mainMenu = menu;

    game_queue = dispatch_queue_create("mouse-rate-check.game", DISPATCH_QUEUE_SERIAL);
    hid_queue = dispatch_queue_create("mouse-rate-check.hid", DISPATCH_QUEUE_SERIAL);
    if (direct) IOHIDRequestAccess(kIOHIDRequestTypeListenEvent);
    pointing = pointing_devices(direct);
    for (GCMouse *mouse in GCMouse.mice) attach_game_mouse(mouse);
    [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidConnectNotification object:nil queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *n) { attach_game_mouse(n.object); }];
    NSEventMask moves = NSEventMaskMouseMoved | NSEventMaskLeftMouseDragged | NSEventMaskRightMouseDragged | NSEventMaskOtherMouseDragged;
    [NSEvent addLocalMonitorForEventsMatchingMask:moves handler:^NSEvent *(NSEvent *event) {
        if (event.deltaX != 0 || event.deltaY != 0)
            record(FEED_POINTER, ns_from_seconds(event.timestamp), event.deltaX, event.deltaY, 0, false);
        return event;
    }];
    [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        if (event.keyCode != 53 || !self->running) return event; /* Esc */
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
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 568, 460)
                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                           backing:NSBackingStoreBuffered defer:NO];
    window.title = @"Mouse Rate Check";
    window.delegate = self;
    window.releasedWhenClosed = NO;
    window.acceptsMouseMovedEvents = YES;

    NSTextField *intro = text(@"This compares how often each macOS source passes your mouse movement to an app.\n\n"
                              @"Click Start, then move the mouse in steady circles, like turning in game, until the bar fills "
                              @"(30 seconds). The pointer disappears while the check runs. Press Esc to stop early.",
                              13, NSFontWeightRegular);
    NSMutableArray *rows = [NSMutableArray array];
    NSTextField *heading = [NSTextField labelWithString:@"updates per second"];
    heading.textColor = NSColor.secondaryLabelColor;
    [rows addObject:@[ [NSTextField labelWithString:@""], heading ]];
    for (int f = direct ? FEED_MOUSE : FEED_POINTER; f < FEED_COUNT; f++) {
        rates[f] = [NSTextField labelWithString:@"–"];
        rates[f].font = [NSFont monospacedDigitSystemFontOfSize:22 weight:NSFontWeightSemibold];
        NSTextField *title = [NSTextField labelWithString:feed_titles[f]];
        title.font = [NSFont systemFontOfSize:14 weight:NSFontWeightMedium];
        [rows addObject:@[ title, rates[f] ]];
    }
    merging = [NSTextField labelWithString:@"–"];
    NSTextField *mergingTitle = [NSTextField labelWithString:@"macOS merging (switches every 5 s)"];
    mergingTitle.textColor = merging.textColor = NSColor.secondaryLabelColor;
    [rows addObject:@[ mergingTitle, merging ]];
    NSGridView *grid = [NSGridView gridViewWithViews:rows];
    grid.columnSpacing = 24;
    grid.rowSpacing = 10;
    [grid columnAtIndex:1].xPlacement = NSGridCellPlacementTrailing;
    [grid columnAtIndex:0].width = 330;

    progress = [NSProgressIndicator new];
    progress.indeterminate = NO;
    progress.minValue = 0;
    progress.maxValue = TEST_SECONDS;
    status = text(@"", 13, NSFontWeightRegular);
    results = text(@"", 13, NSFontWeightRegular);
    results.selectable = YES;
    button = [NSButton buttonWithTitle:@"Start" target:self action:@selector(start:)];
    button.keyEquivalent = @"\r";

    NSStackView *stack = [NSStackView stackViewWithViews:@[ intro, grid, progress, status, results, button ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 16;
    stack.edgeInsets = NSEdgeInsetsMake(24, 24, 24, 24);
    [progress.widthAnchor constraintEqualToConstant:520].active = YES;
    window.contentView = stack;
    [self fit];
}

/* Lays out the window without showing it and fills in a result with no movement. */
- (NSSize)smokeTest
{
    [self buildWindow];
    started = now_ns();
    NSDictionary *summary = analyse(started, started + TEST_SECONDS * second_ns, NO, @{});
    results.stringValue = [summary[@"verdict"] componentsJoinedByString:@"\n"];
    [self fit];
    write_json(summary, nil);
    return window.frame.size;
}

/* Sizes the window to its contents, keeping its top edge in place. */
- (void)fit
{
    NSRect frame = window.frame;
    NSSize size = [window frameRectForContentRect:(NSRect){ NSZeroPoint, window.contentView.fittingSize }].size;
    [window setFrame:NSMakeRect(frame.origin.x, NSMaxY(frame) - size.height, size.width, size.height) display:YES];
}

- (void)start:(id)sender
{
    if (running) return;
    for (int f = 0; f < FEED_COUNT; f++) atomic_store(&feeds[f].count, 0);
    toggles = 0;
    ticks = 0;
    started = now_ns();
    set_merging(1);
    atomic_store_explicit(&recording, true, memory_order_release);
    running = YES;
    /* Freeze the pointer over the window, as a game does. Re-associating right
       after a warp skips the warp's 0.25 s suppression of mouse events. */
    if (!NSPointInRect(NSEvent.mouseLocation, window.frame)) {
        CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
        CGWarpMouseCursorPosition(CGPointMake(NSMidX(window.frame), top - NSMidY(window.frame)));
        CGAssociateMouseAndMouseCursorPosition(true);
    }
    CGAssociateMouseAndMouseCursorPosition(false);
    [NSCursor hide];
    button.enabled = NO;
    button.title = @"Running…";
    results.stringValue = @"";
    phaseTimer = [NSTimer scheduledTimerWithTimeInterval:PHASE_SECONDS repeats:YES block:^(NSTimer *timer) {
        set_merging(!atomic_load(&merging_on));
    }];
}

- (void)finish:(BOOL)completed
{
    if (!running) return;
    running = NO;
    uint64_t end = now_ns();
    atomic_store_explicit(&recording, false, memory_order_release);
    [phaseTimer invalidate];
    phaseTimer = nil;
    CGAssociateMouseAndMouseCursorPosition(true);
    [NSCursor unhide];
    NSEvent.mouseCoalescingEnabled = YES;
    atomic_store(&merging_on, 1);
    dispatch_sync(hid_queue, ^{});
    dispatch_sync(game_queue, ^{});

    NSDictionary *summary = analyse(started, end, completed, @{ @"mouse_names": mouse_names, @"game_names": game_names,
                                                                @"pointing": pointing, @"system": system_info() });
    NSString *saved = @"";
    if (outDir) {
        [NSFileManager.defaultManager createDirectoryAtPath:outDir withIntermediateDirectories:YES attributes:nil error:NULL];
        write_json(summary, [outDir stringByAppendingPathComponent:@"summary.json"]);
        write_samples([outDir stringByAppendingPathComponent:@"samples.csv"], started);
        saved = [NSString stringWithFormat:@"\n\nSaved in %@. You can close this window.", outDir.lastPathComponent];
    }
    results.stringValue = [[summary[@"verdict"] componentsJoinedByString:@"\n"] stringByAppendingString:saved];
    status.stringValue = completed ? @"Done." : @"Stopped early.";
    button.enabled = YES;
    button.title = @"Run Again";
    [self fit];
}

- (void)tick:(NSTimer *)timer
{
    uint64_t now = now_ns();
    size_t slot = ticks % SNAPSHOTS, old = (ticks + 1) % SNAPSHOTS;
    snapshotAt[slot] = now;
    for (int f = 0; f < FEED_COUNT; f++) snapshot[slot][f] = atomic_load(&feeds[f].count);
    for (int f = 0; f < FEED_COUNT; f++) {
        if (!rates[f]) continue;
        if (!running || ticks < SNAPSHOTS - 1) { rates[f].stringValue = running ? @"…" : @"–"; continue; }
        double rate = (snapshot[slot][f] - snapshot[old][f]) * 1e9 / (double)(now - snapshotAt[old]);
        rates[f].stringValue = whole(rate);
    }
    ticks++;
    if (!running) { merging.stringValue = @"–"; return; }
    merging.stringValue = atomic_load(&merging_on) ? @"on" : @"off";
    double elapsed = (now - started) / 1e9;
    progress.doubleValue = fmin(elapsed, TEST_SECONDS);
    status.stringValue = [NSString stringWithFormat:@"Keep moving the mouse in circles. %.0f seconds left.",
                                   fmax(0, ceil(TEST_SECONDS - elapsed))];
    if (elapsed >= TEST_SECONDS) [self finish:YES];
}

- (void)applicationDidResignActive:(NSNotification *)note { [self finish:NO]; }
- (void)windowWillClose:(NSNotification *)note { [self finish:NO]; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }
- (void)applicationWillTerminate:(NSNotification *)note { [self finish:NO]; }
@end

/* ---- Modes without a window ---- */

/* Lists the mice each source can see. Opens nothing and shows no window. */
static int selftest(void)
{
    [NSApplication sharedApplication];
    NSApp.activationPolicy = NSApplicationActivationPolicyAccessory;
    [NSApp finishLaunching];
    NSMutableArray *connected = [NSMutableArray array];
    [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidConnectNotification object:nil queue:nil
                                                usingBlock:^(NSNotification *n) { [connected addObject:game_mouse_name(n.object)]; }];
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:3]];
    NSMutableArray *mice = [NSMutableArray array];
    for (GCMouse *mouse in GCMouse.mice) [mice addObject:game_mouse_name(mouse)];
    if (!mice.count) [mice addObjectsFromArray:connected];
    write_json(@{ @"game_mice": mice, @"pointing_devices": pointing_devices(NO), @"system": system_info() }, nil);
    return 0;
}

static void add(int which, uint64_t recv, uint64_t stamp, double dx, double dy, unsigned source, int merging)
{
    size_t n = atomic_load(&feeds[which].count);
    feeds[which].samples[n] = (sample){ recv, stamp, (float)dx, (float)dy, (uint16_t)source, (uint8_t)merging };
    atomic_store(&feeds[which].count, n + 1);
}

/* Runs the analysis on a known input: a 1,000 Hz mouse drawing circles; pointer
   events merged to a 120 Hz tick while merging is on and one per report while it
   is off; game-controller input one per report with Y upward. Prints the summary. */
static int synthetic(BOOL with_mouse)
{
    const uint64_t start = 1000 * second_ns, tick = second_ns / 120;
    for (int phase = 0; phase < TEST_SECONDS / PHASE_SECONDS; phase++)
        log_merging(start + phase * PHASE_SECONDS * second_ns, phase % 2 == 0);
    uint64_t next_tick = start + tick, pending_stamp = 0;
    double pending_x = 0, pending_y = 0;
    for (int i = 0; i < TEST_SECONDS * 1000; i++) {
        uint64_t t = start + (uint64_t)i * 1000000 + 500000;
        double angle = 2 * M_PI * (t - start) / 1e9;
        double dx = lround(8 * cos(angle)), dy = lround(8 * sin(angle));
        int on = merging_during(t, t + 1) == 1;
        for (; next_tick <= t; next_tick += tick)
            if (pending_stamp) {
                add(FEED_POINTER, next_tick + 300000, pending_stamp, pending_x * 0.5, pending_y * 0.5, 0, 1);
                pending_x = pending_y = 0;
                pending_stamp = 0;
            }
        if (with_mouse) add(FEED_MOUSE, t + 200000, t, dx, dy, 0, on);
        add(FEED_GAME, t + 500000, t, dx, -dy, 0, on);
        if (on) {
            pending_x += dx;
            pending_y += dy;
            pending_stamp = t;
        } else {
            add(FEED_POINTER, t + 1000000, t, dx * 0.5, dy * 0.5, 0, 0);
        }
    }
    if (with_mouse) /* a second, barely used device */
        for (int i = 0; i < 300; i++) add(FEED_MOUSE, start + i * 100000000ull + 3200000, start + i * 100000000ull + 3000000, 1, 0, 1, 1);
    game_mice = [NSMutableArray array];
    write_json(analyse(start, start + TEST_SECONDS * second_ns, YES,
                       @{ @"mouse_names": @[ @"Synthetic Mouse (USB)", @"Synthetic Trackpad (SPI)" ],
                          @"game_names": @[ @"Synthetic Mouse" ] }),
               nil);
    return 0;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        mach_timebase_info(&timebase);
        for (int f = 0; f < FEED_COUNT; f++) feeds[f].samples = calloc(capacity, sizeof(sample));
        mouse_names = [NSMutableArray array];
        game_names = [NSMutableArray array];
        game_mice = [NSMutableArray array];
        hid_devices = [NSMutableArray array];
        NSString *output = nil;
        BOOL direct = NO;
        for (int i = 1; i < argc; i++) {
            if (!strcmp(argv[i], "--selftest")) return selftest();
            if (!strcmp(argv[i], "--smoke")) {
                [NSApplication sharedApplication].activationPolicy = NSApplicationActivationPolicyProhibited;
                NSSize size = [[[Check alloc] initWithOutput:nil direct:NO] smokeTest];
                fprintf(stderr, "window %.0f x %.0f\n", size.width, size.height);
                return 0;
            }
            if (!strcmp(argv[i], "--synthetic")) return synthetic(!(i + 1 < argc && !strcmp(argv[i + 1], "--no-mouse")));
            if (!strcmp(argv[i], "--direct")) direct = YES;
            if (!strcmp(argv[i], "--out") && i + 1 < argc) output = @(argv[++i]);
        }
        NSApplication *app = [NSApplication sharedApplication];
        Check *check = [[Check alloc] initWithOutput:output direct:direct];
        app.delegate = check;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        [app run];
    }
    return 0;
}
