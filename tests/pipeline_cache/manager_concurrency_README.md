# Production manager concurrency and lifecycle proof

Run `python3 tests/pipeline_cache/run_manager_concurrency.py` from the workspace
root. It compiles the current production codec and cache manager into an x86_64
native dylib with AddressSanitizer and UndefinedBehaviorSanitizer, then executes
through Rosetta with actual Metal libraries and GPU readback. It does not use
Wine or touch the game prefix.

The harness alternates two fragment shaders with different expected pixels. Four
threads make 400 concurrent calls and release every returned PSO according to the
production API's +1 ownership contract. Two threads repeatedly call shutdown;
the main thread also shuts down before spawning another 400 calls, establishing
that these requests are definitely after admission stopped. Both later ordinary
creation and retained earlier PSOs must still render correct pixels.

Two startup processes build separate immutable archive batches. A live owner
then holds the cache writer lease while a second process loads both batches and
prewarms two recipes with strict archive hits. The reader must report no writer
lease, perform no archive population, and leave every cache file's contents
unchanged. This exercises ownership of an array containing multiple archives.

The final stable-source run passed all cases:
[2026-09-11 15:41:10 report](../../logs/dxmt/pipeline-concurrency-proof-20260911-154110/report.json).
The report contains compiler commands and production source hashes; sources were
unchanged during the run. Cache lock contention may fall back to ordinary Metal
creation, so pointer identity is informative rather than a required 100% hit rate.
Different PSO identities can also reflect replacement of an earlier cached state.

Leak detection is disabled for this bounded process-lifetime test; address and
undefined-behavior checks remain enabled. This test establishes neither leak
freedom nor gameplay performance, and it does not exercise the Wine bridge.
