# Native app sources

The app is named Recall. `Brand.swift` holds its public identity in one place:
name, tagline, repository links, the update feed, the release disk image name,
the trademark line and the author's links (Mosaic News links say which screen
opened them). The bundle identifier and data folder keep their original
values so installations and updates carry over.

`Main.swift` owns the AppKit application lifecycle, one window, menus and the
cross-process app lock, plus the Help menu and the Dock menu (Force Quit).
`SetupView.swift` composes the SwiftUI setup/status views, the support card,
the version and update line, the first-match tip and the footer's Settings,
Help & FAQ and About buttons, while `UtilitySheets.swift` owns Settings, About
(with Licenses: the bundled NOTICE and Apache 2.0 text, and the third-party
license files in Finder), Uninstall, the update sheet and What's New (content in `WhatsNew.swift`,
bundled). Settings is in tabs (`SettingsTab`), and reopens on the last one shown:
General (updates, opening Battle.net with the app, the mouse; Battle.net's size follows the main
display by itself, so there is no switch for it), Display (fullscreen
resolution, Reset Display Settings), Graphics (MetalFX upscaling and Sharpening, with an
info button explaining them; the Metal HUD; Game Mode; Shader memory), Audio (microphone; how Bluetooth headphones
and the sound output are handled) and Advanced (Force Quit, Repair, Logging and Save Logs, proxy detection).
Uninstall stays at the foot of every tab. `HelpSheet.swift` owns Help &
FAQ, in the same tabs (`LauncherTabs`): FAQ and Troubleshooting (`HelpTopic`: an answer, numbered
steps, a note and a button to the setting the steps name, one topic open at a time) and Support
(the Discord invite, and a bug report in three steps: copy or save the support report, save the
logs, then open a GitHub issue). A search field under the tabs (1.5) looks through FAQ and Troubleshooting together
(`HelpTopic.search`: every word of the query in the question or its answer, questions that name it
first, case, accents, width, bold and curly quotes ignored; Chinese and Korean match as typed) and
shows the matches under the tab each lives in, with no tab selected. Cmd-F starts a search, Esc
clears it before it closes Help, Return opens the first answer, and choosing a tab ends it. The
Edit menu has Undo, Redo, Cut and Paste for the field (`Main.swift`); `tests/HelpSearchTests.swift`
covers the matching. The Play, opening and running screens name what else is using the Mac
(1.5, REC-5; `BusyApps.swift`, shown by `PerformanceTip`, one row each, and nothing when
nothing is; Help › Troubleshooting explains them at length): when other apps together use more graphics, processor (performance
cores Overwatch needs to itself) or memory than Overwatch can spare, the largest users until the
rest would fit, graphics first, each with its icon, what it uses and a Quit button
(`NSRunningApplication.terminate`, as Cmd-Q); plus Low Power Mode (a button to
System Settings › Battery, or › Energy without a battery), a Mac that macOS is slowing down to
cool (thermal state serious or critical). When macOS reports memory pressure
(`kern.memorystatus_vm_pressure_level` warning or critical, before or during a match), the note
says the Mac is low on memory and names the largest memory users until they hold Overwatch's
footprint; if all of them together couldn't make room, macOS itself holds the memory and, before
Overwatch starts, it suggests a restart instead. Memory moved to disk (`vm.swapusage`) is only
reported: it stays there long after the pressure. On October 20 such a Mac kept FPS while
movement and aim answered late; Help › Troubleshooting › "My controls feel delayed" says to quit
apps, then to restart a Mac up for days. The lines come from replay and in-game measurements.
It reads what Activity Monitor shows without any permission: this user's processes' processor
time and footprint (`proc_pidinfo`, `proc_pid_rusage`), each grouped
under the app macOS holds responsible for it (`responsibility_get_pid_responsible_for_pid`, not
public API), graphics time per process from the GPU driver's user clients in the I/O Registry
(`AppUsage`), and `kern.memorystatus_level`. Recall, its data folders (Wine, Battle.net, Overwatch),
macOS's own apps and the Finder never count. `AppModel.watchLoad` looks every five seconds while
one of those screens is visible (`applicationDidChangeOcclusionState`), never while the window is
hidden, a match included; Battle.net's or Overwatch's launch saves the latest result, and the
support report (schema 4) carries it as `other_apps.at_last_launch` with the current one as
`other_apps.now`. `tests/BusyAppsTests.swift` covers the reading and the choice.
`AppModel.openHelp` opens it on Troubleshooting after a failed step, on Support
from Help › Report a Problem…, otherwise on FAQ. Every pop-up is 540 wide; Settings, Help &
FAQ, About and Licenses are all 540 × 760 (`LauncherStyle.largeSheetHeight`), so tabs, Done and
Uninstall never move: Settings' page scrolls only when a notice joins its tallest tab (Graphics
with Battle.net open, 745), and About's letter and support section scroll. Esc closes every
pop-up a Done, Continue, Later or Cancel button closes (`closesOnEscape` beside Return), and a
click on the main window outside the open pop-up closes it the same way (`Main.swift`'s local
event monitor, `AppModel.closeSheetFromOutside`): not in the title bar, not under a nested sheet
or an alert, not while an info popover is open, never during an update's download or install or
once uninstalling has started. The window's minimum, 540 × 800, is also its SwiftUI content's,
because the hosting view otherwise replaces the window's minimum with its content's (near zero). `ProjectLinks.swift` holds the link buttons, the lockup, the author
photo and the support card. `DisplayOptions.swift` lists the fullscreen
resolutions (1080p, 1440p and 4K in 16:10 and 16:9, as in the launch contract)
and reads the main display, which Settings names and uses to say how a choice
looks there and whether it fits: Wine sees the main display at twice its size in
points, and a larger game window would leave part of it out of the pointer's
reach (the worker lowers such a choice at launch by the same rule). Players
usually set the resolution in Overwatch's Video settings; the worker keeps that
choice (`nextResolution` in `portable_preferences.h`, reported by `status` as
`display_next`), so Settings › Display shows it, with sizes that write the same
game setting from outside the game. Each main display (by make, model and serial
number) keeps its own resolution unless Settings › Display › Remember a resolution for
each display is off (`display-memory`); a display seen for the first time starts at 1080p
in its shape. Reset Display Settings writes the first-install
resolution (1080p in the main display's shape) and the other display settings again,
leaving quality and FPS alone. Uninstall
asks the worker to move the owned data root to the Trash (refused while an owned
Battle.net or Overwatch process runs), then the app removes its lock folder and
defaults and moves its own bundle to the Trash. Nothing is deleted outright. `LauncherStyle.swift`
defines the shared typography (the system font, SF Pro), surfaces, hero and actions. `AppModel.swift` owns observable UI state and
coordinates resumable worker operations. `SetupService.swift` runs the native
worker off the UI thread and consumes bounded JSON events. `InstallLocation.swift`
holds the install-location rules: the internal default, the optional folder
choice before setup starts (APFS/Mac OS Extended, not case-sensitive, not
read-only, network or cloud-synced) and disconnected-drive detection. A refusal can
name a Help topic, which the setup screen's notice opens (a case-sensitive drive gets
Help's steps to add a volume or partition that isn't, instead of erasing it). An installation
the player moves away from with Set Up on This Mac Instead is remembered
(`otherInstallLocation`, `AppModel.otherInstallation`) while its folder still holds one: the
setup screens' note, the Install location menu and Settings › General take the player back
(`OtherInstallationSheet` asks whether the setup here moves to the Trash, through the worker's
`uninstall`, or stays and is offered back; `tests/OtherInstallationTests.swift`). The worker
enforces the same drive rules for any new data folder and never creates a
missing parent, so an unplugged drive cannot become a stray internal folder.
When macOS won't let the worker create, own or write in the data folder (its
`SetupFailure.folderAccessCodes`, such as `directory_creation_failed` under a locked
Application Support), the failure screen says so: "Recall can't use its folder", the
folder to fix (`InstallLocation.folderToFix`: the data folder, or the nearest folder above
it that exists), Show in Finder, which selects it for File › Get Info, and Help's
`folder-access` steps. Retry and reinstalling can't get past it (REC-54).

