# Building from source

Players don't need any of this. [Download the app](https://github.com/AsherJN/recall/releases/latest)
instead. This page is for developers who want to rebuild the runtime or the app.

The release runtime is built from pinned upstream sources by the portable build
scripts, then assembled and signed. The Mac app is built with command-line Swift
tools; no Xcode project is required. The older development-checkout tools in
this tree assume a locally prepared engine and toolchain and are kept for
reference.

## Source identities

| Source | Exact input |
|---|---|
| DXMT | `https://github.com/NerRobDog/dxmt`, commit `c5dc3a0dfe9108e667da43de871324bd298c9c02` |
| DirectX headers | `https://github.com/misyltoad/mingw-directx-headers`, submodule commit `9df86f2341616ef1888ae59919feaa6d4fad693d` |
| NVIDIA NVAPI headers (MIT) | `https://github.com/NVIDIA/nvapi`, DXMT submodule commit `d08488fcc82eef313b0464db37d2955709691e94` |
| Wine | `https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz`, `sources/wine` subtree |
| Engine recipe reference | Soju commit `3a350b32bf906dd2a509b18c642a5a2676de022a`, `engine-v1.5` |
| LLVM / Windows compiler | LLVM 15.0.7 x86_64; llvm-mingw 20251216 UCRT macOS universal |
| Other build tools | Bison 3.8.2, Python 3.10+, Meson/Ninja, Apple Command Line Tools (macOS 26.5 SDK) and Metal compiler |

Initialize DXMT at its exact commit and initialize the pinned DirectX and NVAPI
headers submodules. Apply, once each and in this order, `patches/dxmt-v1-private.patch`,
`patches/dxmt-v1-performance.patch`, `patches/dxmt-portable-metal.patch` and
`patches/dxmt-metalfx-upscaling.patch`.
Extract the Wine source and apply, once each and in this order,
`patches/wine-v1-canvas.patch`, `patches/wine-mouselook.patch`,
`patches/wine-portable-directory-boolean.patch`, Soju's
`ncrypt-persisted-keys.patch`, `patches/wine-server-registry-save.patch`,
`patches/wine-ntdll-syscall-log.patch`, `patches/wine-win32u-display-log.patch`
and `patches/wine-winemac-activation.patch`. `build_portable_dxmt.py` and
`build_portable_runtime.py` apply them for you and check each one's SHA-256.
The two `v1` filenames identify the complete integration patches; do not layer
older candidate patches on them.

Xcode 27 installs the Metal compiler as a separate download
(`xcodebuild -downloadComponent MetalToolchain`). `scripts/portable_metal.py`
compiles DXMT's shaders from standard input so no build path ends up in the
compiled shader. Without the Metal toolchain, `DXMT_METAL_CACHE` can name a
folder of outputs made earlier through the same wrapper from byte-identical
shader sources (`<sha256 of input>.air` and `.metallib`); a missing entry stops
the build.

NVIDIA's loader, part of the game, loads DXMT's DLSS stand-in (`nvngx.dll`) only
when it carries an Authenticode signature, and never checks who signed it.
`build_portable_dxmt.py` signs it with the certificate in `runtime/signing/recall-nvngx`;
make your own once with `python3 scripts/sign_pe.py create-certificate
runtime/signing/recall-nvngx` (it needs OpenSSL 3). Keep the keys out of git.

From each clean source directory, use `git apply --check` before applying the
corresponding patch. Absolute patch paths are supported. The publisher's source
preview verification checks the patches against their recorded bases. Patch
application is source reconstruction evidence, not a clean full-runtime build.

## Existing development layout

```text
runtime/source/dxmt-ow2/                    pinned patched DXMT
runtime/source/wine-v1/                     patched Wine source
runtime/source-reference/crossover-26.3/    original Mac driver source files
runtime/toolchains/                        isolated compiler and build tools
runtime/soju-engine-dxmt-ow2-v0.2/           reference Wine headers/build tools
runtime/soju-engine-dxmt-local/             separate integration engine
runtime/build/                             generated build outputs
```

`scripts/build_dxmt_local.py --check` lists missing prerequisites without
installing anything. Once the prerequisites are provided, `--configure` prepares
Meson and `--build --jobs 2` builds into `runtime/build/dxmt-local/install`.
This development configuration disables D3D12, NVAPI, and NVNGX in DXMT; the
release build (`build_portable_dxmt.py`) builds NVAPI and NVNGX with the d3d12
stand-in for MetalFX upscaling. No player needs this developer toolchain.

