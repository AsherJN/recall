/* Reuse the actual-source harness helpers without running its full test main. */
#define main cache_writer_full_test
#include "cache_writer_test.m"
#undef main

void cache_writer_enqueue_then_release(const char *path) {
  @autoreleasepool {
    CacheWriter *writer = [[CacheWriter alloc] initWithPath:[NSString stringWithUTF8String:path] version:24];
    assert(writer);
    /* Force work to remain pending when the executable immediately dlcloses
     * this MH_DYLIB. This delay exists only in the isolated unload test. */
    dispatch_async(queueFor(writer), ^{ usleep(250000); });
    for (uint64_t i = 0; i < 1000; i++) put(writer, i, 128);
    [writer release];
  }
}
