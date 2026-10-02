/* Standalone test of the actual modified implementation, using only temporary
 * SQLite files. No Wine process, game asset, or live shader cache is touched. */
#include <assert.h>
#include <fcntl.h>
#include <sys/file.h>
#include <unistd.h>
#include <objc/runtime.h>
#include "../../runtime/source/dxmt-ow2/src/winemetal/unix/cache.c"

/* cache.c also exports an unrelated private Metal-cache-path thunk. This test
 * never calls it; these stubs let us link only Foundation and SQLite. */
void MTLSetShaderCachePath(NSString *path) { (void)path; }
NSString *MTLGetShaderCachePath(void) { return nil; }

static void *ivarAddress(id object, const char *name) {
  Ivar ivar = class_getInstanceVariable([object class], name);
  assert(ivar);
  return (char *)object + ivar_getOffset(ivar);
}
static dispatch_queue_t queueFor(CacheWriter *writer) {
  return *(dispatch_queue_t *)ivarAddress(writer, "_queue");
}
static char lifecycleQueueKey;
static dispatch_semaphore_t lifecycleComplete;
@interface LifecycleCacheWriter : CacheWriter
@end
@implementation LifecycleCacheWriter
- (void)dealloc {
  assert(dispatch_get_specific(&lifecycleQueueKey) == &lifecycleQueueKey);
  [super dealloc];
  dispatch_semaphore_signal(lifecycleComplete);
}
@end

