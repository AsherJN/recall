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
matches. `WINE_SYSCALL_LOG` and `WINE_IO_ERROR_LOG` are developer diagnostics
(off unless set).

`wine-win32u-display-log.patch`: `WINE_DISPLAY_LOG` records each forced
display-device update with its reason and duration (off unless set).

`wine-winemac-activation.patch` applies to the Mac driver after the two driver
patches above:
- macOS announces the game as active again on every left click; the driver
  re-reads the display list only after the game had actually been inactive, so
  clicks no longer cost a frame;
- the fullscreen letterbox bars stay black, and on a 1x external monitor the
  drawable is capped at the monitor's own pixels;
- when the game moves or resizes its window in fullscreen, the driver answers
  with the fullscreen frame, so the pointer, the communication wheel and menu
  clicks stay lined up with what is drawn;
- the fullscreen canvas takes 1080p, 1440p and 4K in 16:10 and 16:9 (up to
  3840 × 2400), and each display lists those of them that fit it, so the game
  can choose them on a monitor that lacks the mode; setting the display itself
  to one still fails, and the canvas never changes the display's mode;
- after you switch to another app from the game in fullscreen, the game stays
  minimized and out of fullscreen until you come back to it: on macOS its own
  requests to restore the window or re-enter fullscreen would bring it back to
  the front.
`WINEMAC_INPUT_STATS` writes an input report (off unless set).

Menus, Battle.net and every other program keep the standard behavior.

Apply each patch once, in this order, first using `git apply --check`.
Do not combine them with historical candidate patch variants.
See [build status](../docs/BUILDING.md) and
[third-party notices](../THIRD_PARTY_NOTICES.md).
