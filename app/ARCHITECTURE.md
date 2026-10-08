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
Help & FAQ and About buttons, while `UtilitySheets.swift` owns Settings, Help & FAQ, About
(with Licenses: the bundled NOTICE and Apache 2.0 text, and the third-party
license files in Finder), Uninstall, the update sheet and What's New (content in `WhatsNew.swift`,
bundled). Settings is in tabs (`SettingsTab`), and reopens on the last one shown:
General (updates, opening Battle.net with the app, Mac-sized Battle.net window, off by
default from 1.3 because its sign-in window doesn't fit at that size), Display (fullscreen
resolution, Reset Display Settings), Graphics (MetalFX upscaling and Sharpening, with an
info button explaining them; the Metal HUD), Audio (microphone; how Bluetooth headphones
and the sound output are handled) and Advanced (Force Quit, Repair, proxy detection,
Korean account support). Uninstall stays at the foot of every tab. `ProjectLinks.swift` holds the link buttons, the lockup, the author
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
and GPU (`cache/warmed.json`). A failed archive (too large, or not covering a key the
last one listed) is tried again smaller instead of ending preparation, and an
archive listing pipelines with no recipe left is rebuilt.

Lifecycle follows AppKit's reopen callback and native window/menu behavior:
[Apple app organization](https://developer.apple.com/documentation/swiftui/app-organization)
and [AppKit reopen handling](https://developer.apple.com/documentation/appkit/nsapplicationdelegate/applicationshouldhandlereopen(_:hasvisiblewindows:)).

See `docs/PHASE_3_NATIVE_APP.md` for private QA evidence, reproducible developer
commands and remaining acceptance limits. This file is developer documentation;
the final public README remains deferred.

Private-preview builds accept `open <app> --args --preview-state <screen>` (for example `welcome` or `ready`) for a read-only preview of a screen.
The read-only preview menu is private-build/argument gated; normal launches do
not expose it. Gameplay and setup orchestration stay outside the view layer.
