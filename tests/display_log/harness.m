#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

static BOOL rotation_mode;
static atomic_uint logger_destroyed, trace_destroyed, drawables_destroyed, commands_destroyed;
static IMP logger_dealloc, trace_dealloc;
static IMP logger_init;
static atomic_bool init_ready, init_release;
static id logger_test_init(id self, SEL selector, NSString *prefix) {
  id result = ((id (*)(id, SEL, NSString *))logger_init)(self, selector, prefix);
  atomic_store(&init_ready, true);
  while (!atomic_load(&init_release)) usleep(1000);
  return result;
}
static void logger_test_dealloc(id self, SEL selector) {
  ((void (*)(id, SEL))logger_dealloc)(self, selector);
  atomic_fetch_add(&logger_destroyed, 1);
}
static void trace_test_dealloc(id self, SEL selector) {
  ((void (*)(id, SEL))trace_dealloc)(self, selector);
  atomic_fetch_add(&trace_destroyed, 1);
}
static void require(BOOL condition, const char *message) {
  if (!condition) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
}

@interface FakeDrawable : NSObject {
  MTLDrawablePresentedHandler _handler;
  NSUInteger _identity;
  double _time;
  id _layer;
}
- (instancetype)initWithIdentity:(NSUInteger)identity layer:(id)layer;
- (void)addPresentedHandler:(MTLDrawablePresentedHandler)handler;
- (void)finish;
- (double)presentedTime;
- (NSUInteger)drawableID;
- (id)layer;
@end
@implementation FakeDrawable
- (instancetype)initWithIdentity:(NSUInteger)identity layer:(id)layer {
  if ((self = [super init])) { _identity = identity; _layer = [layer retain]; }
  return self;
}
- (void)addPresentedHandler:(MTLDrawablePresentedHandler)handler { _handler = [handler copy]; }
- (double)presentedTime { return _time; }
- (NSUInteger)drawableID { return _identity; }
- (id)layer { return _layer; }
- (void)finish {
  _time = _identity == 0 ? 0 : 1000.0 + _identity / 60.0 + (rotation_mode ? (_identity / 100) * .05 : 0);
  MTLDrawablePresentedHandler handler = [_handler copy];
  [_handler release]; _handler = nil;
  if (handler) handler((id<MTLDrawable>)self);
  [handler release];
}
- (void)dealloc {
  [_handler release]; [_layer release];
  atomic_fetch_add(&drawables_destroyed, 1);
  [super dealloc];
}
@end

@interface FakeCommand : NSObject {
  MTLCommandBufferHandler _handler;
  NSUInteger _identity;
  MTLCommandBufferStatus _status;
}
- (instancetype)initWithIdentity:(NSUInteger)identity;
- (void)addCompletedHandler:(MTLCommandBufferHandler)handler;
- (void)finish;
- (double)GPUStartTime;
- (double)GPUEndTime;
- (MTLCommandBufferStatus)status;
- (NSError *)error;
@end
@implementation FakeCommand
- (instancetype)initWithIdentity:(NSUInteger)identity {
  if ((self = [super init])) _identity = identity;
  return self;
}
- (void)addCompletedHandler:(MTLCommandBufferHandler)handler { _handler = [handler copy]; }
- (double)GPUStartTime { return _identity == 1 ? 0 : 999.0 + _identity / 60.0; }
- (double)GPUEndTime { return _identity == 1 ? 0 : self.GPUStartTime + 0.003; }
- (MTLCommandBufferStatus)status { return _status; }
- (NSError *)error { return _status == MTLCommandBufferStatusError ? [NSError errorWithDomain:@"diagnostic" code:42 userInfo:nil] : nil; }
- (void)finish {
  _status = _identity == 2 ? MTLCommandBufferStatusError : MTLCommandBufferStatusCompleted;
  MTLCommandBufferHandler handler = [_handler copy];
  [_handler release]; _handler = nil;
  if (handler) handler((id<MTLCommandBuffer>)self);
  [handler release];
}
- (void)dealloc {
  [_handler release];
  atomic_fetch_add(&commands_destroyed, 1);
  [super dealloc];
}
@end

