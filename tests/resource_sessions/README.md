# Long-session resource capture

The measured source-build launcher starts one detached collector for the exact
Wine bottle. It identifies the Wine server by executable, PID, UTC process start
token, and Wine's prefix device/inode directory. Monitoring continues across
Overwatch exits and subsequent Play clicks, until that server exits or six hours
elapse. A replacement server needs a fresh measured launch. The launcher confirms
collector startup through `session-status.json`; an unconfirmed startup is shown
as a warning rather than reported as ready.

Resource samples retain the existing system counters and game CPU/RSS fields.
Schema 2 adds UTC plus `monotonic_ns`, game start identity, exact Wine-session
identity, sampling duration, and process-scan completeness. `game_started` and
`game_exited` records describe observed process transitions, not match boundaries.
An incomplete process scan cannot declare a game exited. Process inspection reads
executable paths and start times; command arguments, environment variables, and
account data are never recorded. GPU and swap counters remain system-wide.

`resources.jsonl` is the newest part; `.1.jsonl`, `.2.jsonl`, and `.3.jsonl` are
progressively older. Each part is at most 4 MiB, for at most 16 MiB total. Rotation
discards the oldest part. Records are newline complete and flushed individually,
but this is not an `fsync` guarantee against power loss. An atomic status snapshot
updates about every 30 seconds and at normal completion, with lifetime sample,
record, and rotation counts. A killed collector can leave a stale status snapshot;
its PID/start identity must still be checked. No file grows for more than six
hours, apart from a bounded in-flight sample/query at the cutoff. Queries have
three-second timeouts and at most eight candidate game processes are inspected.

A nonblocking per-prefix file lease prevents simultaneous session samplers. A
new collector allows five seconds for the previous server's collector to release
the lease, then exits without creating another resource stream if it is still
owned. Legacy direct `--seconds` (1–900) and `--wait-for-game` (0–600) commands
retain their prior first-game duration/exit behavior, and also use bounded output.

The normal measured launch command is unchanged:

```sh
python3 scripts/launch_cx26.py --backend dxmt --source-build --profile smooth60 --measure --restart-client
```

Before Battle.net starts, cache-enabled source launches call the independently
implemented offline preparation helper. Its returned status is saved in the
launch manifest. A publication state that cannot be verified aborts launch;
ordinary preparation failure is recorded and leaves the original cache available.
`--no-pipeline-cache` disables reuse/learning/preparation, and
`--no-pipeline-prewarm` disables offline and in-game startup preparation while
retaining reuse/learning. Normal startup retains the 128-pipeline/10-second budget
and prioritizes expensive recipes.

For unambiguous gameplay boundaries, invoke a marker when that phase begins:

```sh
python3 scripts/mark_measurement.py quickplay_entered
python3 scripts/mark_measurement.py match_ended
```

Other choices are `practice_entered`, `workshop_entered`, `menu_entered`, and
`game_closed`. Automatic selection validates the active collector and Wine server;
`--session logs/dxmt/measured-...` can explicitly select a completed run. Marker
timestamps are the time of invocation, not retroactive estimates. Included game
IDs are explicitly labelled `last_observed_games`, with their resource snapshot
time. Markers use a separately locked 256 KiB file and never control the game.
`mark_measurement.discover_artifacts()` includes numbered native/resource stream
parts plus summary, hitch, and event files without loading their contents.

## Validation

```sh
python3 -m unittest discover -s tests -p 'test_resource_sessions.py' -v
python3 -m unittest discover -s tests -p 'test_launch_profiles.py' -v
python3 -m unittest discover -s tests -p 'test_measurement_markers.py' -v
```

40 tests passed on 2026-09-11: follow/rearm and server exit; reused PIDs; partial
scans; transient query/sample errors; legacy modes; real file rotation and leases;
CLI completion/status/release; engine/prefix attribution; bounded candidate scans;
launcher startup confirmation, failed-child status rejection, and bounded
transient discovery retries; preparation ordering and failure contract; marker
identity validation and native rotated-file discovery. Test clocks and process
queries are mocked, while the production state machine, CLI, file writers, and
POSIX lease code execute directly. A separate real read-only system sample took
about 65 ms and produced the expected schema; no game was active. Live game
restart attribution and a multi-hour capture remain to be verified in the next
user-run session. Admission additionally retries missing/temporarily unavailable
prefix queries for five seconds; a different process start token or executable
is rejected immediately. Safe per-check booleans and reasons are logged.
No game, Wine process, cache, or native build was changed by these tests.

The first live collector attempt exited before creating samples; the generic
error from that version cannot identify which admission check failed. Its log
and metadata were preserved. After adding per-check diagnostics and the bounded
admission retry, the collector was rearmed in the same measured folder without
restarting Battle.net. `measured-20260911-213142-747601/collector-live-validation.json`
records 46 samples, a status heartbeat more than 90 seconds after the first
sample, stable server/collector identities through 34 seconds of independent
observation, the exclusive bottle lease, and successful read-only phase-marker
selection. No game was launched. Native log prefixes were preserved; the active
pointer identifies the uniquely named replacement resource stream.
