# CPU frame cadence and sparse wait tracing

`DXMT_FRAME_LOG` enables one shared utility writer per active queue/presenter lifetime. The existing `frames-<Windows PID>.csv` filename retains the original four columns and adds schema 3 UTC/monotonic timestamps, queue identity, exact local frame-latency wait, event identity and cumulative dropped-event count. If all queues are destroyed and subsequently recreated in the same process, a `-runN` suffix prevents overwriting the earlier capture.

A 4,096-record fixed ring admits producers using a single nonblocking atomic try-lock. Producer paths perform no formatting, file I/O, dynamic allocation or waiting on the logger. A background worker opens, writes, flushes and rotates files. Each frame/event stream uses three approximately 2 MiB segments (the final row can exceed the threshold by one row): `.2.csv` is oldest, `.1.csv` next, `.csv` current. A small atomically replaced `.summary.json` keeps lifetime counts even after detailed rows rotate away. Drops and disk errors remain explicit; missing rows must not be called smooth time. On shutdown the caller allows at most 500 ms for draining; an outstanding writer keeps its shared state and pinned Windows module alive. Abrupt process exit may still lose the queued tail.

`frames-<PID>.events.csv` records sparse spans lasting at least 2 ms:

- `coherence_wait`: caller waiting on the existing CPU coherence fence.
- `chunk_capacity_wait`: caller waiting for space in the fixed command-chunk pool.
- `encode`: CPU command encoding, including any nested pipeline waits.
- `submit`: the existing Metal command-buffer commit call.
- `completion_wait`: finish thread waiting for that command buffer.
- `next_drawable`: presenter waiting in the existing drawable acquisition call.
- `layer_sync_wait`: presenter waiting before a layer/pipeline update.
- `initializer_flush`: resource-initializer flush call.
- `command_buffer_acquire`: native command-buffer acquisition call.

A span's timestamps mark its end; subtract `duration_us` to obtain its beginning. `frame_id=0` means no safely available frame association. Queue and presenter owner IDs are independent. Nested spans overlap: never sum them as exclusive CPU or GPU frame time. UTC correlates with the native Metal log and external system sampler; each clock's monotonic origin is platform-specific, so correlate cross-domain monotonic clocks using their paired UTC stamps.

`python3 tests/presentation/run.py` compiles the actual helper and queue logger/destructor bodies using ASan/UBSan, with only the platform thread wrapper replaced by a standard-library adapter. Tests cover disabled/failed-open behavior, asynchronous short-tail flushing, compile-counter baselines, local wait duration, UTC/monotonic stamps, many rotations, lifetime counters, and concurrent overload with explicit loss accounting. Small test segment limits do not change release defaults.

Use `python3 scripts/summarize_frames.py <current frames-PID.csv> --include-rotated` to read precisely the matching `.2.csv`, `.1.csv` and current file, oldest first. Schema 3 timestamps preserve missing time between retained rows; missing timestamps are excluded rather than replaced by summed frame durations. Duplicate rows from overlapping captures are disclosed. The report lists its input files and oldest retained origin; it does not represent the entire lifetime. Default single-file input remains supported.
