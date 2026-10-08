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

- **The game stops responding.** In the app, choose Settings › Advanced › Force Quit
  (or right-click the app in the Dock), then open Overwatch again.
- **Overwatch won't start, or setup reports damaged files.** Choose Settings › Advanced ›
  Repair Game Files with Overwatch and Battle.net closed. It reinstalls the files
  the app adds and refreshes the Windows environment; Overwatch, its settings
  and your Battle.net sign-in are kept.
- <a id="id-external-monitor"></a>**Playing on an external monitor.** Overwatch opens on your main display, the
  one with the menu bar. In System Settings › Displays, select the monitor and
  set Use as to Main display (Displays… in the app's Settings › Display opens that page).
  Then, in Overwatch under Options › Video, choose the monitor's own resolution
  for the sharpest picture, for example 2560 × 1440 on a 1440p monitor or
  5120 × 2160 on a 5K2K ultrawide. Recall remembers it for that monitor, and
  your MacBook screen keeps its own. You can also set it in the app under
  Settings › Display, which names your main display and says how
  each size will look on it.
- **Matches stutter.** Play Workshop code 929PJ from Custom Games and let it
  run for 5 to 10 minutes; your Mac gets Overwatch's graphics ready ahead of
  time. See [Your first matches](INSTALLATION.md#your-first-matches).
- **The game is black or the wrong size.** Quit Overwatch, choose Settings › Display ›
  Reset Display Settings, then play again. Overwatch opens at 1080p; your
  graphics and FPS settings stay as they are.
- <a id="id-metalfx-upscaling"></a>**Getting more FPS with MetalFX upscaling.** Close Battle.net, turn on
  Settings › Graphics › MetalFX upscaling, then play from the app. In Overwatch's Video
  settings, choose NVIDIA DLSS and a mode: Performance and Ultra Performance
  give the most FPS, Quality looks closest to full resolution. The game draws
  fewer pixels and Apple's MetalFX rebuilds the full-size picture; Settings › Graphics ›
  Sharpening makes it crisper. While it's on, Overwatch lists your graphics card
  as an NVIDIA GeForce RTX 4090 (that's how it offers DLSS; your Mac does the
  work), and the NVIDIA Reflex option has no effect.
- **My team can't hear me.** Open Settings › Audio in the app. If the microphone
  is off, choose Turn On…, switch on Recall in System Settings, then open Recall
  again. Then check the voice chat settings in Overwatch's Sound options.
- **I don't want Battle.net to open with Recall.** Choose Cancel while it opens,
  or turn off Settings › General › Open Battle.net when Recall opens; then start it with
  Open Battle.net.
- **Battle.net looks small or cut off.** Battle.net opens at its Windows size.
  To make it larger, turn on Settings › General › Mac-sized Battle.net window,
  then close Battle.net and open it again from the app. If part of a window is
  cut off, turn it off again.
- **"No compatible graphics hardware was found."** This can follow connecting
  or unplugging a display while Battle.net was open. Open Battle.net from the
  app rather than from the Dock: the app reopens it for your current displays.
- **Recall asks to install Rosetta after a macOS upgrade.** An upgrade to
  macOS 27 can remove Rosetta, which Battle.net and Overwatch need. Choose
  Install Rosetta, follow Apple's steps, then choose Check Again.
- **Battle.net can't connect on a work or school network.** Some of these
  networks set up their proxy automatically. Close Battle.net, turn on
  Settings › Advanced › Detect network proxy automatically, then open
  Battle.net again from the app.
- <a id="id-korean-accounts"></a>**Overwatch closes as it starts on a Korean account (linked to Nexon).**
  Close Battle.net, turn on Settings › Advanced › Korean account support
  (한국 계정 지원), then play from the app. It's experimental: it doesn't turn off
  Nexon's anti-cheat, but Nexon doesn't support playing on a Mac, so using it
  could affect your account.

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
web request it reaches GitHub from your IP address. Turn it off in Settings › General,
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
