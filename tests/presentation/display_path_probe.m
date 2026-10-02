/* Native presentation-timing probe. Test-only; never installed in the engine.
 *
 * Reproduces the game's presentation pattern on the real display without Wine:
 * a fullscreen-space window, a CAMetalLayer letterboxed like the v1 canvas,
 * GPU-bound frames of a chosen cost, the translator's latency-1 rule, and a
 * choice of drawable count, display sync and submission policy. Every frame
 * records commit time, GPU start/end and the drawable's presentedTime so the
 * GPU-end-to-photon path can be compared across configurations.
 *
 * Usage: probe <out.csv> <seconds> <spec>[;<spec>...]
 *   spec: key=value pairs separated by commas:
 *     drawables=2|3      maximumDrawableCount
 *     sync=0|1           displaySyncEnabled
 *     size=canvas|window|full
 *                        canvas: 3024x1890-style letterbox (16:10 fit in the view)
 *                        window: layer covers the fullscreen window content
 *                        full:   layer covers the entire panel including the top strip
 *     gpu=<ms>           target GPU cost per frame (calibrated at start)
 *     cpu=<ms>           simulated game CPU work between frames
 *     policy=latency1|jit|pfence|uncapped|pace
 *                        latency1: after committing N, wait for N-1 to complete, then CPU work (the translator today)
 *                        jit:      latency1 plus a sleep so CPU work ends just before N completes
 *                        pfence:   latency1, and do not acquire drawable N until N-1 has been presented
 *                        uncapped: acquire as fast as nextDrawable allows
 *                        pace:     fixed period given by period=<ms>
 *     period=<ms>        for pace
 *     margin=<ms>        for jit (default 1.5)
 *     fbo=0|1            framebufferOnly (the translator sets 0; Wine's own layer sets 1)
 *     mask=0|1           put a mask layer on the content view like Wine's window shape
 *     jitter=<ms>        random per-frame GPU cost variation, with a 4x hitch every 60 frames
 *     size=scaled        the v1 canvas layout: scaled root bounds and a 1920x1200-point client view
 *     tree=wine|wine-noimage  reproduce Wine's flipped layer-backed content/client views around the metal view
 *     cursor=hide|show   hide the pointer during the spec (the game hides it)
 *     colorspace=none|srgb|p3|linear   explicit layer colorspace (translator default: srgb)
 *     opaquewindow=0|1   window opaque flag (Wine windows start non-opaque)
 *     bg=0|1             black backgroundColor on the metal layer (Wine's metal view sets it)
 *     magfilter=nearest|linear  layer magnification filter (Wine's metal view sets nearest)
 *     subclass=0|1       use a CAMetalLayer subclass overriding nextDrawable (Wine's WineMetalLayer)
 *     invalidate=<N>     every N frames replace the content view's image and setNeedsDisplay (Wine window surface pushes)
 *     cvlink=0|1         run a CVDisplayLink that calls displayIfNeeded on the main thread each refresh (Wine's display link)
 *     commit=0|1         an explicit CATransaction commit from the render thread every frame
 *     hostwindow=none|child|aux  host the metal view in a borderless overlay window: a child of the
 *                        fullscreen window, or an auxiliary window ordered above it (the driver's overlay)
 *     label=<text>       free label
 */
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NSString *const kShader = @"#include <metal_stdlib>\n"
"using namespace metal;\n"
"struct V { float4 pos [[position]]; };\n"
"vertex V vmain(uint id [[vertex_id]]) { float2 p[3] = { float2(-1,-1), float2(3,-1), float2(-1,3) }; V o; o.pos = float4(p[id], 0, 1); return o; }\n"
"fragment float4 fmain(V in [[stage_in]], constant uint &iters [[buffer(0)]], constant float &t [[buffer(1)]]) {\n"
"  float2 uv = in.pos.xy * 0.0007; float a = uv.x * 1.3 + t;\n"
"  for (uint i = 0; i < iters; i++) { a = sin(a * 1.01 + uv.y) * 0.999 + cos(a * 0.5); }\n"
"  return float4(0.5 + 0.5 * sin(a), 0.5 + 0.5 * cos(a + t), 0.3, 1);\n"
"}\n"
"fragment float4 fpresent(V in [[stage_in]], texture2d<float> source [[texture(0)]]) {\n"
"  constexpr sampler s(coord::pixel, filter::nearest);\n"
"  return source.sample(s, in.pos.xy);\n"
"}\n";

typedef struct {
    double cpu_start, main_commit, drawable_wait_ms, present_commit;
    double main_gpu_start, main_gpu_end, gpu_start, gpu_end, presented;
    int presented_seen, completed_seen, main_seen;
} Sample;

