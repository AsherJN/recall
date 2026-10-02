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
