#include <assert.h>
#include <dlfcn.h>
#include <stdio.h>
#include <sqlite3.h>
#include <unistd.h>

int main(int argc, char **argv) {
  assert(argc == 3);
  void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!library) { fprintf(stderr, "%s\n", dlerror()); return 1; }
  void (*enqueue)(const char *) = dlsym(library, "cache_writer_enqueue_then_release");
  assert(enqueue);
  enqueue(argv[2]);
  assert(dlclose(library) == 0);
  Dl_info info;
  assert(dladdr((const void *)enqueue, &info) != 0);
  /* Poll only our private SQLite file; never invoke library code after close. */
  int count = 0;
  for (int i = 0; i < 100 && count != 1000; i++) {
    usleep(20000);
    sqlite3 *db = NULL;
    assert(sqlite3_open_v2(argv[2], &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK);
    sqlite3_stmt *stmt = NULL;
    int rc = sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM cache_24", -1, &stmt, NULL);
    if (rc == SQLITE_BUSY || rc == SQLITE_LOCKED) { sqlite3_close(db); continue; }
    if (rc != SQLITE_OK) fprintf(stderr, "reader prepare failed: %s (%d)\n", sqlite3_errmsg(db), rc);
    assert(rc == SQLITE_OK);
    rc = sqlite3_step(stmt);
    if (rc == SQLITE_BUSY || rc == SQLITE_LOCKED) { sqlite3_finalize(stmt); sqlite3_close(db); continue; }
    assert(rc == SQLITE_ROW);
    count = sqlite3_column_int(stmt, 0);
    sqlite3_finalize(stmt);
    sqlite3_close(db);
  }
  assert(count == 1000);
  puts("PASS dlclose with queued writes: ObjC MH_DYLIB remains mapped, 1000 entries persisted");
  return 0;
}