typedef struct {
    int drawables, sync, fbo, mask, cursor, opaque_window;
    int bg, magnearest, subclass, invalidate, cvlink, commit;
    char hostwindow[16];
    int hostfresh, hostorderfirst, hostdeact, hide, layeropaque, backed;
    char size[16], policy[16], label[64], tree[16], colorspace[16];
    double gpu_ms, cpu_ms, period_ms, margin_ms, jitter_ms;
} Spec;

static void parseSpec(const char *text, Spec *spec) {
    memset(spec, 0, sizeof(*spec));
    spec->drawables = 3; spec->sync = 0; strcpy(spec->size, "canvas"); strcpy(spec->policy, "latency1");
    spec->gpu_ms = 11.6; spec->cpu_ms = 6.6; spec->period_ms = 12.5; spec->margin_ms = 1.5; spec->fbo = 1; spec->opaque_window = 1; spec->layeropaque = 1;
    char *copy = strdup(text), *save = NULL;
    for (char *item = strtok_r(copy, ",", &save); item; item = strtok_r(NULL, ",", &save)) {
        char *eq = strchr(item, '='); if (!eq) continue; *eq = 0; const char *value = eq + 1;
        if (!strcmp(item, "drawables")) spec->drawables = atoi(value);
        else if (!strcmp(item, "sync")) spec->sync = atoi(value);
        else if (!strcmp(item, "size")) strlcpy(spec->size, value, sizeof(spec->size));
        else if (!strcmp(item, "policy")) strlcpy(spec->policy, value, sizeof(spec->policy));
        else if (!strcmp(item, "label")) strlcpy(spec->label, value, sizeof(spec->label));
        else if (!strcmp(item, "gpu")) spec->gpu_ms = atof(value);
        else if (!strcmp(item, "cpu")) spec->cpu_ms = atof(value);
        else if (!strcmp(item, "period")) spec->period_ms = atof(value);
        else if (!strcmp(item, "margin")) spec->margin_ms = atof(value);
        else if (!strcmp(item, "fbo")) spec->fbo = atoi(value);
        else if (!strcmp(item, "mask")) spec->mask = atoi(value);
        else if (!strcmp(item, "jitter")) spec->jitter_ms = atof(value);
        else if (!strcmp(item, "tree")) strlcpy(spec->tree, value, sizeof(spec->tree));
        else if (!strcmp(item, "cursor")) spec->cursor = !strcmp(value, "hide") ? 1 : 2;
        else if (!strcmp(item, "colorspace")) strlcpy(spec->colorspace, value, sizeof(spec->colorspace));
        else if (!strcmp(item, "opaquewindow")) spec->opaque_window = atoi(value);
        else if (!strcmp(item, "bg")) spec->bg = atoi(value);
        else if (!strcmp(item, "magfilter")) spec->magnearest = !strcmp(value, "nearest");
        else if (!strcmp(item, "subclass")) spec->subclass = atoi(value);
        else if (!strcmp(item, "invalidate")) spec->invalidate = atoi(value);
        else if (!strcmp(item, "cvlink")) spec->cvlink = atoi(value);
        else if (!strcmp(item, "commit")) spec->commit = atoi(value);
        else if (!strcmp(item, "hostwindow")) strlcpy(spec->hostwindow, value, sizeof(spec->hostwindow));
        else if (!strcmp(item, "hostfresh")) spec->hostfresh = atoi(value);
        else if (!strcmp(item, "hostorderfirst")) spec->hostorderfirst = atoi(value);
        else if (!strcmp(item, "hostdeact")) spec->hostdeact = atoi(value);
        else if (!strcmp(item, "hide")) spec->hide = atoi(value);
        else if (!strcmp(item, "layeropaque")) spec->layeropaque = atoi(value);
        else if (!strcmp(item, "backed")) spec->backed = atoi(value);
    }
    free(copy);
}

static double now(void) { return CACurrentMediaTime(); }
static void sleepUntil(double t) {
    for (;;) {
        double remaining = t - now();
        if (remaining <= 0) return;
        if (remaining > 0.0015) usleep((useconds_t)((remaining - 0.001) * 1e6));
        else while (now() < t) {}
    }
}

@interface FlippedView : NSView
@end

// Wine's WineMetalLayer overrides nextDrawable to post a presentation event.
@interface ProbeMetalLayer : CAMetalLayer
@end
@implementation ProbeMetalLayer
- (id<CAMetalDrawable>)nextDrawable { return [super nextDrawable]; }
@end

