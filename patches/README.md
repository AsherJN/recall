# Integration patches

## DXMT

These apply to commit `c5dc3a0dfe9108e667da43de871324bd298c9c02` of
[NerRobDog/dxmt](https://github.com/NerRobDog/dxmt), in this order.

`dxmt-v1-private.patch` is the complete DXMT integration patch: the fullscreen
canvas, presentation and shader/pipeline caching tuned for Overwatch.

`dxmt-v1-performance.patch` is the 1.0 performance work:
- Render targets that Overwatch marks as writable by compute shaders but never
  uses that way keep Apple's lossless compression; the first real use moves the
  texture to a writable copy. Each frame takes about a fifth less GPU time.
- CPU and GPU waits wake exactly when the work is done instead of polling.
- Frame pacing: after the frame-latency wait, the game thread sleeps for most
  of the time the GPU still needs, so the next frame samples input later at
  the same GPU load. It is on only when the renderer profile enables it
  (`dxgi.presentPacing`; the app's profile uses mode 3 with a 1 ms margin).
- Shader variants are prepared when the game creates its shaders
  (`DXMT_PREPARE_SHADERS=1`), and variants that translate to the same code share
  one cache entry.
- Developer diagnostics that stay off unless their environment variable is set:
  a frame log, a call recorder for off-screen replay, and replay tools.

`dxmt-portable-metal.patch` makes both Metal build steps run through
`scripts/portable_metal.py`, which keeps the build machine's paths out of the
compiled shaders.

`dxmt-shader-pack.patch` (1.4) lets the shader pack hold every pipeline the
game has used on the Mac. The pipeline cache keeps learning until the disk is
nearly full, with no size limit of its own; it checks each archive in 1 MiB
pieces instead of reading it into memory whole; and Recall's preparation tool
can add a batch of pipelines as one more archive (`DXMT_PIPELINE_CACHE_APPEND`)
instead of rebuilding the pack, so preparation after a session can be stopped
and resumed without losing finished work. A game checks the archives on all cores
at once and loads them in order, slowest pipelines first, as much as Recall's
Shader memory setting allows (`load.json` beside the pack: all of it unless the
player chose less), and keeps loading past its startup deadline; only the
preparation tool adds to the pack.

`dxmt-metalfx-upscaling.patch` is MetalFX upscaling (1.3): with Recall's
MetalFX upscaling setting on, Overwatch offers NVIDIA DLSS, which runs on
Apple's MetalFX temporal upscaler.
- The adapter and NVAPI report one NVIDIA GeForce RTX 4090, so the game offers
  DLSS. This happens only when `DXMT_ENABLE_NVEXT=1`; the stand-ins refuse to
  load otherwise.
- DXMT's DLSS stand-in (`nvngx.dll`) gains Direct3D 12 entry points that report
  "not supported" and NVIDIA's own failure codes. A `d3d12.dll` stand-in answers
  the setup questions of NVIDIA Streamline (shipped with the game), which builds
  a Direct3D 12 helper even in Direct3D 11 games; it creates nothing and refuses
  feature level 12_2, so the game stays on Direct3D 11.
- The DLSS output is made shader-writable before MetalFX writes it (see the
  compression change in `dxmt-v1-performance.patch`).
- Jittered motion vectors, which MetalFX cannot cancel, lose the change in
  jitter since the last frame in a small compute pass, as AMD FSR 2 does.
- The DLSS mode the player chooses is the lowest render size the stand-in
  offers.
- Optional sharpening after MetalFX (`d3d11.metalfxSharpness`, 0 to 1), with
  the method of AMD FidelityFX RCAS on tone-mapped values.
- Both compute passes are compiled by macOS at run time, so DXMT's precompiled
  shaders are unchanged.

`build_portable_dxmt.py` signs the built `nvngx.dll` (Authenticode, SHA-256)
with `scripts/sign_pe.py`: NVIDIA's loader, part of the game, loads only a
signed core DLL.

## Wine

These apply to the `sources/wine` subtree of the
[CodeWeavers Wine 26.3.0 source archive](https://media.codeweavers.com/pub/crossover/source/crossover-sources-26.3.0.tar.gz),
in this order, with `wine-portable-directory-boolean.patch` and Soju's
`ncrypt-persisted-keys.patch` after the second.

`wine-v1-canvas.patch` preserves the fullscreen and focus integration of the
Mac driver.

`wine-mouselook.patch` adds mouselook with raw mouse input for games listed in
`WINEMAC_MOUSELOOK`; the app lists `Overwatch.exe`. While such a game hides and
confines its cursor:
- the Mac pointer is frozen;
- mouse motion reaches Wine as raw mouse counts from Apple's Game Controller
  framework, at the mouse's full report rate, as on Windows;
- trackpads keep macOS pointer events.

`wine-server-registry-save.patch`: the Wine server writes its periodic registry
save from a forked copy of itself, so the game no longer pauses for about a
tenth of a second every 30 seconds. `WINESERVER_REGISTRY_LOG` names every change
to a saved key (off unless set).

`wine-ntdll-syscall-log.patch`: a DLL's Unix library is loaded without holding
Wine's virtual-memory lock, which removes the 150–400 ms freezes that hit during
matches. From 1.1, the programs named in `WINE_GAME_MODE` (Recall sets
`Overwatch.exe`) start from the engine's game app,
`lib/wine/game-mode/Overwatch.app`: a copy of Wine's loader in a bundle that
declares itself a game, which is what macOS needs to turn Game Mode on.
`scripts/game_mode_app.py` makes it. A thread's alert index under msync is no
longer closed as if it were a file descriptor when the thread exits: that closed
whichever file the process had under the same number, often one of Overwatch's
game archives, whose next read then failed and crashed the game (issues #40 and
#50). `WINE_SYSCALL_LOG` and `WINE_IO_ERROR_LOG` are developer diagnostics (off
unless set).

`wine-win32u-display-log.patch`: `WINE_DISPLAY_LOG` records each forced
display-device update with its reason and duration (off unless set). The
programs named in `WINE_APP_DPI` get their own DPI for the system and every
monitor, as Windows programs do at that scaling; everything else, and Wine's
shared record of the displays, keeps the session's DPI. Wine's Retina mode
shows each Windows pixel at half a point on every display, so Recall names
Battle.net's programs at 192, the size Battle.net has on Windows at 200%, while
Overwatch sees 96 as before. From 1.6 Recall turns Retina mode on only when the
main display is a Retina one; without it each Windows pixel is a point and
Battle.net keeps 96.

`wine-winemac-activation.patch` applies to the Mac driver after the two driver
patches above:
- macOS announces the game as active again on every left click; the driver
  re-reads the display list only after the game had actually been inactive, so
  clicks no longer cost a frame;
- mouse buttons delivered to an active fullscreen canvas stay with Wine,
  including their following drag and release events. Passing those events to
  AppKit a second time could replace the game's cursor with the macOS pointer
  and enter native window-move handling. Background activation, Command-clicks,
  titlebar controls and windowed games keep their native behavior;
- the fullscreen letterbox bars stay black, and on a 1x external monitor the
  drawable is capped at the monitor's own pixels;
- when the game moves or resizes its window in fullscreen, the driver answers
  with the fullscreen frame, so the pointer, the communication wheel and menu
  clicks stay lined up with what is drawn;
- the fullscreen canvas takes 1080p, 1440p and 4K in 16:10 and 16:9 (up to
  3840 × 2400), and each display lists those of them that fit it, so the game
  can choose them on a monitor that lacks the mode; setting the display itself
  to one still fails, and the canvas never changes the display's mode;
- it also takes any larger resolution that fits inside a display, such as an
  ultrawide or 5K monitor's own size (5120 × 2160, 5120 × 2880), which the game
  offers in its Video settings; the game had drawn those inside a 16:9 frame
  with black bars on all four sides;
- after you switch to another app from the game in fullscreen, its window stays
  in its fullscreen space until you come back, as a Mac fullscreen app's does.
  The game still minimizes itself, as on Windows, but its window is neither taken
  out of fullscreen nor sent to the Dock, and coming back restores the game and
  makes it the active window at once, so it takes the mouse and keyboard again
  without macOS's fullscreen and Dock animations. While you are away, the game's
  requests to restore the window or re-enter fullscreen are held, since on macOS
  they would bring it back to the front. If the window does leave fullscreen in
  the background, a minimize asked for while macOS is still animating waits for
  the animation to end, which would otherwise bring the window back. A game window
  that Wine counts as minimized but that is still on screen is restored when you
  come back to it; otherwise its picture stayed frozen and it ignored input;
- when the game leaves fullscreen for a window or borderless, its picture is laid
  out as Wine has the window then; restoring the layout from before fullscreen
  had left the picture too small or too large in the window, with clicks missing
  what they were aimed at;
- while a window covers a whole screen (a borderless game) and the game is the
  active app, the menu bar and Dock are hidden, as Windows keeps the taskbar
  under a borderless game;
- with Korean account support on (`WINEMAC_SCREEN_READBACK=1`, which the app sets on the Korea region),
  reading the screen back (BitBlt or StretchBlt from the screen) gives a black
  image instead of failing, so the anti-cheat in the Korean build of Overwatch
  no longer crashes the game when it takes a screenshot. No pixels are read;
  without the variable the call fails as before;
- with `WINEMAC_INPUT_VARIANT=precise`, which the app sets from 1.5:
  - mouse buttons come from the Game Controller framework's mouse input, as the
    motion does, and each one reaches the game after the motion that came before
    it, as on Windows. macOS's own copy of each click held it until the next
    display refresh, so shots during a flick landed past where the player clicked;
  - moves carry the time they were delivered and go out as soon as a millisecond
    has passed since the last delivery;
  - if the Game Controller mouse input goes quiet, pointer events stand in at the
    mouse's own scale, and its handlers are set again. A trackpad alone keeps the
    pointer's scale, so it can aim too.

  Without the variable, input behaves as in 1.4.
- with `WINEMAC_INPUT_VARIANT=classic`, which the app sets for its Classic mouse
  from 1.6, clicks and timing are as in 1.4, and pointer events stand in while the
  Game Controller mouse input is quiet, as with `precise`;
- with `WINEMAC_RAW_SOURCE=hid`, which the app sets for its High-precision mouse
  from 1.6, the mouse's movement and buttons come from its own reports through
  IOHID instead of the Game Controller framework, which drops some of them in game.
  It needs the app's Input Monitoring permission and never asks for it itself. It
  opens only devices with a mouse collection, trackpads excepted, and reads only
  their X, Y and button elements, never keys. Their input reaches the game only
  while macOS still gives the game mouse input of its own, so the camera never
  turns while another app has the mouse. When macOS's own input is only late, the
  movement in between is held for up to half a second and delivered when it
  arrives. Without the permission or a mouse, the
  Game Controller input stays;
- Korean and other input methods get each key after the window's input context
  is made the current one, so typing in the game's chat works (contributed by
  @sookcha);
- a keyboard layout chosen in macOS while the game or Battle.net runs
  (Control-Space, the Globe key, the input menu) reaches it: the driver follows
  macOS's notice of a new selection, and checks again when the program becomes
  active, instead of waiting for the window's input context to be the current one,
  which in game it often is not. Keys held during a switch are released, so none
  stays down.
`WINEMAC_INPUT_STATS` writes an input report (off unless set).

Menus, Battle.net and every other program keep the standard behavior.

`wine-audio-devices.patch` (1.6) changes Wine's audio device list (`mmdevapi`) and its
Mac sound driver (`winecoreaudio.drv`). Wine listed the Mac's sound devices once, when a
program started, so headphones connected later never reached the game. Now:
- the driver watches Core Audio's device list and default devices; after a change settles,
  `mmdevapi` lists the devices again and tells each program what changed, as Windows does
  (device added, device state changed, default device changed), so a game that follows the
  default device on Windows follows the Mac's choice;
- a stream whose device is removed reports `AUDCLNT_E_DEVICE_INVALIDATED`, as on Windows,
  once the list has been updated, so a program that reopens the default device at once
  gets the new one;
- while the Mac's default microphone is a Bluetooth headset's and the Mac's own microphone
  can hear (lid open), Wine's default microphone is the Mac's own, also when the headset
  connects during play: recording from the headset would switch it to its low-quality
  hands-free mode for all sound. A microphone a program chooses by name is used as chosen.
  `WINECOREAUDIO_TEST_BLUETOOTH_UID` names a device to treat as Bluetooth, for tests.

`wine-service-security.patch` (1.6) changes Wine's service manager (`services.exe`) and its client
(`sechost.dll`):
- a service keeps the security descriptor a program gives it (`SetServiceObjectSecurity`), under
  the service key's `Security` value as on Windows, and `QueryServiceObjectSecurity` returns it;
  a service without one has Windows' default (SYSTEM, Administrators, interactive and service
  users). Wine had discarded descriptors and returned an empty one;
- a program path given with forward slashes (`C:/dir/app.exe`) is kept with backslashes, as programs
  read it back on Windows; arguments are left alone.
Battle.net's update agent checks its helper service on every start. With an empty descriptor or a
forward-slash path it found the helper broken and reinstalled itself (about 14 MB) on the next start,
so every other start downloaded it again.

Apply each patch once, in this order, first using `git apply --check`.
Do not combine them with historical candidate patch variants.
See [build status](../docs/BUILDING.md) and
[third-party notices](../THIRD_PARTY_NOTICES.md).
