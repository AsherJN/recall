# Architecture and development

The Windows client and game run through Wine under Rosetta. DXMT translates
Direct3D 11 rendering into Metal. A modified Wine Mac window driver maintains
the game canvas through fullscreen and focus transitions. Pipeline preparation
uses locally learned recipes; it cannot prepare effects never encountered before.

Current launch policy uses three drawables, eight normal-priority compiler
workers, DXGI maximum frame latency one, normal Wine presentation, frame pacing
mode 3 with a 1 ms margin, and shader variants prepared when the game creates
its shaders. It preserves the saved game FPS limit. Diagnostic overlay presentation has
a known focus-return failure and is not a supported player option.

Layout:

- `app/` — the SwiftUI Mac app: setup wizard, launch, settings, support and
  in-app updates.
- `scripts/` — portable runtime build pipeline, native setup worker sources,
  release packaging, and developer analysis tools.
- `patches/` — the DXMT and Wine integration patches against pinned upstream commits.
- `tests/` — deterministic Python tests plus native fixtures.
- `config/` — DXMT profiles.
- `licenses/` — upstream license texts.

Good first places to look: `app/Sources/Brand.swift` for the app's name and
links, `app/Sources/SetupService.swift` for the setup flow,
`scripts/portable_setup.m` for the native worker, and `patches/` for the
rendering and window-driver changes.

## Quick start: build the app

To work on the Mac app (its screens, setup and settings), you don't need to
build the Wine engine. Build the app around the engine from the matching Recall
release. You need Apple's Command Line Tools (`xcode-select --install`), git and
Python 3.10 or later.

1. Clone the repository. `main` matches the latest release; for an earlier one,
   check out its tag, for example `git checkout v1.4.0`.

   ```sh
   git clone https://github.com/AsherJN/recall.git && cd recall
   ```

2. Copy the engine out of the Recall app of the same version. If the Recall you
   have installed is a different version, download the matching one from
   [Releases](https://github.com/AsherJN/recall/releases).

   ```sh
   mkdir -p runtime
   cp /Applications/Recall.app/Contents/Resources/runtime.tar.gz runtime/
   ```

3. Fetch the shader preparation source once. This clones DXMT at its pinned
   commit and applies the project's patches; it needs no other tools.

   ```sh
   python3 scripts/build_portable_dxmt.py --workspace runtime/dxmt --source-only
   ```

4. Build the app. Each build needs a new `--output`; earlier ones are kept.

   ```sh
   python3 scripts/build_native_app.py --output runtime/build/Recall.app --workspace runtime/dxmt
   ```

5. Quit the installed Recall, then open your build with
   `open runtime/build/Recall.app`. It uses the same data folder as the installed
   app, so it sets up and plays the same way. To look at screens without touching
   your installation, build with `--preview` and open it with
   `open runtime/build/Recall.app --args --preview-state welcome`; its Preview menu
   switches between screens and between light and dark appearance.

The build stops if the engine or the shader preparation source isn't the exact
one this version of the app was tested with, and says what to fix. To try your
own engine in a personal build, build it as [BUILDING.md](BUILDING.md) describes,
then set `runtimeArchive`, `runtimeVersion` and `runtimeSHA256` in
`app/Resources/release.json` to match it. Don't share a build made that way.

Run the tests that need no game or engine with `python3 tests/run_portable.py`.
Run the Mac app's setting/launch race regression with
`python3 tests/run_advanced_settings.py`; it uses a temporary app and fixture
worker without changing an installed Recall environment.

## Contributing

Keep changes focused, preserve upstream attribution, and describe relevant
validation. Use synthetic fixtures for tests; never submit game files, installed
Windows environments, accounts, credentials, private paths, or learned caches.
Support claims require actual game evidence on the stated hardware and OS.

`tests/run_portable.py` selects tests that can run without proprietary components,
the installed runtime, or private playtest logs. Remaining tests are retained as
developer fixtures and have explicit prerequisites; see [BUILDING.md](BUILDING.md). The source
audit scans all reachable commit contents and metadata, and complements manual
review. It is not a guarantee that arbitrary text contains no sensitive data.

When contributing changes to a third-party project, follow that project's own
contribution policy. This integration repository does not claim authorship of
upstream rendering or compatibility implementations.

## System stats HUD

**Settings → Display → System Stats HUD** toggles a small click-through strip at
the upper left of each display while Recall’s Overwatch app is active, including
fullscreen Spaces. Switching apps hides it and stops sampling. It defaults to off,
remembers the choice, and applies immediately without restarting the game.
CPU and GPU usage are system-wide, not game-only.
Battery time is macOS's estimate and can take time to adjust after starting a game;
`…` means the OS has no estimate, and `—` means a metric is unavailable.

Build Recall normally as described above. Test a fullscreen match at 16:9 and
16:10, switch Spaces, alt-tab, toggle it during a match, and confirm clicks/aim
still pass through the strip. Layout previews alone cannot establish in-game
window ordering or input behavior.

Reader edge cases, live API smoke checks, and panel show/hide checks:

```sh
mkdir -p build
xcrun swiftc -parse-as-library app/Sources/StatsHUD.swift app/Sources/Localization.swift \
  tests/StatsHUDTests.swift -o build/StatsHUDTests
build/StatsHUDTests
```