// Wine's WineMetalView: a layer-backed view whose backing layer is the metal layer
// (wantsLayer + makeBackingLayer), rather than a layer-hosting view.
@interface BackedMetalView : NSView
@property (strong) id<MTLDevice> device;
@end
@implementation BackedMetalView
- (CALayer *)makeBackingLayer {
    CAMetalLayer *layer = [ProbeMetalLayer layer];
    layer.device = self.device;
    layer.framebufferOnly = YES;
    layer.magnificationFilter = kCAFilterNearest;
    layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
    layer.contentsScale = 2.0;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    return layer;
}
- (BOOL)isOpaque { return YES; }
@end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer {}
@end

@interface Probe : NSObject <NSWindowDelegate>
@property (strong) NSWindow *window;
@property (strong) NSWindow *overlay;
@property (strong) NSView *canvasView;
@property (strong) FlippedView *outer;
@property (strong) FlippedView *client;
@property (strong) CAMetalLayer *layer;
@property (strong) id<MTLDevice> device;
@property (strong) id<MTLCommandQueue> queue;
@property (strong) id<MTLRenderPipelineState> pipeline;
@property (strong) id<MTLRenderPipelineState> presentPipeline;
@property (strong) id<MTLTexture> offscreen;
@property (assign) BOOL fullscreen;
@end

@implementation Probe
- (void)windowDidEnterFullScreen:(NSNotification *)note { self.fullscreen = YES; }
@end

static Probe *probe;
static FILE *output;
static NSString *outputPath;
static int totalSeconds;
static NSArray<NSString *> *specs;

static CGImageRef surfaceImage(size_t width, size_t height) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, width, height, 8, 0, space, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextSetRGBFillColor(ctx, 0, 0, 0, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, width, height));
    CGImageRef image = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx); CGColorSpaceRelease(space);
    return image;
}

static void applyColor(const Spec *spec) {
    // The translator sets an explicit colorspace on the game's layer (sRGB by
    // default); an unset colorspace means "display native, no color matching".
    CGColorSpaceRef space = NULL;
    if (!strcmp(spec->colorspace, "srgb")) space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    else if (!strcmp(spec->colorspace, "p3")) space = CGColorSpaceCreateWithName(kCGColorSpaceDisplayP3);
    else if (!strcmp(spec->colorspace, "linear")) space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearSRGB);
    probe.layer.colorspace = space;
    if (space) CGColorSpaceRelease(space);
    probe.window.opaque = spec->opaque_window != 0;
    probe.window.backgroundColor = spec->opaque_window ? NSColor.blackColor : NSColor.clearColor;
}

static int usingSubclass, usingBacked;
static CVDisplayLinkRef displayLink;
static CVReturn linkCallback(CVDisplayLinkRef link, const CVTimeStamp *now_, const CVTimeStamp *out, CVOptionFlags in, CVOptionFlags *flagsOut, void *ctx) {
    dispatch_async(dispatch_get_main_queue(), ^{ [probe.window displayIfNeeded]; });
    return kCVReturnSuccess;
}

static void applyLayerClass(const Spec *spec) {
    if (spec->backed != usingBacked) {
        NSView *old = probe.canvasView;
        NSRect frame = old.frame;
        NSView *superview = old.superview;
        [old removeFromSuperview];
        if (spec->backed) {
            BackedMetalView *view = [[BackedMetalView alloc] initWithFrame:frame];
            view.device = probe.device;
            view.wantsLayer = YES;
            view.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
            probe.canvasView = view;
            probe.layer = (CAMetalLayer *)view.layer;
            usingSubclass = 1;
        } else {
            NSView *view = [[NSView alloc] initWithFrame:frame];
            view.wantsLayer = YES;
            CAMetalLayer *layer = [CAMetalLayer layer];
            layer.device = probe.device; layer.pixelFormat = MTLPixelFormatBGRA8Unorm; layer.framebufferOnly = YES; layer.opaque = YES;
            view.layer = layer;
            probe.canvasView = view;
            probe.layer = layer;
            usingSubclass = 0;
        }
        if (superview) [superview addSubview:probe.canvasView];
        usingBacked = spec->backed;
    }
    if (spec->subclass != usingSubclass) {
        CAMetalLayer *old = probe.layer;
        CAMetalLayer *layer = spec->subclass ? [ProbeMetalLayer layer] : [CAMetalLayer layer];
        layer.device = old.device; layer.pixelFormat = old.pixelFormat; layer.framebufferOnly = old.framebufferOnly; layer.opaque = old.opaque;
        probe.layer = layer;
        probe.canvasView.layer = layer;
        usingSubclass = spec->subclass;
    }
    probe.layer.backgroundColor = spec->bg ? NSColor.blackColor.CGColor : NULL;
    probe.layer.opaque = spec->layeropaque != 0;
    probe.layer.magnificationFilter = spec->magnearest ? kCAFilterNearest : kCAFilterLinear;
    if (spec->cvlink && !displayLink) {
        CVDisplayLinkCreateWithCGDisplay(CGMainDisplayID(), &displayLink);
        CVDisplayLinkSetOutputCallback(displayLink, linkCallback, NULL);
        CVDisplayLinkStart(displayLink);
    } else if (!spec->cvlink && displayLink) {
        CVDisplayLinkStop(displayLink); CVDisplayLinkRelease(displayLink); displayLink = NULL;
    }
}

