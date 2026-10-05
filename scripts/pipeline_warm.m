// pipeline-warm <learned folder> <Metal cache folder> <selection.json> <log prefix> <seconds>
//
// macOS keeps compiled shaders per app. With Game Mode, Overwatch runs as the
// engine's game app, whose cache starts empty after an update or a macOS update,
// so every pipeline the game learned is compiled again mid-match. This compiles
// the selected learned pipelines into that app's cache before the session: the
// cache only stores Metal's own compiled functions, keyed by what was compiled,
// so the game finds them whichever process compiled them. No binary archive.
// Prints a JSON summary; writes one prewarm record per pipeline to
// <log prefix>-<pid>.jsonl (the format ow2-pipeline's progress feed reads).
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <time.h>
#import "pipeline_recipe.h"

// Metal's own setting (DXMT uses it too). The location is fixed at first use.
extern void MTLSetShaderCachePath(NSString *path);
extern NSString *MTLGetShaderCachePath(void);

static double now(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9; }
static NSData *readBounded(NSString *path, size_t limit) {
  int fd = open(path.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return nil;
  struct stat info;
  NSData *data = nil;
  if (!fstat(fd, &info) && S_ISREG(info.st_mode) && info.st_size > 0 && (size_t)info.st_size <= limit) {
    NSMutableData *buffer = [NSMutableData dataWithLength:(NSUInteger)info.st_size];
    if (pread(fd, buffer.mutableBytes, buffer.length, 0) == (ssize_t)buffer.length) data = buffer;
  }
  close(fd);
  return data;
}
static NSString *digest(NSData *data) {
  if (!data) return nil;
  unsigned char hash[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, hash);
  NSMutableString *text = [NSMutableString stringWithCapacity:64];
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [text appendFormat:@"%02x", hash[i]];
  return text;
}
static BOOL validKey(id key) {
  if (![key isKindOfClass:NSString.class] || [key length] != 64) return NO;
  return [key rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
}

int main(int argc, char **argv) {
  @autoreleasepool {
    if (argc != 6) return 64;
    NSString *folder = @(argv[1]), *cachePath = @(argv[2]);
    double seconds = atof(argv[5]);
    if (!cachePath.isAbsolutePath || !(seconds > 0)) return 64;
    // Before any other Metal call, and confirmed: compiling into another cache
    // would only cost the player time.
    if (![NSFileManager.defaultManager createDirectoryAtPath:cachePath withIntermediateDirectories:YES attributes:nil error:nil]) return 3;
    MTLSetShaderCachePath(cachePath);
    if (![MTLGetShaderCachePath() isEqualToString:cachePath]) return 3;
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) return 2;
    NSData *listing = readBounded(@(argv[3]), 4 * 1024 * 1024);
    NSArray *keys = listing ? [NSJSONSerialization JSONObjectWithData:listing options:0 error:nil] : nil;
    if (![keys isKindOfClass:NSArray.class] || keys.count > 32768) return 4;
    for (id key in keys) if (!validKey(key)) return 4;
    NSString *logPath = [NSString stringWithFormat:@"%s-%d.jsonl", argv[4], getpid()];
    int logFd = open(logPath.fileSystemRepresentation, O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0600);
    // Shared with the compile callbacks, which skip it once it is closed.
    __block FILE *log = logFd >= 0 ? fdopen(logFd, "w") : NULL;
    if (!log) return 5;

    // Metal compiles several pipelines at once for one process; separate
    // processes writing one cache lose each other's entries.
    long cores = (long)NSProcessInfo.processInfo.activeProcessorCount;
    long width = MIN(16, MAX(4, cores + cores / 2));
    dispatch_semaphore_t slots = dispatch_semaphore_create(width);
    dispatch_group_t group = dispatch_group_create();
    NSObject *lock = [[NSObject alloc] init];
    __block long warmed = 0, failed = 0;
    long attempted = 0;
    BOOL stopped = NO;
    double deadline = now() + seconds;
    for (NSString *key in keys) {
      if (now() >= deadline) { stopped = YES; break; }
      @autoreleasepool {
        NSData *data = readBounded([folder stringByAppendingFormat:@"/recipes/%@.json", key], DXMT_RECIPE_ENCODED_MAX_BYTES * 2);
        NSDictionary *envelope = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *recipe = [envelope isKindOfClass:NSDictionary.class] ? dxmt_recipe_decode(dxmt_recipe_encode(envelope[@"recipe"])) : nil;
        NSError *error = nil;
        MTLRenderPipelineDescriptor *descriptor = recipe && [dxmt_recipe_key(recipe) isEqual:key]
            ? dxmt_recipe_restore(device, recipe, ^NSData *(NSString *sha256) {
                NSData *bytes = validKey(sha256) ? readBounded([folder stringByAppendingFormat:@"/libraries/%@.air", sha256], DXMT_RECIPE_LIBRARY_MAX_BYTES) : nil;
                return [digest(bytes) isEqualToString:sha256] ? bytes : nil;
              }, &error) : nil;
        ++attempted;
        if (!descriptor) {
          @synchronized(lock) { ++failed; fprintf(log, "{\"event\":\"prewarm\",\"key\":\"%s\",\"success\":false,\"duration_us\":0}\n", key.UTF8String); fflush(log); }
          continue;
        }
        dispatch_semaphore_wait(slots, DISPATCH_TIME_FOREVER);
        dispatch_group_enter(group);
        double began = now();
        const char *name = strdup(key.UTF8String);
        [device newRenderPipelineStateWithDescriptor:descriptor completionHandler:^(id<MTLRenderPipelineState> state, NSError *compileError) {
          (void)compileError;
          @synchronized(lock) {
            if (state) ++warmed; else ++failed;
            if (log) fprintf(log, "{\"event\":\"prewarm\",\"key\":\"%s\",\"success\":%s,\"duration_us\":%.0f}\n", name, state ? "true" : "false", (now() - began) * 1e6);
            if (log) fflush(log);
          }
          free((void *)name);
          dispatch_semaphore_signal(slots);
          dispatch_group_leave(group);
        }];
        [descriptor release];
      }
    }
    // A compile in flight cannot be cancelled; wait for it a little.
    BOOL drained = !dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
    long done, bad;
    @synchronized(lock) { done = warmed; bad = failed; fclose(log); log = NULL; }
    NSDictionary *summary = @{@"attempted": @(attempted), @"warmed": @(done), @"failed": @(bad),
        @"complete": @(!stopped && drained && attempted == (long)keys.count), @"cache": MTLGetShaderCachePath(), @"width": @(width)};
    NSData *output = [NSJSONSerialization dataWithJSONObject:summary options:NSJSONWritingSortedKeys error:nil];
    fwrite(output.bytes, 1, output.length, stdout); fputc('\n', stdout); fflush(stdout);
    // Objects a late callback may still use are left to the process exit.
    return 0;
  }
}