static size_t pendingBytes(CacheWriter *writer) {
  os_unfair_lock *lock = ivarAddress(writer, "_pendingLock");
  os_unfair_lock_lock(lock);
  size_t result = *(size_t *)ivarAddress(writer, "_pendingBytes");
  os_unfair_lock_unlock(lock);
  return result;
}
static uint64_t drops(CacheWriter *writer) {
  os_unfair_lock *lock = ivarAddress(writer, "_pendingLock");
  os_unfair_lock_lock(lock);
  uint64_t result = *(uint64_t *)ivarAddress(writer, "_droppedWrites");
  os_unfair_lock_unlock(lock);
  return result;
}
static void drainAndCommit(CacheWriter *writer) {
  dispatch_sync(queueFor(writer), ^{});
  usleep(60000); /* let the production 20 ms idle commit run */
  dispatch_sync(queueFor(writer), ^{});
  assert(pendingBytes(writer) == 0);
}
static sqlite3 *openReader(NSString *path) {
  sqlite3 *db = NULL;
  assert(sqlite3_open_v2(path.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK);
  return db;
}
static int entryCount(NSString *path) {
  sqlite3 *db = openReader(path);
  sqlite3_stmt *stmt = NULL;
  assert(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM cache_24", -1, &stmt, NULL) == SQLITE_OK);
  assert(sqlite3_step(stmt) == SQLITE_ROW);
  int count = sqlite3_column_int(stmt, 0);
  sqlite3_finalize(stmt);
  sqlite3_close(db);
  return count;
}
static dispatch_data_t makeValue(size_t size, unsigned char byte) {
  void *buffer = malloc(size);
  assert(buffer);
  memset(buffer, byte, size);
  return dispatch_data_create(buffer, size, NULL, DISPATCH_DATA_DESTRUCTOR_FREE);
}
static void put(CacheWriter *writer, uint64_t key, size_t size) {
  NSData *keyData = [[NSData alloc] initWithBytesNoCopy:&key length:sizeof(key) freeWhenDone:NO];
  dispatch_data_t value = makeValue(size, key & 255);
  [writer set:keyData value:value];
  [keyData release];
  dispatch_release(value);
}

int main(int argc, char **argv) {
  assert(argc == 2 || argc == 3);
  @autoreleasepool {
    NSString *root = [NSString stringWithUTF8String:argv[1]];
    NSString *path = [root stringByAppendingPathComponent:@"cache.db"];
    CacheWriter *writer = [[CacheWriter alloc] initWithPath:path version:24];
    assert(writer);
    if (argc == 3 && strcmp(argv[2], "abrupt-exit") == 0) {
      for (uint64_t i = 0; i < 1000; i++) put(writer, i, 128);
      dispatch_sync(queueFor(writer), ^{});
      /* Intentionally bypass Objective-C/GCD/SQLite teardown. At most the last
       * partial batch is expendable; committed data must recover correctly. */
      _exit(0);
    }

    /* Queue payload must outlive all borrowed caller buffers. */
    dispatch_suspend(queueFor(writer));
    unsigned char borrowedKey[] = {1, 2, 3, 4};
    NSData *key = [[NSData alloc] initWithBytesNoCopy:borrowedKey length:4 freeWhenDone:NO];
    dispatch_data_t value = makeValue(128, 0xa5);
    [writer set:key value:value];
    memset(borrowedKey, 0xff, sizeof(borrowedKey));
    [key release];
    dispatch_release(value);
    dispatch_resume(queueFor(writer));
    drainAndCommit(writer);
    CacheReader *reader = [[CacheReader alloc] initWithPath:path version:24];
    assert(reader);
    unsigned char expectedKey[] = {1, 2, 3, 4};
    NSData *query = [[NSData alloc] initWithBytes:expectedKey length:4];
    dispatch_data_t result = [reader get:query];
    assert(result && dispatch_data_get_size(result) == 128);
    const void *bytes = NULL;
    size_t length = 0;
    dispatch_data_t flat = dispatch_data_create_map(result, &bytes, &length);
    for (size_t i = 0; i < length; i++) assert(((const unsigned char *)bytes)[i] == 0xa5);
    dispatch_release(flat);
    dispatch_release(result);
    [query release];
    [reader release];
    printf("PASS borrowed-key and dispatch-data lifetime; idle commit\n");

    /* Multiple producers use one SQLite queue; each entry has a unique key. */
    dispatch_apply(4, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t producer) {
      @autoreleasepool {
        for (uint64_t i = 0; i < 100; i++) put(writer, 1000 + producer * 100 + i, 2048);
      }
    });
    drainAndCommit(writer);
    assert(drops(writer) == 0);
    assert(entryCount(path) == 401);
    printf("PASS concurrent producers and batched persistence (400 entries)\n");

    /* Block only our private test queue, forcing the production overflow path. */
    dispatch_suspend(queueFor(writer));
    for (uint64_t i = 0; i < 24; i++) put(writer, 2000 + i, 1024 * 1024);
    assert(pendingBytes(writer) <= kCachePendingByteLimit);
    assert(drops(writer) == 9);
    dispatch_resume(queueFor(writer));
    drainAndCommit(writer);
    assert(entryCount(path) == 416);
    printf("PASS bounded pending memory and nonblocking queue-full drops (15 accepted, 9 skipped)\n");
    [writer release];

    /* Another process holding the SQLite write lock must not stall compilation
     * or poison future persistence attempts. */
    NSString *busyPath = [root stringByAppendingPathComponent:@"busy.db"];
    writer = [[CacheWriter alloc] initWithPath:busyPath version:24];
    assert(writer);
    sqlite3 *competing = NULL;
    assert(sqlite3_open(busyPath.fileSystemRepresentation, &competing) == SQLITE_OK);
    assert(sqlite3_exec(competing, "BEGIN IMMEDIATE;", NULL, NULL, NULL) == SQLITE_OK);
    for (uint64_t i = 0; i < 10; i++) put(writer, i, 128);
    drainAndCommit(writer);
    assert(entryCount(busyPath) == 0);
    assert(sqlite3_exec(competing, "ROLLBACK;", NULL, NULL, NULL) == SQLITE_OK);
    sqlite3_close(competing);
    put(writer, 100, 128);
    drainAndCommit(writer);
    assert(entryCount(busyPath) == 1);
    [writer release];
    printf("PASS competing SQLite writer: fail fast, then recover\n");

    /* No synchronous teardown drain is needed: queued blocks retain writer. */
    NSString *releasePath = [root stringByAppendingPathComponent:@"release.db"];
    writer = [[LifecycleCacheWriter alloc] initWithPath:releasePath version:24];
    assert(writer);
    lifecycleComplete = dispatch_semaphore_create(0);
    dispatch_semaphore_t start = dispatch_semaphore_create(0);
    dispatch_queue_set_specific(queueFor(writer), &lifecycleQueueKey, &lifecycleQueueKey, NULL);
    dispatch_async(queueFor(writer), ^{ dispatch_semaphore_wait(start, DISPATCH_TIME_FOREVER); });
    for (uint64_t i = 0; i < 10; i++) put(writer, i, 128);
    [writer release];
    dispatch_semaphore_signal(start);
    assert(dispatch_semaphore_wait(lifecycleComplete, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) == 0);
    dispatch_release(start);
    dispatch_release(lifecycleComplete);
    assert(entryCount(releasePath) == 10);
    printf("PASS caller release: idle timer commits, writer deallocates on its own queue, SQLite closes\n");

    NSString *badParent = [root stringByAppendingPathComponent:@"regular-file"];
    assert([@"not a directory" writeToFile:badParent atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    assert([[CacheWriter alloc] initWithPath:[badParent stringByAppendingPathComponent:@"cache.db"] version:24] == nil);
    printf("PASS initialization failure cleanup\n");
  }
  return 0;
}