@interface OverlayWindow : NSWindow
@end
@implementation OverlayWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

static BOOL applyHostWindow(const Spec *spec) {
    BOOL child = !strcmp(spec->hostwindow, "child"), aux = !strncmp(spec->hostwindow, "aux", 3), screen = !strncmp(spec->hostwindow, "screen", 6);
    BOOL fullFrame = screen ? strcmp(spec->hostwindow, "screen-content") != 0 : !strcmp(spec->hostwindow, "aux-full");
    NSView *root = probe.window.contentView;
    if (!child && !aux && !screen) {
        if (probe.overlay) {
            [probe.window removeChildWindow:probe.overlay];
            [probe.overlay orderOut:nil];
            if (probe.canvasView.window == probe.overlay) { [probe.canvasView removeFromSuperview]; [root addSubview:probe.canvasView]; }
        }
        return NO;
    }
    NSRect content = fullFrame ? probe.window.screen.frame : [probe.window contentRectForFrameRect:probe.window.frame];
    if (probe.overlay && (spec->hostfresh || screen != (probe.overlay.level > NSNormalWindowLevel))) {
        [probe.window removeChildWindow:probe.overlay]; [probe.canvasView removeFromSuperview]; [probe.overlay orderOut:nil]; probe.overlay = nil;
    }
    if (!probe.overlay) {
        probe.overlay = [[OverlayWindow alloc] initWithContentRect:content styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        probe.overlay.releasedWhenClosed = NO;
        probe.overlay.opaque = YES;
        probe.overlay.backgroundColor = NSColor.blackColor;
        probe.overlay.hasShadow = NO;
        probe.overlay.ignoresMouseEvents = YES;
        probe.overlay.animationBehavior = NSWindowAnimationBehaviorNone;
        probe.overlay.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary | NSWindowCollectionBehaviorIgnoresCycle
            | (screen ? NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary : 0);
        if (screen) probe.overlay.level = NSMainMenuWindowLevel + 1;
        probe.overlay.hidesOnDeactivate = spec->hostdeact != 0;
        probe.overlay.contentView.wantsLayer = YES;
        probe.overlay.contentView.layer.backgroundColor = NSColor.blackColor.CGColor;
    }
    [probe.overlay setFrame:content display:NO];
    if (probe.outer) { [probe.outer removeFromSuperview]; probe.outer.layer.contents = nil; }
    [probe.canvasView removeFromSuperview];
    if (spec->hostorderfirst) {
        // Put the empty overlay on screen first, then host the layer in it.
        if (child) [probe.window addChildWindow:probe.overlay ordered:NSWindowAbove];
        if (screen) [probe.overlay orderFrontRegardless]; else [probe.overlay orderWindow:NSWindowAbove relativeTo:probe.window.windowNumber];
        [CATransaction flush];
        usleep(300000);
    }
    [probe.overlay.contentView addSubview:probe.canvasView];
    NSRect bounds = probe.overlay.contentView.bounds;
    double backing = probe.overlay.backingScaleFactor;
    double scale = fmin(bounds.size.width / 1920.0, bounds.size.height / 1200.0);
    double w = floor(1920.0 * scale), h = floor(1200.0 * scale);
    probe.canvasView.autoresizingMask = NSViewNotSizable;
    probe.canvasView.frame = NSMakeRect(floor((bounds.size.width - w) / 2), floor((bounds.size.height - h) / 2), w, h);
    probe.layer.contentsScale = backing;
    probe.layer.drawableSize = CGSizeMake(llround(w * backing), llround(h * backing));
    probe.layer.maximumDrawableCount = spec->drawables;
    probe.layer.displaySyncEnabled = spec->sync != 0;
    probe.layer.framebufferOnly = spec->fbo != 0;
    if (child) [probe.window addChildWindow:probe.overlay ordered:NSWindowAbove];
    else [probe.window removeChildWindow:probe.overlay];
    if (screen) [probe.overlay orderFrontRegardless];
    else [probe.overlay orderWindow:NSWindowAbove relativeTo:probe.window.windowNumber];
    [CATransaction flush];
    return YES;
}

static void applyLayout(const Spec *spec) {
    applyColor(spec);
    applyLayerClass(spec);
    if (applyHostWindow(spec)) return;
    NSView *root = probe.window.contentView;
    NSRect rootFrame = root.frame;
    [root setBounds:NSMakeRect(0, 0, rootFrame.size.width, rootFrame.size.height)];
    NSRect bounds = root.bounds;
    double backing = probe.window.backingScaleFactor;
    NSRect frame = bounds;
    double extraScale = 1.0;
    root.layer.mask = nil;
    if (!strncmp(spec->tree, "wine", 4)) {
        // Wine's tree: window content view (flipped, layer-backed, draws the
        // window surface image into its layer, scaled root bounds) -> client
        // WineContentView (flipped, layer-backed, 1920x1200 points) -> metal view.
        if (!probe.outer) {
            probe.outer = [[FlippedView alloc] initWithFrame:bounds];
            probe.outer.wantsLayer = YES;
            probe.outer.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
            probe.client = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, 1920, 1200)];
            probe.client.wantsLayer = YES;
            probe.client.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
            [probe.outer addSubview:probe.client];
        }
        [probe.canvasView removeFromSuperview];
        [probe.client addSubview:probe.canvasView positioned:NSWindowBelow relativeTo:nil];
        if (probe.outer.superview != root) [root addSubview:probe.outer];
        probe.outer.frame = bounds;
        double w = bounds.size.width, h = bounds.size.height;
        double scale = fmin(w / 1920.0, h / 1200.0);
        [probe.outer setBounds:NSMakeRect(-(w / scale - 1920.0) / 2, -(h / scale - 1200.0) / 2, w / scale, h / scale)];
        probe.client.frame = NSMakeRect(0, 0, 1920, 1200);
        probe.client.layer.backgroundColor = NSColor.blackColor.CGColor;
        if (strcmp(spec->tree, "wine-noimage")) {
            CGImageRef image = surfaceImage((size_t)(w * backing), (size_t)(h * backing));
            probe.outer.layer.contents = (__bridge id)image;
            probe.outer.layer.contentsScale = backing;
            CGImageRelease(image);
        } else {
            probe.outer.layer.contents = nil;
        }
        probe.outer.layer.backgroundColor = NSColor.blackColor.CGColor;
        probe.canvasView.frame = probe.client.bounds;
        probe.canvasView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        probe.layer.contentsScale = backing * scale;
        probe.layer.drawableSize = CGSizeMake(llround(1920 * backing * scale), llround(1200 * backing * scale));
        probe.layer.maximumDrawableCount = spec->drawables;
        probe.layer.displaySyncEnabled = spec->sync != 0;
        probe.layer.framebufferOnly = spec->fbo != 0;
        [CATransaction flush];
        return;
    }
    if (probe.outer) { [probe.outer removeFromSuperview]; probe.outer.layer.contents = nil; }
    if (probe.canvasView.superview != root) { [probe.canvasView removeFromSuperview]; [root addSubview:probe.canvasView]; }
    probe.canvasView.autoresizingMask = NSViewNotSizable;
    if (spec->mask) {
        // Wine's content view carries a mask layer for the window shape.
        CALayer *mask = [CALayer layer];
        mask.frame = root.layer.bounds;
        mask.backgroundColor = NSColor.blackColor.CGColor;
        root.layer.mask = mask;
    }
    if (!strcmp(spec->size, "scaled")) {
        // The v1 canvas layout: root bounds scaled so a 1920x1200-point client
        // view fills the screen with equal bars; the layer draws at display pixels.
        double w = bounds.size.width, h = bounds.size.height;
        double scale = fmin(w / 1920.0, h / 1200.0);
        [root setBounds:NSMakeRect(-(w / scale - 1920.0) / 2, -(h / scale - 1200.0) / 2, w / scale, h / scale)];
        frame = NSMakeRect(0, 0, 1920.0, 1200.0);
        extraScale = scale;
    } else if (!strcmp(spec->size, "canvas")) {
        // 16:10 game image aspect-fitted in the content view, like the v1 canvas.
        double scale = fmin(bounds.size.width / 1920.0, bounds.size.height / 1200.0);
        double w = floor(1920.0 * scale), h = floor(1200.0 * scale);
        frame = NSMakeRect(floor((bounds.size.width - w) / 2), floor((bounds.size.height - h) / 2), w, h);
    } else if (!strcmp(spec->size, "full")) {
        NSRect screen = probe.window.screen.frame;
        NSRect windowFrame = probe.window.frame;
        // Extend upward to cover the top strip the fullscreen space leaves black.
        frame = NSMakeRect(0, 0, bounds.size.width, bounds.size.height + (screen.size.height - windowFrame.size.height));
    }
    probe.canvasView.frame = frame;
    probe.layer.contentsScale = backing * extraScale;
    probe.layer.drawableSize = CGSizeMake(llround(frame.size.width * backing * extraScale), llround(frame.size.height * backing * extraScale));
    probe.layer.maximumDrawableCount = spec->drawables;
    probe.layer.displaySyncEnabled = spec->sync != 0;
    probe.layer.framebufferOnly = spec->fbo != 0;
    [CATransaction flush];
}

