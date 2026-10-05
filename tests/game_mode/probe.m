// Stand-in for Recall's Wine game process when testing macOS Game Mode: a window
// that enters macOS fullscreen and keeps the GPU busy (the system may ignore apps
// it does not consider demanding), reporting what gamepolicyctl says while it
// runs. Prints one JSON object per line to --log (or stdout).
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>

static NSString *const kShader =
    @"#include <metal_stdlib>\nusing namespace metal;\n"
     "struct V { float4 p [[position]]; };\n"
     "vertex V vs(uint i [[vertex_id]]) { float2 q = float2((i << 1) & 2, i & 2); V v; v.p = float4(q * 2 - 1, 0, 1); return v; }\n"
     "fragment float4 fs(V in [[stage_in]], constant float &t [[buffer(0)]]) {\n"
     "  float2 uv = in.p.xy * 0.001; float a = 0;\n"
     "  for (int i = 0; i < 192; i++) { uv = float2(sin(uv.y * 1.7 + t), cos(uv.x * 1.3 - t)) + uv * 0.5; a += length(uv); }\n"
     "  return float4(fract(a * 0.01), fract(a * 0.013), fract(a * 0.017), 1); }\n";

@interface Probe : NSObject <NSApplicationDelegate>
@end

@implementation Probe {
    NSWindow *window;
    CAMetalLayer *layer;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> pipeline;
    NSFileHandle *out;
    NSString *gamepolicyctl;
    double seconds;
    CFAbsoluteTime start;
    unsigned long frames;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    seconds = 14;
    gamepolicyctl = @"/Applications/Xcode.app/Contents/Developer/usr/bin/gamepolicyctl";
    out = NSFileHandle.fileHandleWithStandardOutput;
    for (NSUInteger i = 1; i + 1 < args.count; i++) {
        if ([args[i] isEqualToString:@"--seconds"]) seconds = args[i + 1].doubleValue;
        else if ([args[i] isEqualToString:@"--gamepolicyctl"]) gamepolicyctl = args[i + 1];
        else if ([args[i] isEqualToString:@"--log"]) {
            [NSFileManager.defaultManager createFileAtPath:args[i + 1] contents:nil attributes:nil];
            out = [NSFileHandle fileHandleForWritingAtPath:args[i + 1]];
        }
    }
    return self;
}

- (void)emit:(NSDictionary *)event {
    NSMutableData *line = [[NSJSONSerialization dataWithJSONObject:event options:NSJSONWritingSortedKeys error:nil] mutableCopy];
    [line appendBytes:"\n" length:1];
    [out writeData:line];
    [out synchronizeFile];
}

- (NSString *)gameModeStatus {
    NSTask *task = [NSTask new];
    NSPipe *pipe = [NSPipe pipe];
    task.executableURL = [NSURL fileURLWithPath:gamepolicyctl];
    task.arguments = @[@"game-mode", @"status"];
    task.standardOutput = pipe;
    task.standardError = pipe;
    if (![task launchAndReturnError:nil]) return @"unavailable";
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSRegularExpression *escapes = [NSRegularExpression regularExpressionWithPattern:@"\\e\\[[0-9;]*m" options:0 error:nil];
    text = [escapes stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0, text.length) withTemplate:@""];
    NSRegularExpression *state = [NSRegularExpression regularExpressionWithPattern:@"Game mode is (\\w+)" options:0 error:nil];
    NSTextCheckingResult *match = [state firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    return match ? [text substringWithRange:[match rangeAtIndex:1]] : text;
}

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    // Wine's loader starts as a UI element and becomes a regular app when it shows a window.
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:kShader options:nil error:&error];
    MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
    descriptor.vertexFunction = [library newFunctionWithName:@"vs"];
    descriptor.fragmentFunction = [library newFunctionWithName:@"fs"];
    descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pipeline = library ? [device newRenderPipelineStateWithDescriptor:descriptor error:&error] : nil;
    if (!pipeline) {
        [self emit:@{@"event": @"error", @"message": error.localizedDescription ?: @"no pipeline"}];
        exit(1);
    }
    queue = [device newCommandQueue];

    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1280, 720)
                                         styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                                                   NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                           backing:NSBackingStoreBuffered
                                             defer:NO];
    window.releasedWhenClosed = NO;
    window.title = @"Game Mode probe";
    window.collectionBehavior = NSWindowCollectionBehaviorFullScreenPrimary;
    layer = [CAMetalLayer layer];
    layer.device = device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    window.contentView.layer = layer;
    window.contentView.wantsLayer = YES;
    [window center];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    start = CFAbsoluteTimeGetCurrent();
    NSBundle *bundle = NSBundle.mainBundle;
    NSRunningApplication *me = NSRunningApplication.currentApplication;
    [self emit:@{@"event": @"start", @"pid": @(getpid()),
                 @"executable": NSProcessInfo.processInfo.arguments[0],
                 @"bundle_identifier": bundle.bundleIdentifier ?: [NSNull null],
                 @"bundle_path": bundle.bundlePath ?: [NSNull null],
                 @"category": [bundle objectForInfoDictionaryKey:@"LSApplicationCategoryType"] ?: [NSNull null],
                 @"supports_game_mode": [bundle objectForInfoDictionaryKey:@"LSSupportsGameMode"] ?: [NSNull null],
                 @"running_app_bundle_identifier": me.bundleIdentifier ?: [NSNull null],
                 @"running_app_bundle_url": me.bundleURL.path ?: [NSNull null],
                 @"game_mode": [self gameModeStatus]}];

    NSTimer *timer = [NSTimer timerWithTimeInterval:1.0 / 240 repeats:YES block:^(NSTimer *t) { [self draw]; }];
    [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
        [self->window toggleFullScreen:nil];
    });
    for (int i = 1; i * 3 < seconds; i++)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, i * 3 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ [self check]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self check];
        exit(0);
    });
}

- (void)check {
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    [self emit:@{@"event": @"check", @"t": @(round((CFAbsoluteTimeGetCurrent() - start) * 10) / 10),
                 @"game_mode": [self gameModeStatus],
                 @"fullscreen": @((window.styleMask & NSWindowStyleMaskFullScreen) != 0),
                 @"active": @(NSApp.isActive),
                 @"frontmost": @(front.processIdentifier == getpid()),
                 @"frames": @(frames)}];
}

- (void)draw {
    @autoreleasepool {
        CGFloat scale = window.backingScaleFactor;
        CGSize size = window.contentView.bounds.size;
        CGSize pixels = CGSizeMake(size.width * scale, size.height * scale);
        if (!CGSizeEqualToSize(layer.drawableSize, pixels)) {
            layer.contentsScale = scale;
            layer.drawableSize = pixels;
        }
        id<CAMetalDrawable> drawable = [layer nextDrawable];
        if (!drawable) return;
        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = drawable.texture;
        pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> encoder = [buffer renderCommandEncoderWithDescriptor:pass];
        float t = CFAbsoluteTimeGetCurrent() - start;
        [encoder setRenderPipelineState:pipeline];
        [encoder setFragmentBytes:&t length:sizeof t atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [encoder endEncoding];
        [buffer presentDrawable:drawable];
        [buffer commit];
        frames++;
    }
}
@end

int main(void) {
    @autoreleasepool {
        Probe *probe = [Probe new];
        NSApplication.sharedApplication.delegate = probe;
        [NSApp run];
    }
    return 0;
}
