# Recall logs

Saved with Recall's **Save Logs**, for a bug report. `Summary.txt` tells what happened, in the
player's language, newest day first. This folder holds the logs themselves.

## Where to start

Read `index.json` first. It has:

- `recall`, `logging`: the versions, the Mac, and the logging setting (`custom` is the player's
  own WINEDEBUG text).
- `sessions`: one per Battle.net start, newest first, with its files and, for sessions Recall 1.5
  or later started, its record (`recall/sessions/<start>/session.json`).
- `moments`: what happened when, oldest first, each with the `file` and `line` to read (lines
  count as grep and sed count them). Battle.net opening, updating (`cancelled` when Battle.net
  stopped it), holding Play (`battlenet_launch_wait`) or marking something not playable; Overwatch
  starting and closing (from Recall's record, or `overwatch_log_*` from Overwatch's own log, which
  covers its latest run only); and crashes, with the crash report's `top_frames`, `running_time`
  and `last_log_line`.
- `errors`: the error lines each log repeats most, with a count and the first line.
- `left_out`: older sessions left out to fit GitHub's 25 MB limit, and crash dumps, which are
  never included.

## The files

- `recall/sessions/<start>/battlenet.log`: everything Battle.net, Overwatch and Wine printed in
  that session. With logging on, Wine's lines begin `<seconds>.<ms>:<process>:<thread>:<class>:<channel>:<function>`.
  Its seconds count from when the Mac started; `session.json` gives `wine_clock_ms` (Wine's count)
  at `started` (the time of day), so time of day = `started` + (seconds × 1000 − `wine_clock_ms`) ms.
- `recall/sessions/<start>/session.json`: what the session started with (`logging`, `winedebug`,
  `dxmt_log_level`, MetalFX, Game Mode), when Overwatch ran (`games`) and when it `ended`.
- `recall/*.log`: Recall's other steps (graphics preparation, the session monitor, setup).
- `battlenet/client`, `battlenet/agent`: Battle.net's own logs, one set per start, in UTC.
  `battlenet/agent/Agent.<version>/Operations-*.log` shows each update and what it waited for.
- `overwatch/Overwatch.log` and `overwatch/errors/*_ErrorLog.txt`: Overwatch's log and its crash
  reports.
- `support-report.json`: the Support Report from Recall's Help.

## Changed before saving

- Personal details are replaced with a word in brackets: `[user]`, `[name]`, `[computer]`,
  `[account-id]`, `[removed]` (sign-in codes), `[windows-user-id]`, `[ip-address]`,
  `[hardware-address]`, `[email]`, `[battletag]`. `index.json` counts each under `removed`.
- In Recall's session logs, three or more identical lines in a row (Wine's prefix aside) are kept
  once, followed by `[recall:repeated count=N last="<prefix of the last one>"]`.