static id<MTLCommandBuffer> encodeMain(NSUInteger iters, float t) {
    id<MTLCommandBuffer> cb = [probe.queue commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = probe.offscreen;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:probe.pipeline];
    uint32_t it = (uint32_t)iters;
    [enc setFragmentBytes:&it length:sizeof(it) atIndex:0];
    [enc setFragmentBytes:&t length:sizeof(t) atIndex:1];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    return cb;
}

static id<MTLCommandBuffer> encodePresent(id<CAMetalDrawable> drawable) {
    id<MTLCommandBuffer> cb = [probe.queue commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = drawable.texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];
    [enc setRenderPipelineState:probe.presentPipeline];
    [enc setFragmentTexture:probe.offscreen atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [enc endEncoding];
    return cb;
}

static int cursorHidden;
static void runSpec(NSString *text, int index) {
    Spec spec; parseSpec(text.UTF8String, &spec);
    dispatch_sync(dispatch_get_main_queue(), ^{
        applyLayout(&spec);
        // The game hides the pointer; a visible pointer over the window may change the flip path.
        if (spec.cursor == 1 && !cursorHidden) { [NSCursor hide]; cursorHidden = 1; }
        if (spec.cursor == 2 && cursorHidden) { [NSCursor unhide]; cursorHidden = 0; }
    });
    usleep(300000);
    CGSize size = probe.layer.drawableSize;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:(NSUInteger)size.width height:(NSUInteger)size.height mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModePrivate;
    probe.offscreen = [probe.device newTextureWithDescriptor:td];
    NSUInteger iters = 2000;
    // Calibrate the main pass cost to the requested GPU time (the present pass is extra, like the translator's).
    for (int round = 0; round < 8; round++) {
        double total = 0; int n = 0;
        for (int i = 0; i < 6; i++) {
            @autoreleasepool {
                id<MTLCommandBuffer> cb = encodeMain(iters, (float)now());
                [cb commit];
                [cb waitUntilCompleted];
                if (i >= 2) { total += cb.GPUEndTime - cb.GPUStartTime; n++; }
            }
        }
        double measured = n ? total / n * 1000 : 0;
        if (measured <= 0) break;
        double ratio = spec.gpu_ms / measured;
        iters = (NSUInteger)fmax(50, iters * fmin(fmax(ratio, 0.25), 4.0));
        if (fabs(ratio - 1) < 0.03) break;
    }
    CGImageRef invalidateImages[2] = {NULL, NULL};
    if (spec.invalidate > 0) {
        NSRect b = probe.window.contentView.bounds; double backing = probe.window.backingScaleFactor;
        invalidateImages[0] = surfaceImage((size_t)(b.size.width * backing), (size_t)(b.size.height * backing));
        invalidateImages[1] = surfaceImage((size_t)(b.size.width * backing), (size_t)(b.size.height * backing));
    }
    if (spec.hide) {
        // Hide and unhide the application mid-spec, like Cmd-H / Cmd-Tab, and report key status.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [NSApp hide:nil]; });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [NSApp unhide:nil]; [probe.window makeKeyAndOrderFront:nil];
            fprintf(stderr, "after unhide: window key %d overlay visible %d key window %s\n", probe.window.isKeyWindow, probe.overlay.isVisible,
                    NSApp.keyWindow == probe.window ? "probe" : NSApp.keyWindow == probe.overlay ? "overlay" : "none"); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            fprintf(stderr, "1.5 s later: window key %d overlay visible %d fullscreen %d\n", probe.window.isKeyWindow, probe.overlay.isVisible,
                    (probe.window.styleMask & NSWindowStyleMaskFullScreen) != 0); });
    }
    int capacity = totalSeconds * 400 + 1000;
    Sample *samples = calloc(capacity, sizeof(Sample));
    NSLock *lock = [NSLock new];
    dispatch_semaphore_t presentedSem = dispatch_semaphore_create(1);
    dispatch_semaphore_t completedPrev = dispatch_semaphore_create(0);
    double start = now(), end = start + totalSeconds, lastCommit = 0, lastCompletion = 0;
    double predictedGpu = spec.gpu_ms / 1000;
    int n = 0;
    while (now() < end && n < capacity) {
        @autoreleasepool {
            double cpuStart = now();
            if (!strcmp(spec.policy, "pace") && lastCommit) { sleepUntil(lastCommit + spec.period_ms / 1000); cpuStart = now(); }
            if (!strcmp(spec.policy, "jit") && lastCompletion) {
                // Start CPU work so it ends margin before the in-flight frame completes.
                sleepUntil(lastCompletion + predictedGpu - spec.cpu_ms / 1000 - spec.margin_ms / 1000);
                cpuStart = now();
            }
            if (spec.cpu_ms > 0 && strcmp(spec.policy, "uncapped")) sleepUntil(cpuStart + spec.cpu_ms / 1000);
            int slot = n;
            samples[slot].cpu_start = cpuStart;
            NSUInteger frameIters = iters;
            if (spec.jitter_ms > 0) {
                double r = ((double)arc4random_uniform(2000) / 1000.0) - 1.0;   // -1..1
                double factor = 1.0 + r * spec.jitter_ms / spec.gpu_ms;
                if (n % 60 == 30) factor *= 4.0;   // occasional hitch, like a first-use pipeline
                frameIters = (NSUInteger)fmax(20, iters * factor);
            }
            id<MTLCommandBuffer> main = encodeMain(frameIters, (float)(now() - start));
            [main addCompletedHandler:^(id<MTLCommandBuffer> done) {
                [lock lock]; samples[slot].main_gpu_start = done.GPUStartTime; samples[slot].main_gpu_end = done.GPUEndTime; samples[slot].main_seen = 1; [lock unlock];
            }];
            [main commit];
            samples[slot].main_commit = now();
            // Present chunk: the translator acquires the drawable only here.
            if (!strcmp(spec.policy, "pfence")) dispatch_semaphore_wait(presentedSem, DISPATCH_TIME_FOREVER);
            double waitStart = now();
            id<CAMetalDrawable> drawable = [probe.layer nextDrawable];
            samples[slot].drawable_wait_ms = (now() - waitStart) * 1000;
            if (!drawable) { n++; continue; }
            id<MTLCommandBuffer> cb = encodePresent(drawable);
            [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
                [lock lock]; samples[slot].presented = presented.presentedTime; samples[slot].presented_seen = 1; [lock unlock];
                dispatch_semaphore_signal(presentedSem);
            }];
            [cb addCompletedHandler:^(id<MTLCommandBuffer> done) {
                [lock lock]; samples[slot].gpu_start = done.GPUStartTime; samples[slot].gpu_end = done.GPUEndTime; samples[slot].completed_seen = 1; [lock unlock];
                dispatch_semaphore_signal(completedPrev);
            }];
            [cb presentDrawable:drawable];
            [cb commit];
            samples[slot].present_commit = now();
            if (spec.commit) {
                [CATransaction begin];
                probe.layer.name = [NSString stringWithFormat:@"frame%d", n];
                [CATransaction commit];
            }
            if (spec.invalidate > 0 && n % spec.invalidate == 0) {
                CGImageRef image = invalidateImages[n & 1];
                dispatch_async(dispatch_get_main_queue(), ^{
                    NSView *target = probe.outer.superview ? probe.outer : probe.window.contentView;
                    target.layer.contents = (__bridge id)image;
                    [target setNeedsDisplay:YES];
                });
            }
            lastCommit = samples[slot].present_commit;
            n++;
            if (strcmp(spec.policy, "uncapped")) {
                // Translator rule (latency 1): after presenting N, wait for N-1 to finish before the game continues.
                if (n >= 2) {
                    dispatch_semaphore_wait(completedPrev, DISPATCH_TIME_FOREVER);
                    [lock lock]; double ge = samples[n - 2].gpu_end, gs = samples[n - 2].main_gpu_start; [lock unlock];
                    lastCompletion = now();
                    if (ge > gs) predictedGpu = predictedGpu * 0.8 + (ge - gs) * 0.2;
                }
            }
        }
    }
    // Drain callbacks.
    usleep(400000);
    [lock lock];
    for (int i = 0; i < n; i++) {
        fprintf(output, "%d,\"%s\",%d,%.6f,%.6f,%.3f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%d,%d,%d\n", index, text.UTF8String, i,
                samples[i].cpu_start, samples[i].main_commit, samples[i].drawable_wait_ms, samples[i].present_commit,
                samples[i].main_gpu_start, samples[i].main_gpu_end, samples[i].gpu_start, samples[i].gpu_end, samples[i].presented,
                samples[i].main_seen, samples[i].completed_seen, samples[i].presented_seen);
    }
    [lock unlock];
    fflush(output);
    fprintf(stderr, "spec %d done: %d frames, drawable %.0fx%.0f, iters %lu\n", index, n, size.width, size.height, (unsigned long)iters);
    free(samples);
    if (invalidateImages[0]) { dispatch_sync(dispatch_get_main_queue(), ^{}); CGImageRelease(invalidateImages[0]); CGImageRelease(invalidateImages[1]); }
}