typedef void (*Record)(id<MTLCommandBuffer>, id<MTLDrawable>, double);
typedef void (*Shutdown)(void);
typedef struct { Record record; FakeCommand *command; FakeDrawable *drawable; } InitRace;
static void *record_during_init(void *argument) {
  @autoreleasepool {
    InitRace *race = argument;
    race->record((id<MTLCommandBuffer>)race->command, (id<MTLDrawable>)race->drawable, 1.0 / 60.0);
  }
  return NULL;
}
typedef struct { const char *fifo, *capture; } ReaderPaths;
static void *read_fifo(void *argument) {
  ReaderPaths *paths = argument;
  FILE *in = fopen(paths->fifo, "r"), *out = fopen(paths->capture, "w");
  require(in && out, "open FIFO capture");
  char buffer[16384];
  size_t bytes;
  while ((bytes = fread(buffer, 1, sizeof(buffer), in))) require(fwrite(buffer, 1, bytes, out) == bytes, "write capture");
  fclose(in); fclose(out);
  return NULL;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    require(argc == 4, "library/prefix/mode arguments");
    const char *mode = argv[3];
    BOOL disabled = !strcmp(mode, "disabled"), missing = !strcmp(mode, "missing");
    BOOL capped = !strcmp(mode, "capped"), overflow = !strcmp(mode, "overflow");
    BOOL pending = !strcmp(mode, "pending"), blocked = !strcmp(mode, "blocked_shutdown");
    BOOL concurrent = !strcmp(mode, "concurrent");
    rotation_mode = !strcmp(mode, "rotation");
    BOOL pre_shutdown = !strcmp(mode, "pre_shutdown"), init_race = !strcmp(mode, "init_race");
    if (disabled) unsetenv("DXMT_DISPLAY_LOG"); else setenv("DXMT_DISPLAY_LOG", argv[2], 1);
    char path[4096], capture[4096];
    snprintf(path, sizeof(path), "%s-%d.csv", argv[2], getpid());
    snprintf(capture, sizeof(capture), "%s-%d.capture.csv", argv[2], getpid());
    if (overflow || blocked) require(mkfifo(path, 0600) == 0, "create diagnostic FIFO");
    void *library = dlopen(argv[1], RTLD_LAZY | RTLD_LOCAL);
    if (!library) fprintf(stderr, "%s\n", dlerror());
    require(library != NULL, "load actual display_log dylib");
    Record record = (Record)dlsym(library, "WMTDisplayLogPresent");
    Shutdown shutdown = (Shutdown)dlsym(library, "WMTDisplayLogShutdown");
    require(record && shutdown, "load diagnostic entrypoints");
    Method logger_method = class_getInstanceMethod(NSClassFromString(@"DXMTDisplayLogger"), sel_registerName("dealloc"));
    Method trace_method = class_getInstanceMethod(NSClassFromString(@"DXMTDisplayTrace"), sel_registerName("dealloc"));
    logger_dealloc = method_setImplementation(logger_method, (IMP)logger_test_dealloc);
    trace_dealloc = method_setImplementation(trace_method, (IMP)trace_test_dealloc);
    if (pre_shutdown) shutdown();
    if (init_race) {
      Method init_method = class_getInstanceMethod(NSClassFromString(@"DXMTDisplayLogger"), sel_registerName("initWithPrefix:"));
      logger_init = method_setImplementation(init_method, (IMP)logger_test_init);
    }

    NSUInteger count = rotation_mode ? 2000 : capped ? 600 : overflow ? 6000 : concurrent ? 256 : pending ? 8 : blocked ? 4 : init_race ? 1 : 64;
    id layer = [[NSObject alloc] init];
    FakeCommand **commands = calloc(count, sizeof(*commands));
    FakeDrawable **drawables = calloc(count, sizeof(*drawables));
    for (NSUInteger i = 0; i < count; ++i) {
      if (rotation_mode && i % 100 == 0) usleep(270000);
      commands[i] = [[FakeCommand alloc] initWithIdentity:i];
      drawables[i] = [[FakeDrawable alloc] initWithIdentity:i layer:layer];
      if (init_race) {
        InitRace race = {record, commands[i], drawables[i]};
        pthread_t initializer;
        require(pthread_create(&initializer, NULL, record_during_init, &race) == 0, "start paused initializer");
        double deadline = CACurrentMediaTime() + 3;
        while (!atomic_load(&init_ready) && CACurrentMediaTime() < deadline) usleep(1000);
        require(atomic_load(&init_ready), "initializer reached pre-publication handoff");
        shutdown();
        atomic_store(&init_release, true);
        pthread_join(initializer, NULL);
      } else {
        record((id<MTLCommandBuffer>)commands[i], (id<MTLDrawable>)drawables[i], i % 2 ? 1.0 / 60.0 : 0);
      }
      if (!capped && !pending && !concurrent) {
        if (i % 2) {
          if (!missing || i % 3) [drawables[i] finish];
          if (!missing || i % 2) [commands[i] finish];
        } else {
          if (!missing || i % 2) [commands[i] finish];
          if (!missing || i % 3) [drawables[i] finish];
        }
        [commands[i] release]; commands[i] = nil;
        [drawables[i] release]; drawables[i] = nil;
      }
    }
    if (capped) {
      for (NSUInteger i = 0; i < count; ++i) {
        [drawables[i] finish]; [commands[i] finish];
        [drawables[i] release]; drawables[i] = nil;
        [commands[i] release]; commands[i] = nil;
      }
    }
    if (concurrent) {
      dispatch_group_t callbacks = dispatch_group_create();
      dispatch_queue_t callback_queue = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
      for (NSUInteger i = 0; i < count; ++i) {
        dispatch_group_async(callbacks, callback_queue, ^{ @autoreleasepool { [commands[i] finish]; } });
        dispatch_group_async(callbacks, callback_queue, ^{ @autoreleasepool { [drawables[i] finish]; } });
      }
      require(dispatch_group_wait(callbacks, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0, "concurrent callbacks complete");
      dispatch_release(callbacks);
      for (NSUInteger i = 0; i < count; ++i) { [commands[i] release]; [drawables[i] release]; }
    }
    ReaderPaths reader_paths = {path, capture};
    pthread_t reader;
    if (overflow) require(pthread_create(&reader, NULL, read_fifo, &reader_paths) == 0, "start capture reader");
    double before_shutdown = CACurrentMediaTime();
    shutdown();
    double shutdown_seconds = CACurrentMediaTime() - before_shutdown;
    require(shutdown_seconds < 1.5, "shutdown bounded despite unavailable writer");
    if (blocked) {
      require(shutdown_seconds >= 0.4, "exercise timeout while FIFO writer is blocked");
      require(pthread_create(&reader, NULL, read_fifo, &reader_paths) == 0, "start delayed reader");
    }
    // Drop the caller's final loader reference BEFORE invoking late callbacks.
    // The helper's explicit RTLD_NODELETE pin must preserve callback code.
    require(dlclose(library) == 0, "close caller's library reference");
    if (pending) {
      for (NSUInteger i = 0; i < count; ++i) {
        [drawables[i] finish]; [commands[i] finish];
        [drawables[i] release]; [commands[i] release];
      }
    }
    if (overflow || blocked) pthread_join(reader, NULL);
    free(commands); free(drawables); [layer release];
    double deadline = CACurrentMediaTime() + 3;
    while (!disabled && !pre_shutdown && atomic_load(&logger_destroyed) != 1 && CACurrentMediaTime() < deadline) usleep(1000);
    require(atomic_load(&commands_destroyed) == count && atomic_load(&drawables_destroyed) == count, "no Metal-object retention cycles");
    require(atomic_load(&logger_destroyed) == (disabled || pre_shutdown ? 0u : 1u), "logger deallocates after timer/queued work/late callbacks");
    unsigned traces = atomic_load(&trace_destroyed);
    require(disabled || pre_shutdown || init_race ? traces == 0 : capped ? traces == 512 : traces == count, "all accepted trace tokens deallocate");
    printf("{\"mode\":\"%s\",\"pid\":%d,\"count\":%lu,\"traces\":%u,\"shutdown_seconds\":%.3f,\"fifo\":%s}\n",
           mode, getpid(), (unsigned long)count, traces, shutdown_seconds, overflow || blocked ? "true" : "false");
  }
  return 0;
}
