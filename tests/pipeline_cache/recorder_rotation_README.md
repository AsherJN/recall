# Recorder diagnostic rotation proof

`run_recorder_rotation.py` reuses an existing recorder reliability proof's native
x86_64 probe and fixture. It first requires every production codec/cache source
hash to match the saved proof, then runs the production `burst` mode in a new
isolated cache with `DXMT_PIPELINE_CACHE_LOG_SEGMENT_BYTES=4096`. No native source
is rewritten and no compiler, Wine process, or game is launched.

```sh
python3 tests/pipeline_cache/run_recorder_rotation.py \
  --proof logs/dxmt/recorder-reliability-20260911-211114
```

The 2026-09-11 result is saved in
`logs/dxmt/recorder-rotation-20260911-212018-522556/report.json`. The reused binary
was x86_64 with AddressSanitizer and UndefinedBehaviorSanitizer. Source hashes
remained unchanged. Assertions verified 63 rotations, three bounded newline
complete JSONL parts, chronological retained records, a continuing final summary,
2,304 durable recipes, zero pending records, and zero diagnostic I/O errors.
The deliberately stalled burst disclosed 4,488 optional diagnostic admission
drops; this is an intentional overflow test, not a claim of lossless detail.
The independent summary continues to account for durable recording after detail
rotation. The report includes binary and source hashes and the exact final
summary. Ordinary game logging retains the normal 8 MiB part limit.
