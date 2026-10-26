# Support and privacy

## Get help from other players

Join the [Recall Discord](https://discord.gg/pexasKezCn) to ask questions in #help,
compare Macs and settings, and find people to play with. Bugs still belong in a
GitHub issue, so they can be tracked and fixed.

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

<a id="id-save-logs"></a>If something went wrong in Battle.net or Overwatch, attach your logs too:
choose Save Logs… in Settings › Advanced (or Help › Support) and add the file to the
issue. It holds your recent sessions' logs from Recall, Battle.net and Overwatch, with
personal details removed (see [Privacy](#privacy)), and a short summary of what happened.
For more detail, turn on Settings › Advanced › Logging before you play again and choose
the kind of problem: Crashes and freezes, Graphics or Battle.net. Custom takes Wine's own
`WINEDEBUG` settings, as you'd type them in Terminal. Logging can lower your FPS, so the
app shows a reminder on its home screen while it's on; turn it off when you're done.

## If something goes wrong

- **The game stops responding.** In the app, choose Settings › Advanced › Force Quit
  (or right-click the app in the Dock), then open Overwatch again.
- **Overwatch won't start, or setup reports damaged files.** Choose Settings › Advanced ›
  Repair Game Files with Overwatch and Battle.net closed. It reinstalls the files
  the app adds and refreshes the Windows environment; Overwatch, its settings
  and your Battle.net sign-in are kept.
- **Overwatch crashes or shows graphics glitches.** Quit Overwatch and close
  Battle.net, then choose Settings › Graphics › Clear Shader Cache. Your next few
  matches stutter again while your Mac relearns your shaders; your game files
  and settings stay as they are.
- <a id="id-external-monitor"></a>**Playing on an external monitor.** Overwatch opens on your main display, the
  one with the menu bar. In System Settings › Displays, select the monitor and
  set Use as to Main display (Displays… in the app's Settings › Display opens that page).
  Then, in Overwatch under Options › Video, choose the monitor's own resolution
  for the sharpest picture, for example 2560 × 1440 on a 1440p monitor or
  5120 × 2160 on a 5K2K ultrawide. Recall remembers it for that monitor, and
  your MacBook screen keeps its own. You can also set it in the app under
  Settings › Display, which names your main display and says how
  each size will look on it.
- **Matches stutter.** Your first 5 to 10 matches stutter while your Mac learns
  Overwatch. To speed it up, play Workshop code 929PJ or join a 500% custom game;
  see [Your first matches](INSTALLATION.md#your-first-matches). Still stuttering
  after 15,000 shaders? Report it with the support report from Help › Support.
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
  work), and the NVIDIA Reflex option has no effect. See
  [how MetalFX upscaling works](METALFX.md).
- <a id="id-high-precision"></a>**Allowing Input Monitoring for your mouse.** Recall reads your mouse
  directly, which needs macOS's Input Monitoring permission. Choose Turn On… on the Play
  screen's card (or Settings › General › Mouse › High-precision), then Turn On. When macOS
  asks, choose Open System Settings and switch on Recall, then choose Quit & Reopen if macOS
  offers it.
- **My team can't hear me.** Open Settings › Audio in the app. If the microphone
  is off, choose Turn On…, switch on Recall in System Settings, then open Recall
  again. Then check the voice chat settings in Overwatch's Sound options.
- **I don't want Battle.net to open with Recall.** Choose Cancel while it opens,
  or turn off Settings › General › Open Battle.net when Recall opens; then start it with
  Open Battle.net.
- <a id="id-battlenet-update"></a>**Battle.net shows Update, Queued or Initializing for a long time.**
  Battle.net updates itself before it updates or starts Overwatch, so Overwatch
  waits its turn. Leave Battle.net open until it's done: quitting starts
  Battle.net's own update over, and clicking Update, Pause or Settings sends
  Overwatch back to the end of the line. In some regions Battle.net's update
  takes much longer, depending on Blizzard's download servers. If it's still
  waiting after half an hour, report it with your support report
  (Help › Report a Problem), which shows how long each update took.
- <a id="id-battlenet-play"></a>**Battle.net shows Play instead of Install, Play does nothing, or Overwatch is missing.**
  In Battle.net, choose Home, then + beside Favorites, and add Overwatch. Select
  it there, then choose Install or Play. If it's still missing, close Battle.net
  and open it again from the app, then report it with your support report
  (Help › Report a Problem). Uninstalling Recall won't fix it: it removes
  Overwatch too, so the whole game downloads again.
- **Battle.net looks too big or too small.** This can follow connecting,
  unplugging or rearranging displays while Battle.net was open. Close
  Battle.net, then open it again from the app.
- **"No compatible graphics hardware was found."** This can follow connecting
  or unplugging a display while Battle.net was open. Open Battle.net from the
  app rather than from the Dock: the app reopens it for your current displays.
- **Recall asks to install Rosetta after a macOS upgrade.** An upgrade to
  macOS 27 can remove Rosetta, which Battle.net and Overwatch need. Choose
  Install Rosetta, follow Apple's steps, then choose Check Again.
- <a id="id-folder-access"></a>**Recall says it can't use its folder.** macOS isn't letting Recall
  create or change its `Overwatch2Mac` folder, which is inside Application Support
  in your Library unless you chose another location. Reinstalling Recall doesn't
  change that. Choose Show in Finder, then File › Get Info on the folder Finder
  selects. Under Sharing & Permissions, click the lock, set your account to
  Read & Write (add it with + if it isn't listed), then choose Try Again in
  Recall. If the `Overwatch2Mac` folder itself belongs to another account, Finder
  can't change that; run
  `sudo chown -R "$(whoami)" ~/Library/"Application Support"/Overwatch2Mac`
  in Terminal, then choose Try Again.
- **Battle.net can't connect on a work or school network.** Some of these
  networks set up their proxy automatically. Close Battle.net, turn on
  Settings › Advanced › Detect network proxy automatically, then open
  Battle.net again from the app.
- <a id="id-korean-accounts"></a>**Overwatch closes as it starts on a Korean account (linked to Nexon).**
  Close Battle.net, choose Korea in Settings › General › Battle.net region, then
  play from the app. Recall adds the certificates the game checks when it starts and
  hands Nexon's anti-cheat a blank image when it takes a screenshot. It doesn't
  turn off Nexon's anti-cheat, but Nexon doesn't support playing on a Mac, so
  playing this way could affect your account.

## Known issues

- Stutter in the first 5 to 10 matches while your Mac learns Overwatch's
  shaders. Workshop code 929PJ and 500% custom games speed it up (see above).
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

If you installed Recall with Homebrew, run `brew uninstall --zap --cask recall`
instead. It closes Battle.net and Overwatch and moves the same things to the
Trash, including a game installed on an external drive.

## Privacy

The app keeps a small local record of setup progress and errors. It can export
a short diagnostic summary for a bug report; the export is optional, sanitized,
and shown to you before you share it. It includes what Battle.net did on its
last three starts: how long each update waited and took, Battle.net's own error
codes and the names of its download servers, nothing about your account.
Save Logs puts the logs Recall, Battle.net and Overwatch keep into one file, saved
where you choose. Before saving, it removes your Mac's user and computer names,
people's names (such as in a device's name), Battle.net account numbers and
sign-in codes, Windows user IDs, IPv6 addresses, hardware addresses, email
addresses and BattleTags, and it never includes Overwatch's crash dumps. Logging
(Settings › Advanced) is off unless you turn it on.
To read your mouse directly, Recall uses macOS's Input Monitoring permission, which
only you can allow, in System Settings. macOS describes it as receiving keystrokes
because one permission covers both mice and keyboards; Recall opens only mice and
reads only their movement and buttons, never your keyboard.
Nothing is uploaded automatically, there is no project login, and the app does
not inventory other apps. Battle.net and Apple handle their own sign-in and
privacy.

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
