# One-shot pipeline completion validation

These checks include the production `d3d11_pipeline_ready.hpp`; they do not copy
its implementation. All files and runtime artifacts stay in this experiment.

Run the native AddressSanitizer/UndefinedBehaviorSanitizer harness:

```sh
python3 tests/pipeline_ready/run.py
```

The native primitives have test-only counters and a gate that holds a waiter
between its failed predicate check and condition-variable registration. This
proves publication uses the same mutex and cannot be lost at that boundary.
The suite also exercises completion before waiting, 100,000 ready-path calls
without a mutex/condition-variable call, duplicate publication, disabled timing,
spurious notifications, twelve simultaneous waiters, ordinary non-atomic result
visibility, failed/null results, 1,200 publication races, and destruction after
all waiters and publishers have joined. The primitive stubs are not used by Wine.

The integration harness extracts the actual four `GetPipeline`, `GetIsDone`, and
`SetIsDone` method bodies plus their Metal-call scopes, and includes the real
completion helper and trace sink. Metal is stubbed for deterministic success and
failure. It validates readiness publication, disabled timing, fast-path trace
suppression, all four pipeline kinds, readiness-to-return timestamp arithmetic,
bounded asynchronous log accounting, and shutdown:

```sh
python3 tests/shader_lifetime/run_pipeline_trace.py
```

For the actual Windows primitives, compile and execute the production header and
`src/util/thread.hpp` with the same statically linked LLVM-MinGW compiler used by
the DXMT build:

```sh
python3 tests/pipeline_ready/run_wine.py \
  --prefix runtime/diagnostics/prefix-window-sizing-20260911-124251
```

This script requires an existing isolated prefix under `runtime/diagnostics`,
never uses an active game prefix, and stops only that diagnostic wineserver. It
runs 800 Windows waiter-release checks including published results and failures,
then interleaves 192 timing trials across old/new mechanisms and readiness
delays of 0, 1, 5, 20, 40, 80, 120, and 160 ms. Each repeat alternates which
mechanism runs first. The reported interval starts immediately before publishing
readiness and ends immediately after the waiting call returns; it includes the
signal call and OS scheduling. Zero-delay trials are reported separately since
completion may precede blocking. Raw nanosecond timestamps, a summary, compiler
command, and source/binary hashes are saved under `logs/dxmt/pipeline-ready-*`.

The first production-helper run, `pipeline-ready-20260911-140128`, passed all
correctness checks. Its 84 nonzero-delay trials per mechanism measured:

| Mechanism | Median | p95 | Maximum |
| --- | ---: | ---: | ---: |
| Existing static libc++ atomic wait | 5.747 ms | 23.398 ms | 35.484 ms |
| Production SRW/condition-variable helper | 0.0313 ms | 0.087 ms | 2.075 ms |

This is a synthetic console comparison with no Metal compilation or gameplay
load. It validates removal of the polling delay; it does not predict game FPS,
remove compilation work, or prove that every wakeup is instantaneous.
