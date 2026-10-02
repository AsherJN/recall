# Native display timing diagnostics

`DXMT_DISPLAY_LOG=/absolute/native/macOS/path/prefix` enables the optional
native Metal logger. Each host process writes `prefix-<native PID>.csv`.
The directory must already exist. This path and PID use macOS conventions;
the existing frame and geometry logs use Wine paths and Windows PIDs.
An unset variable or a value without a leading `/` leaves logging disabled.

The logger observes the existing two Metal presentation calls without changing
their arguments or adding a GPU wait. Join rows by `native_pid, sequence`.
`layer_ptr, drawable_id` identify a drawable within its layer; pointer values
are diagnostic identities and may be reused after an object is destroyed.

| Event | Meaning |
| --- | --- |
| `request` | CPU reached the native presentation call; `minimum_duration_s` is its existing requested duration, or zero for plain `presentDrawable`. |
| `presented` | Metal called the drawable's presented handler. A valid `presented_s` is Metal's actual presentation timestamp, not the callback execution time. |
| `gpu_complete` | Metal completed the command buffer containing this presentation. Valid GPU start/end times describe this command buffer only, not every command buffer in the game frame. |
| `retired` | The last owner of the diagnostic trace released it, including any registered callback blocks. `callbacks_seen` is a bitmask: presented=1, completed=2. Missing bits disclose callbacks that never ran. |
| `registration_failed` | An exception prevented all callback registration from completing. Rendering continues through the original presentation call. |
| `summary` | Explicit/graceful logger shutdown attempted the final drain; outstanding callbacks and diagnostic drops remain visible. |

`event_host_s` is when the event was recorded; `request_host_s` is copied from
the request. `unix_ms` provides coarse alignment with other process logs.
Calculate visible cadence from successive **valid `presented_s` values for the
same layer**, sorted by presentation time. Callback arrival order can differ
from display order. Do not count an event's callback time as screen output.
Apple defines zero `presentedTime` as not presented or skipped; the logger
therefore marks it `zero_or_unavailable`. A missing presented callback or a
dropped record is also not proof that a frame was visibly skipped.

The logger limits outstanding traces to 512, its event ring to 4,096 records,
and each of three rotating CSV segments to approximately 16 MiB. Callbacks use a
nonblocking ring insertion; contention/overflow drops diagnostics and never
waits for disk. A utility queue flushes every 250 ms. Drop and active-trace
columns are counters sampled when rows are written, not at the event timestamp.
Explicit shutdown waits at most 500 ms for the writer, never for the GPU.
An abrupt process exit, a host exit path that bypasses `atexit`, or a blocked
writer can leave a partial tail or no summary. The code image is explicitly
pinned with `RTLD_NODELETE` before callback registration; callback-owned trace
objects retain the logger until released and do not retain Metal objects.

The standalone harness builds the **actual helper source** with AddressSanitizer
and UndefinedBehaviorSanitizer. Fake Metal objects exercise callback order,
zero timings, errors, missing callbacks, trace/ring limits, concurrent callbacks,
blocked file I/O, late callbacks after `dlclose`, and both shutdown/initialization
orderings. It checks callback/object/logger destruction without creating a
window, using a GPU, launching Wine, or building the full runtime.

```sh
python3 tests/display_log/run.py
python3 tests/display_log/run.py --arch x86_64
```

These tests establish the helper's lifetime and logging behavior. Actual Metal
presentation timestamps and runtime integration still require a native/Wine
render probe; they are not a game performance benchmark.

## Long-session recording

The display CSV remains schema 1. The writer now rotates `display-<native PID>.csv` to `.1.csv` and `.2.csv` at approximately 16 MiB per segment instead of turning recording off after 64 MiB. Sequence IDs continue across rotations. The threshold can be exceeded by one complete row, never by an unbounded tail.

`display-<PID>.summary.json` is an atomically replaced, small lifetime record. It counts received requests/presentations, unavailable callbacks, retired traces without presentation callbacks, registration failures, logger/registry admission drops, disk errors, rotation counts, and valid adjacent presentation intervals. The interval accumulator reorders a fixed 4,096-presentation window: only consecutive sequence IDs with positive presentation times and the same Metal layer form a pair. Invalid, absent or out-of-window callbacks do not invent an interval.

`display-<PID>.hitches.csv` independently retains compact intervals longer than 25 ms with three approximately 2 MiB segments. Its UTC time maps to actual presentation time from the paired host/callback clock; callback invocation time is not itself screen presentation. Lifetime counters include rotated-out data, but do not imply that missing data was smooth. Detailed files may no longer contain the beginning of a long session.

`python3 tests/display_log/run.py --arch x86_64 --mode rotation` uses small compile-time limits to force 21 display rotations and a hitch rotation while checking continued recording, complete CSV rows, disk bounds and lifetime counts across 2,000 fake presentations. Release limits remain 16 MiB / 2 MiB. The existing full suite still checks callback ordering, missing/pending callbacks, ring overflow, bounded shutdown and callback code lifetime after the caller releases its dynamic-library reference.

Use `python3 scripts/summarize_display.py <current display-PID.csv> --include-rotated` to join matching `.2.csv`, `.1.csv` and current-file records by process/layer/sequence before computing coverage. Requests and callbacks split across rotation boundaries are joined, while missing sequence IDs remain gaps. The report names every input and the retained origin. Lifetime summary/hitch files and other processes are not mixed into the detailed CSV analysis. Without the flag, only the supplied file is read.