The mouse (Settings › General › Mouse, `AppModel.MouseInput`, Standard unless the player
chooses; setup doesn't ask) is one of three, passed as `launch --mouse`. Standard keeps the
launch contract's input variant, `precise` (1.5's: clicks from Apple's mouse input for games,
GCMouse, in order with its movement). Classic (REC-57) has the worker set the window driver's
`classic`: 1.4's clicks and timing, with 1.5's stand-in while GCMouse is silent. High-precision
(REC-52; recommended from 1.6.1, REC-64) has it set `WINEMAC_RAW_SOURCE=hid`: the driver reads
the mouse's own reports through IOHID instead of GCMouse, which loses some in game. Choosing it
first opens `HighPrecisionMouseSheet`, which explains it in plain words, why macOS will ask to
let Recall "receive keystrokes", how to undo it and what macOS shows next, and links the
Discord post for feedback (GitHub on China's Battle.net). Its Turn On
(`AppModel.turnOnHighPrecision`) chooses it and shows macOS's prompt the first time, or after
a no opens System Settings, since macOS asks only once. The Play screen's card
(`HighPrecisionCard`, `HighPrecisionInvite`) invites players to it once Overwatch is installed,
while Battle.net is closed and a mouse is connected (the driver's rule, read from the I/O
Registry, which needs no permission), and after it is chosen reminds them to finish the
permission; closing it, or leaving High-precision, hides it for good. IOHID needs Input Monitoring,
the app's permission as the microphone is (`InputMonitoring.swift`): the panel links to the
switch in System Settings until it is allowed, and the game's process, which the app
started, has the app's answer. Without it the driver keeps GCMouse and asks nothing. The
driver opens only devices with a mouse collection, trackpads excepted, reads only X, Y and
buttons, passes their input on only while macOS still gives the game mouse input of its own
(so not while another app has the mouse), and counts GCMouse's input beside it for
comparison (the Mouse logging preset's `hid_shadow_*`).

Mouse › Advanced (`AppModel.MouseRate`, REC-63), closed until the player opens it, sets at
most how many times a second Overwatch gets the mouse's movement: every report (the default
from 1.6.1), or 2,000, 1,000 (1.6.0's), 500 or 250, passed as `launch --mouse-rate`. The worker
sets the window driver's `WINEMAC_MOUSELOOK_RAW_INTERVAL_US` (0, or a million over the rate);
the driver adds up what comes in between, so no movement is lost, only later. Classic keeps
the driver's own 1 ms, its 1.4 timing, so the worker leaves the variable out there and the
section says so in place of the slider. In the owner's test of October 25 (4,000 Hz,
High-precision) every report brought movement 1.6 ms sooner than 1,000 a second, at no FPS
cost. The Support Report (`mouse_rate`) and the session record name the choice.

Overwatch's voice chat uses the app's microphone permission: to macOS the game runs
as part of the app, and the app and Wine are signed with the microphone entitlement.
`Microphone.swift` asks before Battle.net first opens (left to the game, Wine would
ask from inside a match), and Settings › Audio shows whether it is on, with a button to the
switch in System Settings, the only place it changes. A Bluetooth headset whose
microphone is in use drops to low-quality hands-free sound, so when the default
microphone is a Bluetooth headset and the Mac's built-in microphone can hear (lid
open), the worker makes the built-in one Wine's default microphone at launch
(`portable_voice.h`, reported as `voice_microphone`); a microphone chosen in
Overwatch still wins. Quits from outside the app (the Dock, logging out, System
Settings after a permission change) go to `AppModel.quit`, which closes an open sheet
first: AppKit drops them while one is attached.