`scripts/build_v1_window_driver.py` builds the Mac driver against the installed
reference engine's ntdll/win32u and ad-hoc signs the development output. It also
regenerates the tracked Wine patch. Run it only in an isolated development
checkout after supplying the documented reference sources. It does not build
the complete Wine engine or create a notarized consumer runtime.

The [pinned Soju build recipe](https://github.com/BCD1210/soju/blob/3a350b32bf906dd2a509b18c642a5a2676de022a/scripts/build-engine.sh)
and [component recipe](https://github.com/BCD1210/soju/blob/3a350b32bf906dd2a509b18c642a5a2676de022a/scripts/get-components.sh)
identify the full-engine starting inputs: Wine 26.3, FreeType 2.13.3, Wine Mono
10.4.1, and the frankea/Whisky v3.1.1 native library archive. Review these scripts
and their GPL-3.0 terms; do not blindly execute an upstream installer against
an existing environment. That archive's exact library/source/license closure
and a fresh full-engine rebuild remain required before binary publication.

## Tests

On macOS with Python 3.10+ and Apple Command Line Tools:

```sh
python3 tests/run_portable.py
python3 scripts/audit_public_source.py
```

The portable selection runs deterministic source/analysis/recovery tests without
the game or Wine runtime. Its process-counter tests compile a small local native
helper; generated files remain ignored. Remaining `test_*.py` modules depend on
installed engines, reconstructed source, historical development shortcuts, or
private measured sessions and are excluded from this portable selection.

Native fixtures under `tests/` extract or compile the relevant upstream source
and need the pinned toolchain/runtime. For example, `tests/fullscreen/run.py
--focus-recovery` exercises the normal presentation path at both resolutions.
The `--overlay` control is a known failing diagnostic, not release acceptance.
No test licenses or distributes Blizzard game files.

## Release build pipeline

Each script prints its options with `--help`. Run them in order from a clean
checkout with Apple Command Line Tools, clang, make, pkg-config and Python 3.10+:

```sh
python3 scripts/build_portable_runtime.py --workspace runtime/phase-2 --download-only
python3 scripts/build_portable_dependencies.py --workspace runtime/phase-2 --jobs 4
python3 scripts/build_portable_runtime.py --workspace runtime/phase-2 --jobs 4
python3 scripts/build_portable_dxmt.py --workspace runtime/phase-2 --jobs 2
python3 scripts/build_portable_setup.py --output runtime/phase-2/native/ow2-setup
python3 scripts/assemble_portable_runtime.py --workspace runtime/phase-2
python3 scripts/build_native_app.py --output runtime/build/Recall.app
python3 -m venv runtime/tools/dmgbuild && runtime/tools/dmgbuild/bin/python -m pip install dmgbuild==1.6.5
runtime/tools/dmgbuild/bin/python scripts/build_release_dmg.py --app runtime/build/Recall.app \
    --output runtime/release/Recall-1.0.0.dmg --identity "Developer ID Application: ..."
```

The DMG opens as a fixed Finder window with the app, an Applications shortcut
and a background drawn by `scripts/dmg_background.swift`. dmgbuild writes that
layout without scripting Finder; `--plain` skips it.

Runtime `phase2-20261007.3` is `phase2-20261007.2` with DXMT built with
`patches/dxmt-metalfx-upscaling.patch` for MetalFX upscaling (`scripts/build_portable_dxmt.py`,
then `scripts/derive_runtime.py --metalfx <DXMT workspace>`): DXMT's five files are
replaced, its `d3d12.dll` stand-in replaces Wine's, and its signed DLSS stand-in
(`nvngx.dll`), its NVAPI stand-in (`nvapi64.dll`) and NVAPI's license
(`licenses/NVAPI-MIT`) are added. Launches leave all three off unless MetalFX
upscaling is on; `nvngx.dll` keeps the signature `build_portable_dxmt.py` gave it.

Runtime `phase2-20261007.2` is `phase2-20261007.1` with only the Mac driver
replaced (`scripts/build_wine_native.py winemac`, then `scripts/derive_runtime.py
--native winemac`), built with the updated `patches/wine-winemac-activation.patch`: with
`WINEMAC_SCREEN_READBACK=1` (Korean account support) it answers screen reads with a
black image.

Runtime `phase2-20261007.1` is `phase2-20261005.1` with Wine's loader and server
re-signed with the microphone entitlement (`com.apple.security.device.audio-input`)
and the game app made again from that loader (`scripts/derive_runtime.py
--microphone`), so Overwatch's voice chat can hear the microphone; unsigned, every
file is unchanged. A full build signs them the same way.

Runtime `phase2-20261005.1` is `phase2-20261004.4` with Wine's controller bus
rebuilt with SDL2 2.32.10 and that SDL2 library added, so Xbox and other
non-PlayStation controllers reach the game: `scripts/build_portable_dependencies.py
--only sdl2`, `scripts/build_wine_native.py winebus`, then `scripts/derive_runtime.py
--controllers`. A full build configures Wine with the same SDL2 and ships it.

Runtime `phase2-20261004.4`, shipped with app 1.1.0, is `phase2-20261004.3` with
the project's license in `licenses/` changed from MIT to the Apache License 2.0 and
its NOTICE (`scripts/derive_runtime.py --relicense`); every other file is
unchanged. Runtime `phase2-20261004.3` is `phase2-20261004.2` with
only the Mac driver replaced (`scripts/build_wine_native.py winemac`, then
`scripts/derive_runtime.py --native winemac`), so the fullscreen canvas takes a
display's own size, such as an ultrawide or 5K monitor's. Runtime
`phase2-20261004.2` is `phase2-20261004.1` with
ntdll replaced and a game app added, so macOS can turn Game Mode on for Overwatch:
`scripts/build_wine_native.py ntdll`, then `scripts/derive_runtime.py --native ntdll
--game-mode`, which makes `lib/wine/game-mode/Overwatch.app` with
`scripts/game_mode_app.py`. `phase2-20261004.1` is `phase2-20261001.2` with every
Mach-O file re-stamped to require macOS 15.0 (`derive_runtime.py --minimum-macos
15.0`); only that field and the signatures differ.

Runtime `phase2-20261001.2`, shipped with app 1.0.0, is `phase2-20260930.1` with
only the Mac driver replaced: `scripts/build_wine_native.py winemac` builds it,
and `scripts/derive_runtime.py --native winemac` swaps it in after checking that
the base runtime ships an earlier build of the same patch, made from the same
original driver. Runtime `phase2-20260930.1` is `phase2-20260927.1` with
the Wine server, ntdll, win32u, the Mac driver, DXMT's four Windows modules and
its Unix library, and `config/dxmt.conf` replaced:
- `scripts/build_wine_native.py wineserver|ntdll|win32u|winemac` builds each
  Wine component from the patched sources with the Phase 2 tree's exact compile
  and link commands and the assembler's packaging; its `--base` mode reproduces
  the shipped file apart from LC_UUID.
- `scripts/build_portable_dxmt.py` builds DXMT with the three DXMT patches,
  the Command Line Tools and the macOS 26.5 SDK (`DEVELOPER_DIR`, `SDKROOT`).
- `scripts/derive_runtime.py --components <DXMT workspace>` checks each build
  against its recorded patch and base file, packages and signs the files the
  way the assembler does, copies the contract's renderer profile and verifies
  that every other file is unchanged.

The build input `phase2-20260927.1` has the same files as
`phase2-20260926.1` (`derive_runtime.py --repackage`). That runtime is
`phase2-20260913.8` with only the Mac driver (`lib/wine/x86_64-unix/winemac.so`)
replaced:
- `scripts/build_mouselook_driver.py` builds the driver from the patched
  sources with the Phase 2 compiler and packaging. Its `--base` mode
  reproduces the previous driver byte for byte.
- `scripts/derive_runtime.py` swaps it in and signs it. It then verifies that
  every other file is unchanged, and writes the new archive and manifest.
  Archives hold only `runtime.json` and the files it lists, and
  `build_native_app.py` refuses an archive that holds anything else.

Signing and notarization need a Developer ID Application identity and a
`notarytool` Keychain profile. Without them, pass `--skip-notarize` to build an
unsigned DMG for local testing only. The Apple support library comes from
Apple's original package and is never modified; its accompanying license ships
with the app.

The public repository is produced from the private engineering checkout by
`scripts/build_public_manifest.py` (reviewed allowlist) and
`scripts/prepare_public_snapshot.py` (hash-pinned export and privacy audit).
