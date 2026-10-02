# DXMT shader lifetime regression harness

Run `python3 tests/shader_lifetime/run.py` from the experiment directory.

This compiles a small native command-line C++ program using the **actual destructor
and compile-work method bodies extracted from the local DXMT source**. Deterministic
stubs simulate allocations, IR restoration, compilation, and Metal library errors.
It does not build DXMT, run Xcode, modify the installed translator, or launch a game.
Temporary generated source and executable files are removed after each run.

Cases cover metadata destruction after early IR release, normal metadata teardown,
cache hits, rejected cache entries, successful compilation, failed primary/secondary
IR restoration, compiler failure, Metal library failure (with and without an error
object), and missing Metal functions. Every branch checks that IR holders are
released once; paths producing bitcode check that it is destroyed once.

The same harness can target a separate checkout with `--source /path/to/dxmt`.
Against the original source, it exposes the metadata leak, two null-IR compile
paths, a bitcode leak on Metal library error, and caching after a null library result.

These are allocation/control-flow regression checks. They do **not** prove Metal
integration, concurrent scheduling correctness, gameplay performance, or that any
fixed error path caused the observed Overwatch stutters.

## First-use compilation and early IR release

The compile-work harness also rejects any Metal compilation or cache write that
still holds this task's parsed shader IR. The actual guard now releases exactly
once immediately after synchronous DXBC-to-AIR conversion, before library/function
creation and cache I/O. The compiled bitcode owns independent serialized bytes.
Other queued/running tasks retain their own `ir_pending_` references; this change
does not change compiler concurrency or release another task's borrowed IR.

The harness verifies that a missing Metal function does not enter the persistent
cache, in addition to the existing library-rejection checks.

`DXMT_SHADER_LOG=<Windows path prefix>` enables per-variant CSV diagnostics named
`<prefix>-<Windows process ID>.csv`. The stream has a 100,000-attempt limit per
process and a bounded asynchronous writer that flushes every 250 ms. Normal I/O
therefore limits abrupt-exit loss to the newest flush interval; blocked I/O or
scheduling can extend it. Disabled runs open no files. No shader bytecode, game identifiers, or
account/session information is recorded: keys are SHA-1 digests plus fixed status
labels and timings.

Columns distinguish cache hit, missing entry, rejected library, and rejected
function; they measure queue delay, cache read, IR restoration, DXBC-to-AIR
translation, IR release, Metal library/function creation, cache write, and total
task duration. IR restoration includes lock waiting as well as parsing. The
record's `start_unix_us` supports correlation with other logs; durations use a
monotonic clock. Total duration excludes writing the trace row itself and does
not measure downstream pipeline-state construction, GPU work, or screen display.
Diagnostics introduce some overhead and remain opt-in.

The tests compile the real trace helper and verify statuses on every task exit,
digest-only keys, duration fields, and that disabled tracing creates no files.

### Downstream Metal pipeline creation and first-use waits

The same `DXMT_SHADER_LOG` prefix also creates
`<prefix>-pipelines-<Windows process ID>.csv`. Each graphics, compute, geometry,
or tessellation pipeline receives a process-local numeric identity when created.
`createMetal` measures the synchronous Metal pipeline creation call; the existing
tessellation mutex wait is excluded. `wait` measures the existing pipeline-ready
wait, including shader dependencies, scheduling, pipeline compilation, and
waking the waiting caller. These intervals can overlap; **do not add them together**.

Already-ready pipelines do not read clocks or emit wait records. Initially
not-ready waits lasting at most 100 microseconds contribute only to aggregate
counts/totals. Longer waits and Metal creation calls enqueue bounded event rows.
Each event stream is capped at 100,000 candidate attempts. Periodically and on explicit shutdown,
`<prefix>-summary-<Windows process ID>.csv` reports written/dropped rows and
pipeline wait/create sample counts and total durations. Wait aggregates cover
initially not-ready calls, not every `GetPipeline` invocation.

The sink and its bounded queue deliberately live for the process lifetime.
One detached writer owns every FILE operation; producers use a try-lock and
disclose contention/overflow drops. Windows pins the diagnostic DLL while tracing
is active. Its `atexit` handler only changes atomics because other threads may
already have been terminated while holding a lock. Explicit shutdown stops
admission and waits at most 500 ms for the writer; late writes become no-ops.
The summary distinguishes flushed records, pending records and dropped records.

Run `python3 tests/shader_lifetime/run_pipeline_trace.py`. It executes the actual
four pipeline `GetPipeline`, `GetIsDone`, and `SetIsDone` bodies, the actual
completion helper, and actual Metal-call scopes with host stubs. It checks
successful and failed/null results are published, calls are neither duplicated
nor retried, already-ready paths emit no wait row, and quiet mode creates no
trace files or publication timestamps. It also verifies the 100-microsecond
threshold, row caps, aggregate/drop accounting, concurrent shutdown, and ignored
late writes. Publication and wait-return monotonic timestamps measure wakeup
delay separately from the whole wait. See `tests/pipeline_ready/README.md` for
the actual Windows synchronization benchmark and additional concurrency checks.

## Shader variant lookup

Run `python3 tests/shader_lifetime/run_variants.py`.

The runner extracts the real eight variant structures, equality operators, and
hash specialization from `d3d11_shader.hpp`, replacing only external pointer and
enum declarations with host stubs. It checks equal values with deliberately
different padding bytes and exercises all 23 equality fields. Hashing uses each
field's value, including pointer identity; no persisted shader-cache digest changes.

An intentionally large synthetic table of 8,192 pixel-shader variants compares
the original type-only hash against the patched hash using the same keys and
standard-library container. The original required 33,558,528 equality comparisons
for 8,192 lookups, with all 8,192 keys in one bucket; the patch required 8,194
comparisons, with a maximum bucket size of seven. One local run took about 74 ms
versus 0.24 ms. These are synthetic lookup numbers, **not game frame-time gains**;
the number of variants attached to real Overwatch shaders has not been measured.

## Converter error-object ownership

Run `python3 tests/shader_lifetime/run_airconv.py`.

The runner extracts the **complete bodies of all five SM50 compile APIs** and
their real error/bitcode types and cleanup functions. LLVM conversion and Metal
library serialization are deterministic stubs; owned buffers count live storage.
Each API exercises success, conversion failure, and invalid output arguments.
The initialization ownership prologue is also extracted and tested for success
and invalid output, while full DXBC parsing/reflection are outside this harness.
A source audit verifies all six scoped allocations and 17 explicit error transfers.

The patch keeps the exported ABI and caller error-ownership contract unchanged:
success automatically destroys the unused error object, and failure transfers it
to the caller for `SM50FreeError`. Original source fails the success ownership check.
This removes a confirmed small leak per successful shader parse or conversion;
its contribution to actual game memory pressure remains unmeasured.