Battle.net, Overwatch and Wine are Intel programs, so every launch and the Battle.net
installer first check Rosetta (`rosetta_required`, the same screen as first setup; an
upgrade to macOS 27 can remove it). Two choices the worker keeps in `state.json` and in
Wine's registry (`portable_network.h`, `portable_korea.h`): automatic proxy detection
(Settings › Advanced), off by default because some internet providers answer the lookup it
makes with an address that never responds and the Battle.net installer then stalls
(`network`); and Korean account support, which is the Korea region (see below): it adds a
DigiCert certificate the Korean build checks and has Wine's Mac driver answer screen reads
with a black image (`korean-support`, `WINEMAC_SCREEN_READBACK`). Setup applies both before
Battle.net's installer runs; a launch puts back any that went missing. Both change only
while Battle.net and Overwatch are closed. Setup and launches also make the left Option key
Alt in Overwatch alone (`keyboard`, Wine's Mac driver `LeftOptionIsAlt` under
`AppDefaults\Overwatch.exe`): Wine sends nothing for Option and makes Command Alt, so
Overwatch's Alt actions answered only to Command. Command stays Alt, and the right Option key
and Battle.net keep typing Option's characters. On Global, the Play screens suggest the Korea
region when the game folder holds Nexon's anti-cheat (`nexon_build`). Support reports name the
failure code itself; anything that isn't a plain code stays `other_setup_error`.

