# Performance

## Recall vs. CrossOver

Tested on October 2, 2026. Each scenario was played in CrossOver and in Recall,
and every frame each app put on screen was recorded.

### Setup

| | |
|---|---|
| Mac | 14-inch MacBook Pro, Apple M1 Pro, 16 GB memory, macOS 26.6.2, on its power adapter |
| Display | External 144 Hz monitor |
| Apps | CrossOver 26.3 with its default graphics setting (D3DMetal); Recall 1.0 |
| Game settings (both apps) | Fullscreen, 1920 × 1080, Low preset, V-Sync off, Dynamic Render Scale off, frame rate limit 600 |
| Measurement | Every new frame shown on screen, about 2 minutes per run, with loading screens and menus removed |

### Custom match

Custom game 929PJ by [u/Working_Dealer_5102](https://www.reddit.com/r/linux_gaming/comments/1u4oanq/auto_precompile_shaders_for_overwatch_for_peak/),
which moves through each map using every hero's abilities, a demanding scene for
any graphics setup. Loading screens between maps are excluded.

| | CrossOver | Recall | Recall vs. CrossOver |
|---|---:|---:|---:|
| Average FPS | 58.4 | **99.6** | **+70.5%** |
| 1% low FPS | 7.4 | **36.0** | **4.9× higher** |
| 0.1% low FPS | 3.0 | **16.3** | 5.4× higher |
| Median frame time | 14.67 ms | **9.31 ms** | 36.5% shorter |
| 95th-percentile frame time | 27.85 ms | **14.85 ms** | 46.7% shorter |
| 99th-percentile frame time | 56.76 ms | **20.74 ms** | 63.5% shorter |
| Stutters over 50 ms | 39.5 per minute | **2.0 per minute** | **94.9% fewer** |
| Stutters over 100 ms | 37 | **1** | |
| Gameplay measured | 105 s | 89 s | |

### Practice Range

About 2 minutes walking the range, turning the camera and shooting bots.

| | CrossOver | Recall | Recall vs. CrossOver |
|---|---:|---:|---:|
| Average FPS | 84.0 | **120.7** | **+43.7%** |
| 1% low FPS | 26.2 | **55.2** | **2.1× higher** |
| 0.1% low FPS | 6.9 | **28.9** | 4.2× higher |
| Median frame time | 11.59 ms | **7.86 ms** | 32.2% shorter |
| 95th-percentile frame time | 18.63 ms | **11.35 ms** | 39.1% shorter |
| 99th-percentile frame time | 22.52 ms | **14.48 ms** | 35.7% shorter |
| Stutters over 50 ms | 4.2 per minute | **0.5 per minute** | **88.1% fewer** |
| Stutters over 100 ms | 4 | **1** | |
| Gameplay measured | 128 s | 127 s | |

### What the terms mean

- **Average FPS:** frames shown on screen per second.
- **1% and 0.1% low FPS:** the frame rate during the slowest 1% and 0.1% of
  frames. Higher means the worst moments stay smoother.
- **Frame time:** the gap between one frame and the next. The median is the
  typical gap; the 95th and 99th percentiles show how long the slower frames take.
- **Stutter:** a gap of more than 50 ms (or 100 ms) between frames, felt as a hitch.

### Notes on the method

- One run per app per scenario.
- Frame time is not input latency. Mouse-to-screen latency was not measured in
  these runs; the next section explains how each app handles the mouse.

## Mouse input

Overwatch is decided by flicks and tracking, so how the mouse reaches the game
matters as much as frame rate. Recall and CrossOver handle it differently.

| | CrossOver | Recall |
|---|---|---|
| How the mouse is read | Waits for macOS pointer updates | Directly from the mouse |
| Updates per second | 120 | Up to 2,000, depending on your mouse |
| Time from movement to update | About 4.5 ms on average | About 0.26 ms |
| Movement lost when the game re-centers the cursor | Some | None |

**Why it matters.** Like most shooters, Overwatch hides the cursor and snaps it
back to the center of the screen after every mouse movement. In Wine's standard
Mac driver, which CrossOver's published source uses, each of those snap-backs
waits its turn on the Mac's main app thread, which is already busy handling the
mouse. While the mouse moves, that happens about 60 times a second at about 1 ms
each, and the game waits every time. Each snap-back also throws away the mouse
movement that was still queued, so some of your movement never reaches the game.
That is the "my aim is a step behind my hand" feeling.

In testing, CrossOver's frame rate also dropped noticeably whenever the mouse
moved.

**What Recall does instead.** Recall uses the Mac's own mouselook mode, the way
native Mac games do: the cursor is never moved back, so nothing waits and no
movement is thrown away. In engineering tests, the main thread's work per mouse
update fell from 4.1–4.3 ms to 0.03 ms, and the slowest cursor re-centers fell
from 2.5 ms to 0.2 ms. Part of any frame rate dip while turning is the game
drawing new views, which happens in every app.

These figures describe how each driver handles the mouse. They come from
engineering tests of Wine's standard Mac driver and of Recall's, not from the
benchmark runs above.