static void worker(void) {
    for (int wait = 0; wait < 100 && !probe.fullscreen; wait++) usleep(100000);
    if (!probe.fullscreen) fprintf(stderr, "warning: fullscreen not confirmed; measuring anyway\n");
    usleep(1500000);
    fprintf(output, "spec_index,spec,frame,cpu_start,main_commit,drawable_wait_ms,present_commit,main_gpu_start,main_gpu_end,gpu_start,gpu_end,presented,main_seen,completed_seen,presented_seen\n");
    for (NSUInteger i = 0; i < specs.count; i++) runSpec(specs[i], (int)i);
    fclose(output);
    dispatch_sync(dispatch_get_main_queue(), ^{ if (cursorHidden) { [NSCursor unhide]; cursorHidden = 0; } });
    dispatch_async(dispatch_get_main_queue(), ^{ [NSApp terminate:nil]; });
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "usage: probe <out.csv> <seconds> <spec;spec...> [windowed]\n"); return 2; }
    @autoreleasepool {
        outputPath = [NSString stringWithUTF8String:argv[1]];
        totalSeconds = atoi(argv[2]);
        specs = [[NSString stringWithUTF8String:argv[3]] componentsSeparatedByString:@";"];
        BOOL windowed = argc > 4 && !strcmp(argv[4], "windowed");
        output = fopen(argv[1], "w");
        if (!output) { perror("open output"); return 1; }
        CGDirectDisplayID display = CGMainDisplayID();
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(display);
        fprintf(stderr, "display mode: %zux%zu @ %.1f Hz (0 = variable)\n", CGDisplayModeGetPixelWidth(mode), CGDisplayModeGetPixelHeight(mode), CGDisplayModeGetRefreshRate(mode));
        if (mode) CGDisplayModeRelease(mode);
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        probe = [Probe new];
        probe.device = MTLCreateSystemDefaultDevice();
        probe.queue = [probe.device newCommandQueue];
        NSError *error = nil;
        id<MTLLibrary> library = [probe.device newLibraryWithSource:kShader options:nil error:&error];
        if (!library) { fprintf(stderr, "shader: %s\n", error.localizedDescription.UTF8String); return 1; }
        MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
        desc.vertexFunction = [library newFunctionWithName:@"vmain"];
        desc.fragmentFunction = [library newFunctionWithName:@"fmain"];
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        probe.pipeline = [probe.device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (!probe.pipeline) { fprintf(stderr, "pipeline: %s\n", error.localizedDescription.UTF8String); return 1; }
        desc.fragmentFunction = [library newFunctionWithName:@"fpresent"];
        probe.presentPipeline = [probe.device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (!probe.presentPipeline) { fprintf(stderr, "present pipeline: %s\n", error.localizedDescription.UTF8String); return 1; }
        NSRect frame = NSMakeRect(100, 100, 960, 600);
        probe.window = [[NSWindow alloc] initWithContentRect:frame styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable) backing:NSBackingStoreBuffered defer:NO];
        probe.window.title = @"Display path probe";
        probe.window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
        probe.window.backgroundColor = NSColor.blackColor;
        probe.window.delegate = probe;
        probe.window.contentView.wantsLayer = YES;
        probe.window.contentView.layer.backgroundColor = NSColor.blackColor.CGColor;
        probe.canvasView = [[NSView alloc] initWithFrame:probe.window.contentView.bounds];
        probe.canvasView.wantsLayer = YES;
        probe.layer = [CAMetalLayer layer];
        probe.layer.device = probe.device;
        probe.layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        probe.layer.framebufferOnly = YES;
        probe.layer.opaque = YES;
        probe.canvasView.layer = probe.layer;
        [probe.window.contentView addSubview:probe.canvasView];
        [probe.window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        if (windowed) probe.fullscreen = YES; else [probe.window toggleFullScreen:nil];
        [NSThread detachNewThreadWithBlock:^{ worker(); }];
        [NSApp run];
    }
    return 0;
}