Recall speaks English, Simplified Chinese and Korean (`Localization.swift`), following the
Mac's language or the one chosen for Recall in System Settings › General › Language & Region ›
Applications. Every on-screen string goes through `L("English", values…)`: the English is
the key, `{0}`, `{1}`… stand for values filled in after the lookup, and `sentences()` joins
whole sentences (no space between them in Chinese). Names and codes use `Text(verbatim:)`.
The translations live in `Resources/Localizations/zh-Hans.json` and `ko.json` (`Localizable`,
plus the two `InfoPlist` strings); `build_native_app.py` writes an `.lproj` for each as binary
`.strings` and declares them all in `CFBundleLocalizations`. `tests/test_localization.py`
fails on an untranslated or leftover string, mismatched `{n}`, on-screen text or any other
sentence that skips `L`, and a translation whose Markdown bold doesn't parse as the English
does (Help renders its text as Markdown). The update sheet takes a release's `## 更新内容`
or `## 새로운 기능` section when Recall is in Chinese or Korean.

Setup's first question is which Battle.net to install (`BattleNetChoice.swift`, screen
`battleNet`): Global, Korea (Korean accounts linked to Nexon, which sign in to Global's
Battle.net) or China's (国服, NetEase accounts, Blizzard's China installer pinned in
`release.json` as `chinaInstallerURL`/`chinaInstallerSHA256`), and the language Battle.net
installs in (English, Simplified Chinese or Korean; China's is Chinese only, Korea suggests
Korean), all filled in from the Mac. China first shows `ChinaBattleNetSheet` (NetEase sign-in
in the browser, the anti-cheat's account risk), Korea `KoreanSupportSheet` (what Recall
changes, Nexon's anti-cheat). Setup hands the Battle.net to the worker (`battlenet`,
`portable_region.h`: `global` for Korea too), which keeps it in `state.json`, runs the
installer with that `--lang` and, for Chinese or Korean, adds Wine font replacements so
Battle.net's text isn't boxes (`tests/run_font_probe.py`); for Korea setup also turns on
Korean account support (`korean-support`), which prepare applies. The region an installation
is on is `BattleNetRegion.kept`: China's Battle.net, or Global's, which is Korea while Korean
account support is on, so 1.3 and 1.4.0 installations that turned it on in Settings ›
Advanced show as Korea (`tests/RegionTests.swift`). Settings › General › Battle.net region
switches between Global and Korea by turning that support on (Korea asks first) or off;
accounts don't carry over to or from China's Battle.net, so that change moves the
installation to the Trash (the worker's `uninstall`, `ChangeRegionSheet`) and starts setup
again with the region chosen. Help shows the topics for every player and those for the
player's region (`HelpTopic.regions`, `AppModel.currentRegion`: NetEase sign-in and account
on China's Battle.net; Xbox sign-in on Global and Korea; the Korean account's risk on Korea;
how to choose Korea on Global), and setup's sign-in note follows the region. Discord is blocked in mainland China, so
players who choose China's Battle.net see `GitHubHelpLink` where the Discord card is
(`AppModel.showsDiscord`). The worker finds Battle.net and Overwatch in other folders under Program Files
too, and support reports name the region, languages, default browser and whether NetEase's
anti-cheat is present.

Settings › Graphics › MetalFX upscaling, off by default, makes Overwatch offer NVIDIA DLSS in its
own Video settings; DXMT runs it on Apple's MetalFX. The app passes it, with Sharpening
(off, low, high), as `launch --metalfx --sharpening`. With it on, the worker
(`portable_metalfx.h`) starts Battle.net with the contract's MetalFX environment (an
NVIDIA identity and the engine's d3d12, DLSS and NVAPI stand-ins, which the contract
otherwise disables), puts the engine's signed DLSS stand-in in `system32` (NVIDIA's
loader in the game checks that file's signature), writes the card the game is about to
see into the game's own record of it so it keeps the player's video settings, and adds
the sharpening amount to the launch's `dxmt.conf`. With it off, it undoes each of those
and clears a choice of DLSS. Like the Metal HUD, both settings change only while
Battle.net is closed.

