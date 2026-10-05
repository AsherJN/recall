# Support and privacy

## Reporting a problem

[Open an issue](https://github.com/AsherJN/recall/issues), or choose Help › Report a Problem
in the app. Include:

- App version and build (Recall › About Recall, or the line above the
  buttons at the bottom of the app window)
- Mac chip and memory
- macOS version
- Game resolution
- What you did, and whether it happened on a fresh launch or after Cmd-Tab

Remove account names and personal file paths before posting.

## If something goes wrong

- **The game stops responding.** In the app, choose Settings › Force Quit (or
  right-click the app in the Dock), then open Overwatch again.
- **Overwatch won't start, or setup reports damaged files.** Choose Settings ›
  Repair Game Files with Overwatch and Battle.net closed. It reinstalls the files
  the app adds and refreshes the Windows environment; Overwatch, its settings
  and your Battle.net sign-in are kept.
- <a id="id-external-monitor"></a>**Playing on an external monitor.** Overwatch opens on your main display, the
  one with the menu bar. In System Settings › Displays, select the monitor and
  set Use as to Main display (Settings › Displays… in the app opens that page).
  Then, in Overwatch under Options › Video, choose the monitor's own resolution
  for the sharpest picture, for example 2560 × 1440 on a 1440p monitor or
  5120 × 2160 on a 5K2K ultrawide. Recall remembers it for that monitor, and
  your MacBook screen keeps its own. You can also set it in the app under
  Settings › Fullscreen resolution, which names your main display and says how
  each size will look on it.
- **Matches stutter.** Play Workshop code 929PJ from Custom Games and let it
  run for 5 to 10 minutes; your Mac gets Overwatch's graphics ready ahead of
  time. See [Your first matches](INSTALLATION.md#your-first-matches).
- **The game is black or the wrong size.** Quit Overwatch, choose Settings ›
  Reset Display Settings, then play again. Overwatch opens at 1080p; your
  graphics and FPS settings stay as they are.
- **I don't want Battle.net to open with Recall.** Choose Cancel while it opens,
  or turn off Settings › Open Battle.net when Recall opens; then start it with
  Open Battle.net.
- **Battle.net looks too big or cut off.** Turn off Settings › Mac-sized
  Battle.net window, then close Battle.net and open it again from the app.
- **"No compatible graphics hardware was found."** This can follow connecting
  or unplugging a display while Battle.net was open. Open Battle.net from the
  app rather than from the Dock: the app reopens it for your current displays.

## Known issues

- Extra stutter in the first few matches while the game compiles shaders.
  Workshop code 929PJ gets ahead of it (see above).
- If a problem starts after a Blizzard or macOS update, check for a Recall
  update with Recall › Check for Updates….
- Changing the graphics quality preset makes Overwatch reset Render Scale to
  Automatic and turn on Dynamic Render Scale, and can set Frame Rate to
  Automatic. The picture softens and FPS drops. In Overwatch's Video settings
  set Render Scale to 100%, Dynamic Render Scale to Off and Frame Rate to
  Custom, then restart Overwatch.
- Unplugging an external install drive while Battle.net or Overwatch is open
  will crash them. Reconnect it and open the app again.

## Updating

The app checks GitHub for a newer version when it opens and offers to install
it. See [Installation](INSTALLATION.md#updating).

## Uninstalling

Choose Settings › Uninstall Recall…, or Uninstall Recall… in the Recall menu,
and confirm. Quit Overwatch first; the app closes Battle.net for you. It
moves its own data folder, which holds the game and the Battle.net client it
set up, to the Trash, then moves itself to the Trash and quits. Nothing is
deleted outright. Put Back in Finder restores everything, and the storage is
freed when you empty the Trash. Your Blizzard account and any other Blizzard
software are not touched.

## Privacy

The app keeps a small local record of setup progress and errors. It can export
a short diagnostic summary for a bug report; the export is optional, sanitized,
and shown to you before you share it. Nothing is uploaded automatically, there
is no project login, and the app does not inventory other apps. Battle.net and
Apple handle their own sign-in and privacy.

To find updates, the app asks GitHub's public release API for the latest
version when it opens, and at most every 12 hours while it stays open. The
request carries no account, identifier or information about your Mac; like any
web request it reaches GitHub from your IP address. Turn it off in Settings,
and check by hand from the Recall menu.

The Mosaic News links in the app open in your browser with a tag naming the
screen they came from (for example `utm_content=home`), so the author can see
which placement works. Nothing else is added, and the app itself records
nothing about the click.

## What not to share

Do not upload complete Wine prefixes, Battle.net account files, access tokens,
private keys, screenshots showing personal details, or raw system-wide logs.
If you find a credential in the repository or in a log, report it privately to
the maintainer instead of posting it in a public issue.
