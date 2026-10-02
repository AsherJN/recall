# Bounded shader/pipeline trace writer checks

`python3 tests/shader_trace/run.py` compiles the current, actual
`d3d11_shader_trace.hpp` into a native host harness with AddressSanitizer and
UndefinedBehaviorSanitizer. It checks:

- Disabled tracing creates no files.
- Two sparse bursts survive `_Exit`, which bypasses destructor/atexit flushing.
- Normal host atexit drains queued rows.
- Eight concurrent producers preserve exact final row/drop accounting once the
  producers finish.
- A FIFO deliberately blocks the writer in `fopen`; producers still finish,
  the 2,048-record queue bounds memory, and explicit shutdown returns within its
  500 ms deadline plus scheduling tolerance. Releasing the FIFO allows the
  detached writer to drain safely; late writes are ignored.
- The 100,000-attempt budget for each stream and queue/limit drops are disclosed.
- Ready publication, wait return, and their difference use the same monotonic
  microsecond clock, independently of GPU completion timestamps.

The sink is intentionally retained for the lifetime of the process, so leak
reporting is disabled in this harness. Address and undefined-behavior checks
remain enabled. Native host checks do not prove Wine DLL teardown behavior.

`run_wine.py` compiles the actual header into a Windows DLL with the workspace
LLVM-MinGW toolchain, then exercises the DLL with the current Wine engine. Run
from the workspace root using an existing isolated diagnostic prefix:

```sh
python3 tests/shader_trace/run_wine.py \
  --prefix runtime/diagnostics/prefix-window-sizing-20260911-124251
```

The runner requires the prefix to live under `runtime/diagnostics`; it stops that
prefix's Wine server after testing. It never uses the game prefix. An optional
`--engine` selects a different prepared engine.

The September 11, 2026 Windows run passed all four cases:

- Sparse records survived `TerminateProcess`, including a late second record,
  without an orderly final flush.
- `FreeLibrary` left the active trace DLL pinned. Four threads made 80 late calls
  safely; 78 rows were persisted and three queue-contention drops were disclosed
  out of 81 total attempts. Explicit shutdown took 18 ms, and subsequent writes
  were ignored.
- Normal `ExitProcess` completed safely and retained the prior periodic record.
- Disabled tracing created no CSV files and allowed the DLL to unload normally.

[The complete report](../../logs/dxmt/shader-trace-windows-20260911-140719/report.json)
records the actual header, DLL and executable hashes, compiler commands, and row
counts. The Windows harness tests lifecycle behavior without sanitizers; it does
not reproduce every possible game teardown or storage failure.

The periodic summary is a replaced, complete snapshot rather than an append-only
file. `records` counts rows successfully flushed to the operating system, not an
`fsync` durability guarantee. `pending` includes queued/unflushed rows; `dropped`
is split into limit, queue contention/overflow/shutdown, and I/O loss. Live
counters are sampled separately, and in-flight calls can cross the snapshot
boundary. `final` means the writer's final snapshot, not proof that every caller
was quiescent.

Windows atexit only stops admission using atomics. This avoids waiting on locks
that an already terminated thread might have owned during `ExitProcess`.
Periodic 250 ms flushing therefore matters: responsive I/O and scheduling
normally leave only the newest interval at risk, while blocked I/O or scheduling
can extend the loss window. A record missing because of telemetry loss must not
be counted as a measured gameplay stall.
The tests do not equate tracing correctness with improved game performance.