The app has no network account, telemetry, player-side Python or runtime build
step. Authentication and game downloads remain inside official Battle.net.
`UpdateService.swift` is its only network use: when automatic checks are on, an
anonymous request to GitHub's latest-release API at launch and at most every 12
hours. Update Now downloads the release DMG, checks GitHub's SHA-256, mounts it
and accepts the app inside only if it is notarized, signed by this app's own
Developer ID team, carries the same bundle identifier and the release's version.
It is copied beside the installed app, verified again, swapped in place
(`FileManager.replaceItemAt`) and reopened after this process exits. Any failure
changes nothing and offers the release page. At launch the check waits at most
three seconds before Battle.net opens. During setup and on error screens, which never
reach that launch, the sheet opens as soon as the check finds an update and nothing is
running, once a launch (`AppModel.offerUpdate`, `tests/UpdateOfferTests.swift`). After an update that brings new game
components, they install without a click and What's New shows once.
`Resources/release.json` is reviewed release input sealed by app signing. The
runtime SHA is trusted from this app resource, not fetched alongside a download.

`build_native_app.py` builds and signs helpers before the outer bundle, generates
the app icon from the owner-provided `Resources/AppIcon.png`, and embeds only the pinned runtime archive and
required resources/notices. Build proofs stay outside executable helper folders.
`scripts/app_icon.swift` fits the unchanged artwork to Apple's icon grid (an
824-point continuous-corner body over white, so macOS 26 does not set it on a
gray tile) and emits all standard 16–1024 pixel representations; `iconutil` assembles the ICNS. An optional
`--icon /path/to/AppIcon.icns` still overrides the default. The launcher header
uses the bundled application icon. Source PNG metadata was removed without
changing its pixels; the original owner file remains local and unchanged.

`AppLocation.swift` handles an app opened from its disk image or translocated:
it copies itself into /Applications (~/Applications when that is not
writable, never over a different app with the same name), verifies the copy
like an update, clears the download quarantine, moves older copies of itself
(same identifier, lower version or build, such as the app under its former
name) to the Trash, ejects the disk image (only a disk image, found through
`hdiutil info`) and reopens. An installed copy retires older copies at launch.

Swift suites (scratch data only; the optional arguments run real installs from
a notarized Developer ID build and never touch /Applications):

```sh
swiftc -O -target arm64-apple-macos26.5 -parse-as-library app/Sources/Localization.swift app/Sources/Brand.swift \
  app/Sources/SetupService.swift app/Sources/UpdateService.swift tests/UpdateServiceTests.swift \
  -o runtime/phase-3/update-tests
runtime/phase-3/update-tests [<scratch app copy> <newer notarized DMG> <its version>]
swiftc -O -target arm64-apple-macos26.5 -parse-as-library app/Sources/Localization.swift app/Sources/Brand.swift \
  app/Sources/SetupService.swift app/Sources/UpdateService.swift app/Sources/AppLocation.swift \
  tests/AppLocationTests.swift -o runtime/phase-3/location-tests
runtime/phase-3/location-tests [<notarized app> <empty scratch folder>]
swiftc -O -target arm64-apple-macos26.5 -parse-as-library app/Sources/Localization.swift app/Sources/InstallLocation.swift \
  tests/InstallLocationTests.swift -o runtime/phase-3/install-location-tests
swiftc -O -target arm64-apple-macos26.5 -parse-as-library app/Sources/Localization.swift app/Sources/DisplayOptions.swift \
  tests/DisplayOptionsTests.swift -o runtime/phase-3/display-options-tests
runtime/phase-3/display-options-tests   # from the repository root
```

