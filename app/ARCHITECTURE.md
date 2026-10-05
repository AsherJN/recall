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
Help & FAQ and About buttons, while `UtilitySheets.swift` owns Settings
(updates, resolution, Force Quit, Repair, Reset Display Settings, Uninstall), Help & FAQ, About
(with Licenses: the bundled NOTICE and Apache 2.0 text, and the third-party
license files in Finder), Uninstall, the update sheet and What's New (content in `WhatsNew.swift`,
bundled). `ProjectLinks.swift` holds the link buttons, the lockup, the author
photo and the support card. `DisplayOptions.swift` lists the fullscreen
resolutions (1080p, 1440p and 4K in 16:10 and 16:9, as in the launch contract)
and reads the main display, which Settings names and uses to say how a choice
looks there and whether it fits: Wine sees the main display at twice its size in
points, and a larger game window would leave part of it out of the pointer's
reach (the worker lowers such a choice at launch by the same rule). Players
usually set the resolution in Overwatch's Video settings; the worker keeps that
choice (`nextResolution` in `portable_preferences.h`, reported by `status` as
`display_next`), so Settings shows it in a folded row whose sizes write the same
game setting from outside the game. Each main display (by make, model and serial
number) keeps its own resolution unless Settings › Remember a resolution for each
display is off (`display-memory`); a display seen for the first time starts at 1080p
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
swiftc -O -target arm64-apple-macos15.0 -parse-as-library app/Sources/Brand.swift \
  app/Sources/SetupService.swift app/Sources/UpdateService.swift tests/UpdateServiceTests.swift \
  -o runtime/phase-3/update-tests
runtime/phase-3/update-tests [<scratch app copy> <newer notarized DMG> <its version>]
swiftc -O -target arm64-apple-macos15.0 -parse-as-library app/Sources/Brand.swift \
  app/Sources/SetupService.swift app/Sources/UpdateService.swift app/Sources/AppLocation.swift \
  tests/AppLocationTests.swift -o runtime/phase-3/location-tests
runtime/phase-3/location-tests [<notarized app> <empty scratch folder>]
swiftc -O -target arm64-apple-macos15.0 -parse-as-library app/Sources/InstallLocation.swift \
  tests/InstallLocationTests.swift -o runtime/phase-3/install-location-tests
swiftc -O -target arm64-apple-macos15.0 -parse-as-library app/Sources/DisplayOptions.swift \
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
