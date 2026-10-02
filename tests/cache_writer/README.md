# Asynchronous DXMT shader-cache persistence

This local patch changes `runtime/source/dxmt-ow2/src/winemetal/unix/cache.c`.
It does not change cache keys, shader bytecode, compiled shader output, or the
SQLite schema. The existing `cache_24` database remains usable.

## Mechanism

Previously each newly translated shader performed an `INSERT OR REPLACE` in its
compilation task, under the single cache-writer mutex, before publishing task
completion. Each insert used its own SQLite transaction; the existing WAL
connection can also run automatic checkpoints during commit. Thus disk work and
other writers could delay shader readiness. This mechanism is established by
source inspection, **not measured as the cause of our Overwatch stalls**.

The local change copies the thunk's borrowed key bytes, retains its dispatch-data
value, and enqueues optional persistence onto one utility-priority serial GCD
queue. Queue accounting caps outstanding keys and payloads plus a 256-byte
per-entry allocation allowance at 16 MiB. This is a pending-data accounting cap,
not a claim that SQLite, GCD, temporary flattened data, and allocator overhead
consume exactly 16 MiB total. If the cap is reached, that cache write is dropped;
rendering and shader compilation continue unchanged. Future sessions may need
to compile that variant again.

The writer batches at most 32 successful inserts per transaction. A delayed
commit after 20 ms limits idle dirty time; dispatch scheduling or a disk stall can
make it later, so this is not a hard real-time durability deadline. SQLite busy
errors fail fast, rollbacks discard only optional cache work, and the next entry
can retry normally. WAL/NORMAL settings are unchanged. No system settings or
live shader databases are changed by the harness.

Queued blocks retain the writer until they finish. Each worker block has an
autorelease pool; final release closes SQLite without a synchronous main-thread
queue drain. Caller-owned key and value buffers can be released immediately
following `set`. Static SQLite bindings are cleared before backing data is
released, including the reader's borrowed key binding.

An abrupt process exit can lose the last partial cache batch, up to 31 entries;
a failed transaction or queue overflow can also omit optional persistence. WAL
recovery protects previously committed entries. This is expendable cached data,
not game installation or account data.

## Verification

Run from the experiment directory:

```sh
python3 tests/cache_writer/run.py
```

The runner uses command-line Clang to include and compile the **actual modified
cache.c** in a standalone executable, not a reimplementation. It does not invoke
Xcode, build a DXMT/Wine runtime, or replace any deployed DLL/library. The only
stubs are unrelated private Metal cache-path functions, which these tests never
call. All database files and test executables live in a temporary subdirectory of
`runtime/diagnostics` and are removed automatically.

The test runs as native arm64 with AddressSanitizer and UndefinedBehaviorSanitizer,
and separately as x86_64 under Rosetta without sanitizers. LeakSanitizer is
unsupported on macOS and is explicitly disabled. Both architectures passed on
2026-09-11:

- Borrowed stack-key mutation and immediate dispatch-data release preserve values.
- Four simultaneous producers persist 400 distinct entries without loss.
- A deliberately suspended private test queue accepts 15 one-MiB entries, skips
  nine excess entries, and never exceeds its pending-data accounting cap.
- An external SQLite transaction causes fail-fast misses; after rollback, writes
  succeed again.
- Releasing the caller's writer while work remains queued still persists the work.
- An invalid database parent fails initialization safely.
- Abrupt process exit after 1,000 writes recovers an intact database with the 992
  committed entries; its eight uncommitted tail entries may be discarded.

Compiler flags include `-Wall -Wextra -Werror`. This validates cache queue and
lifetime behavior in isolation. It does **not** verify the full winemetal build,
Wine ABI integration, render correctness, or improved gameplay frame times.

## Read-only audit findings

Before changes, the live cache contained 1,787 entries / 27,499,182 bytes of shader
values, in a WAL database. There were no CacheReader/CacheWriter failure markers
in the inspected DXMT diagnostic logs. Serial Python SQLite reads on this Mac
reported p99 327 microseconds on the first pass and 14 microseconds on a repeat;
OS caches were already warmed by inspection. These are not measurements of Wine
mutex contention or an active match, and do not implicate ordinary cache reads
in the observed 50-100 ms stalls.

This cache stores translated shader library data, not every native Metal pipeline
state. Even a DXMT cache hit calls `newLibrary` / `newFunction`; rendering can still
wait for `newRenderPipelineState` / `newComputePipelineState`. The patch removes
optional disk persistence from shader completion, not all first-use compilation.

## Adversarial lifetime review

The C++ shader cache is module-static, which alone does not guarantee process
lifetime. Wine 11's `release_builtin_module` calls `dlclose` on a builtin Unix
library when its module reference count reaches zero. Queued Objective-C objects
are not a general substitute for pinning executable code.
[Wine source](https://github.com/wine-mirror/wine/blob/wine-11.0/dlls/ntdll/unix/virtual.c)

For this macOS build, the bridge is an Objective-C **MH_DYLIB**, not an unloadable
MH_BUNDLE: the source uses Meson `shared_library`, and the installed winemetal.so
Mach header is DYLIB with TLV descriptors. Apple's dyld marks Objective-C
non-bundle images as never-unloadable; TLV descriptors independently impose the
same policy. The async patch therefore does not need an additional dlopen pin for
this build. This conclusion does not automatically transfer to a future
MH_BUNDLE build, another operating system, or a loader using forced unload.
[Apple dyld source](https://github.com/apple-oss-distributions/dyld/blob/main/common/MachOAnalyzer.cpp)

The runner now verifies that assumption experimentally on both tested
architectures. It compiles the actual cache.c implementation into an MH_DYLIB,
queues 1,000 writes behind a 250 ms test-only delay, releases the writer, and
immediately dlcloses the library. The executable confirms with dladdr that the
image remains mapped and observes all 1,000 entries committed afterward. This
passed on native arm64 with ASan/UBSan and x86_64 under Rosetta. The private test
reader tolerates transient SQLite BUSY/LOCKED while polling. The two additional
source files are `unload_test_library.m` and `unload_test_main.c`.

A lifecycle subclass test also verifies actual deallocation, rather than merely
observing completed writes: the last reference disappears on the writer's own
serial queue after the idle commit, the base destructor returns, and a semaphore
notifies the test. There is no synchronous dispatch to the same queue and no
recurring timer to retain the object forever. A stalled storage operation or a
queue that cannot be scheduled can still postpone cleanup; abrupt process exit
can discard optional tail writes.

SQLite handling is deliberately best-effort. BEGIN contention leaves the local
transaction flag unset; failed inserts are reset/unbound then rolled back;
failed commits attempt rollback before clearing transaction state. Final cleanup
commits any remaining batch, finalizes the only persistent prepared statement,
then closes SQLite and releases the queue. Catastrophic I/O failure, allocation
failure, filesystem corruption, and rollback failure were not fault-injected;
the writer is not a database repair or guaranteed-durability service.