Native process execution: `scripts/portable_setup.m`, with scoped session and
display helpers. The native pipeline coordinator invokes a separately compiled
helper built from the exact accepted production cache/recipe implementation.
It clones, prepares, verifies, and atomically publishes while preserving the
prior cache. It never runs a player-side compiler or imports developer caches.
The game names its cache folder with Metal's registry ID for the GPU, which
macOS reassigns at each restart, so the coordinator first folds folders left by
earlier restarts into the one the game opens now and removes them. Archives
carry over only from the same macOS version; preparation rebuilds the rest.
Its progress lines (each shader from the preparation tool's diagnostic log) reach
the launching screen's "Preparing graphics" details as `graphics` events.
With Game Mode the game runs as the engine's game app, and macOS keeps compiled
shaders per app, so that app's cache starts empty after the update that brings it
and after each macOS update. Settings › Graphics › Game Mode (`AppModel.gameMode`,
on by default; 1.6's test builds had it off, REC-51, until REC-55; support's `gameMode`
default from 1.1 is the same setting) passes `launch --game-mode 0` when off, and the game then runs as Wine's own
loader (`lib/wine/x86_64-unix/wine`, whose embedded Info.plist names it
`com.codeweavers.CrossOver.wineloader`, a cache it shares with CrossOver). The worker
passes the program the game runs as (`gameProgram`), and a second helper,
`pipeline-warm`, compiles every learned pipeline into that program's cache
(`MTLSetShaderCachePath`, 16 at a time in one process) once per program, macOS version
and GPU (`cache/warmed.json`); switching the setting names the other program, whose cache is
then warmed in turn. Clear Shader Cache removes the game app's cache only, never the
loader's, which CrossOver uses too. Since 1.4 the pack holds every learned pipeline
(`dxmt-shader-pack.patch`): the game keeps learning until the disk is nearly full,
archives have no total size limit and are hashed in 1 MiB pieces, all at once on every
core, and nothing learned is forgotten. A game holds what it loads of the pack in memory
(about the archives' size). It loads archives in order, slowest pipelines first (the helper
keeps the catalog ordered by recorded build time per byte and writes each archive's size and
count to `cache/pack.json`), as much as Settings › Graphics › Shader memory allows: all of
it on every Mac unless the player chose less (Overwatch measured 5.7 GB with the whole pack
at the owner's settings and 9.6 GB at maximum settings on a 16 GB Mac; 8 GB players, at low
settings, can lower it). Settings reads the catalog itself until `pack.json` exists.
The worker keeps the choice (`shader_memory` in state.json, `shader-memory --limit
all|first|<MiB>`) and writes it to `cache/pipelines/load.json`, which the game reads as it
starts; each launch writes it first, so a game started from a Battle.net already open has it
too. Loading isn't cut off at the 10-second startup deadline: lookups stop waiting then, and
an archive still loading is used once it has loaded. The game no longer adds to the pack
itself, since a game that loaded part of it must not rewrite its catalog. After updating to
1.4, a sheet offers the one-time shader cache update once, after What's New, when learned
pipelines aren't prepared yet (`ShaderUpdateSheet`): `prepare-shaders` replaces a monitor
waiting for a match (`cache/monitor.pid`) with one that prepares now, marked by
`cache/shader-update` so the main window says "Updating your shader cache", then watches the
session like any monitor; a launch stops it like any preparation. After each
session the helper also warms every learned pipeline into the shader cache of the program the
game ran as (`warm`; the monitor passes it with `watch --game-app`), which costs
no memory until the game uses one and covers what a game doesn't load. Preparation adds batches: each is one more archive of up to 2048
pipelines or about 150 seconds of first builds, slowest (and of those, most recently
used) first, made in a clone by the tool's append mode, verified in a fresh process
and published by an atomic swap before the next starts, so a stopped preparation
keeps its finished batches. Archives under 512 pipelines (the game's own, a batch cut
short) and damaged ones are built again into the next batch, so the pack stays a few
large files. A pipeline finished past the tool's deadline goes into the next batch;
one that failed to build waits for the next session.
Preparing takes minutes (the first time, on a cache like the owner's, about 20), so it
happens after a match: the session's monitor (`watch`), which waits up to 12 hours for
a match while Battle.net is open, stays until the game has closed and runs
`ow2-pipeline --after-session` (its pid in `cache/after-session.pid`, up to 4 hours);
a launch folds folders, warms and reports what that preparation added, then stops a
monitor still preparing. The monitor doesn't depend on the app:
quitting or force quitting it leaves the preparation running. While the pid file names a
live `ow2-setup` (`AfterMatch`), the ready screen and the running screen with only
Battle.net open show "Preparing shaders from your last match", checked when the window
becomes active and every few seconds while shown, with how many are ready of all learned
(`cache/preparing.json`, written after each batch). The launching screen's details explain
the two numbers (ready: the pack's pipelines; learned: every recipe), and an info button
explains shaders in plain words (`ShaderInfo`,
also in Help's FAQ). Support reports carry the numbers, whether preparation is running or
waiting for the game to close, and how the last after-match preparation ended, as a code
(`ShaderRecord`): one stopped because the game started again is `cancelled`, not `failed`. From
1.5.0 (schema 3) they give MetalFX upscaling (`on`/`off`) and its sharpening as two fields
(`tests/SupportReportTests.swift`).

Settings › Advanced › Logging (`LoggingSetting`, `Logging.swift`; REC-40) is off unless the player
turns it on: presets named for a kind of problem (Crashes and freezes, Graphics, Battle.net, Mouse),
any mix of them at once (REC-51; kept as their names joined with commas, which reads 1.5's single
setting as it was), and Custom, Wine's own WINEDEBUG text, checked as it's typed against Wine's
grammar, whose items come after the presets'. Mouse adds no Wine logging: it turns on the window
driver's mouse report (`WINEMAC_INPUT_STATS`), one JSON line a second for each Wine process that is
frontmost or has input, `input-<pid>.jsonl` in the session's folder; Save Logs keeps its mouse data
and drops its key-press counts (`MouseReport`). Battle.net carries the setting from when it opens
(worker: `launch --logging`, `scripts/portable_logs.h`), as it does the HUD.
The worker keeps each Battle.net start's output and record in `logs/sessions/<UTC start>/` and
removes the oldest only while the logs would take more room than the disk has left. Turning
logging on warns about FPS first, and the Play, opening and running screens say it's on, or that
an open Battle.net still logs (`LoggingReminder`, one slim row with Save Logs and Turn Off, so it
stacks with the busy-apps note and the first-matches tip). Save Logs
(Settings › Advanced, Help › Support and the reminder; `LogBundle.swift`) saves the recent
sessions' logs from Recall, Battle.net and Overwatch in one zip, newest first while it stays under
GitHub's 25 MB attachment limit, after `LogCleaner` removes personal details (its rules come from
a check of real logs). `Summary.txt` is the timeline in the player's language; `index.json` and
`README.md` (`app/Resources/LogsReadme.md`) point engineers and AI assistants at the moments that
matter, by file and line. Crash dumps never go in. The support report names the setting, and
from schema 5 whether Game Mode is on.
`tests/LogBundleTests.swift` and `tests/test_session_logs.py` cover them.

The running screen learns the session's processes from `ow2-setup session` (when the window
becomes active, or from Settings) and asks macOS to report when each one ends (a process
dispatch source), so it returns to Play the moment Overwatch or Battle.net quits; nothing
polls while the game runs. After Exit to Desktop, Overwatch minimizes its window and keeps
working for 10–80 seconds before it quits (QA, 2026-10-14: about 230% CPU, the same with
Shader memory at "Slowest only", so not the pack). While the game's window isn't on screen
the running screen says it can take up to a minute to close and offers Force Quit
(`GameClosingNote`, which confirms first). It never ends the game itself: a game minimized
mid-match, or on another desktop, looks the same.

A Dock click opens Battle.net (when it's set to open with the app and nothing runs) only
when the window was closed, as opening the app does; a window behind other apps or
minimized just comes forward. Lifecycle follows AppKit's reopen callback and native
window/menu behavior:
[Apple app organization](https://developer.apple.com/documentation/swiftui/app-organization)
and [AppKit reopen handling](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen(_:hasvisiblewindows:)).

See `docs/PHASE_3_NATIVE_APP.md` for private QA evidence, reproducible developer
commands and remaining acceptance limits. This file is developer documentation;
the final public README remains deferred.

Private-preview builds accept `open <app> --args --preview-state <screen>` (for example `welcome` or `ready`) for a read-only preview of a screen.
The read-only preview menu is private-build/argument gated; normal launches do
not expose it. Gameplay and setup orchestration stay outside the view layer.
