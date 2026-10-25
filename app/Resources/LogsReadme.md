# Recall logs

Saved with Recall's **Save Logs**, for a bug report. `Summary.txt` tells what happened, in the
player's language, newest day first. This folder holds the logs themselves.

## Where to start

Read `index.json` first. It has:

- `recall`, `logging`: the versions, the Mac, and the logging setting. `setting` is `off`, or the
  presets that were on joined with commas (`crashes`, `graphics`, `battlenet`, `mouse`, `custom`);
  `custom` is the player's own WINEDEBUG text.
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
  `dxmt_log_level`, MetalFX, Game Mode, the mouse's `mouse_input` and `mouse_rate`), when Overwatch
  ran (`games`) and when it `ended`.
- `recall/sessions/<start>/input-<pid>.jsonl` (logging's Mouse preset): the mouse report, one JSON
  line a second for each Wine process that was frontmost or had input. `unix_ms` is the time, `exe`
  the program, `app_active` whether it was frontmost and `mode` whether mouselook was on.
  - `raw_dx`, `raw_dy`: how far the mouse moved that second, in the mouse's own counts, as the
    game's source delivered it; `raw_moves` is how many reports carried it. `raw_source` names
    that source: `gcmouse` (Apple's mouse input for games) or `hid` (the mouse's own reports,
    Settings › General › Mouse › High-precision, with `hid_access` macOS's Input Monitoring answer,
    `hid_open` the result of opening the mice, `hid_mice` how many are open and `hid_reports` and
    `hid_buttons` what they sent). While `hid` delivers, `hid_shadow_moves`, `hid_shadow_dx` and
    `hid_shadow_dy` are what GCMouse gave at the same time, not delivered: the difference is what
    GCMouse would have lost. When macOS has given Overwatch no mouse input for 50 ms, HID's movement
    is held: `hid_released` counts reports held and delivered once macOS's input came back within
    half a second (it was only late), `hid_withheld` the reports held longer and the presses held
    back (another app most likely had the mouse).
  - `variant` is how clicks and timing work: `precise` for Standard and High-precision, `classic`
    for Classic (Recall 1.4's).
  - `raw_interval_us`: the least time between deliveries to Overwatch, in microseconds, from
    Settings › General › Mouse › Advanced. 0 is every report (the default from Recall 1.6.1);
    1000 is 1,000 a second, as in 1.6.0 and always with Classic. Movement in between is added to
    the next delivery.
  - `mac_dx`, `mac_dy`: how far the macOS pointer moved in points, which follows the pointer's speed
    and acceleration settings.
  - `moved_x`, `moved_y`, `moved_abs`: what reached Overwatch through Wine.
  - Clicks (`clicks`, `raw_buttons`, `appkit_buttons`), app switches (`activations`, `resigns`) and
    mouselook (`mouselook_enters`, `mouselook_exits`). `raw_buttons` are the button changes the
    game's source posted and `appkit_copies` macOS's copies of them, dropped; `appkit_buttons`
    are macOS's changes posted because the source had none. While `hid` delivers,
    `appkit_unmatched` counts those, and `appkit_unmatched_nearest_ms` is how far the nearest
    source change of the same kind was from the latest one (source minus macOS, `null` if none).
    `appkit_copies_late_stamp` counts copies macOS stamped more than 2 ms after the mouse's own.
  - Switching away from the game in fullscreen: the window stays fullscreen while the player is
    away. `canvas_exits_held` counts the game's requests to leave fullscreen held then and
    `minimize_held` its minimizes held with them; on return, `canvas_exits_resumed` counts the game
    asking for fullscreen again (nothing to animate) and `canvas_exits_applied` held exits applied
    3 s after the return because it had not. Where the window did leave fullscreen,
    `minimize_waits` counts the game's minimizes that waited for macOS's leave-fullscreen animation,
    `minimize_after_exit` those applied when it ended and `minimize_timeouts` those applied after
    3 s without its end. `minimize_returns` counts minimizes the player came back before, held or
    waiting, which restored the game instead, and `minimize_recovered` windows that Wine had
    minimized but were still on screen when the player came back to them, which restored them.
  - With pointer acceleration off, (`raw_dx`+`raw_dy`) / (`mac_dx`+`mac_dy`) stays the same when
    nothing is lost. A second whose ratio falls below the player's usual one means GCMouse delivered
    less than the hand moved.
  - The key-press counts the report also keeps (`key_*`: how many, never which) are removed before
    saving.
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
