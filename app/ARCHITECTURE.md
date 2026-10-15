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
General (updates, opening Battle.net with the app; Battle.net's size follows the main
display by itself, so there is no switch for it), Display (fullscreen
resolution, Reset Display Settings), Graphics (MetalFX upscaling and Sharpening, with an
info button explaining them; the Metal HUD; Shader memory), Audio (microphone; how Bluetooth headphones
and the sound output are handled) and Advanced (Force Quit, Repair, proxy detection,
Korean account support). Uninstall stays at the foot of every tab. `HelpSheet.swift` owns Help &
FAQ, in the same tabs (`LauncherTabs`): FAQ and Troubleshooting (`HelpTopic`: an answer, numbered
steps, a note and a button to the setting the steps name, one topic open at a time) and Support
(the Discord invite, and a bug report in two steps: copy or save the support report, then open a
GitHub issue). `AppModel.openHelp` opens it on Troubleshooting after a failed step, on Support
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
read-only, network or cloud-synced) and disconnected-drive detection. The worker
enforces the same drive rules for any new data folder and never creates a
missing parent, so an unplugged drive cannot become a stray internal folder.

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
upgrade to macOS 27 can remove it). Settings › Advanced holds two choices
the worker keeps in `state.json` and in Wine's registry (`portable_network.h`,
`portable_korea.h`): automatic proxy detection, off by default because some internet
providers answer the lookup it makes with an address that never responds and the
Battle.net installer then stalls (`network`); and Korean account support, experimental,
which adds a DigiCert certificate the Korean build checks and has Wine's Mac driver
answer screen reads with a black image (`korean-support`, `WINEMAC_SCREEN_READBACK`).
Setup applies both before Battle.net's installer runs; a launch puts back any that
went missing. Both change only while Battle.net and Overwatch are closed, and turning
Korean support on asks first, in English and Korean. The Play screens suggest it when
the game folder holds Nexon's anti-cheat (`nexon_build`). Support reports name the
failure code itself; anything that isn't a plain code stays `other_setup_error`.

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
three seconds before Battle.net opens. After an update that brings new game
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
swiftc -O -target arm64-apple-macos26.5 -parse-as-library app/Sources/Brand.swift \
  app/Sources/SetupService.swift app/Sources/UpdateService.swift tests/UpdateServiceTests.swift \
  -o runtime/phase-3/update-tests
runtime/phase-3/update-tests [<scratch app copy> <newer notarized DMG> <its version>]
swiftc -O -target arm64-apple-macos26.5 -parse-as-library app/Sources/Brand.swift \
  app/Sources/SetupService.swift app/Sources/UpdateService.swift app/Sources/AppLocation.swift \
  tests/AppLocationTests.swift -o runtime/phase-3/location-tests
runtime/phase-3/location-tests [<notarized app> <empty scratch folder>]
swiftc -O -target arm64-apple-macos26.5 -parse-as-library app/Sources/InstallLocation.swift \
  tests/InstallLocationTests.swift -o runtime/phase-3/install-location-tests
swiftc -O -target arm64-apple-macos26.5 -parse-as-library app/Sources/DisplayOptions.swift \
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
and after each macOS update. The worker passes the game app's path, and a second
helper, `pipeline-warm`, compiles every learned pipeline into that app's cache
(`MTLSetShaderCachePath`, 16 at a time in one process) once per app, macOS version
and GPU (`cache/warmed.json`). Since 1.4 the pack holds every learned pipeline
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
session the helper also warms every learned pipeline into the game app's shader cache
(`warm`, Game Mode only; the monitor passes the app with `watch --game-app`), which costs
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
also in Help's FAQ). Support reports carry the numbers, whether preparation is running and
how the last after-match preparation ended, as a code (`ShaderRecord`).

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
