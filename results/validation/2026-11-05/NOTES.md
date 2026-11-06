# Phase 0 validation, 2026-11-05: working notes

Same machine as 2026-11-03 (M3 Pro, built-in display, plugged in), Ghostty `c7f68a7`, SwiftTerm
1.20.0. Every benchmark process ran at nice 5 (inherited from the shell that started them), the
same for every setup. The `ascii` workload is Side's own sources and grew from 34 to 36.3 MB.

## 1. The 2026-11-03 numbers reproduce

`latency.jsonl`, `throughput.jsonl` (3 runs each, interleaved):

- Latency, key written straight to the terminal (the 11-03 method): A 7.2, C 13.8, D 18.6 ms
  median idle (11-03: 6.8, 13.7, 21.9).
- Throughput at 200×60, each setup's own clock: ascii A 31.5 / C 133 / D 214 MB/s, tui 21 / 159
  / 184, scroll 25 / 113 / 171 (11-03: 31.5 / 136 / 222, 21 / 159 / 169, 26 / 113 / 160).

## 2. A real key changes the latency picture

The 11-03 harness never sent a key event. A wrote through SwiftTerm's `send(txt:)`, B and C
wrote to the PTY directly, D called `ghostty_surface_text`: four different paths, none of them
a typed key's. With `TERMBENCH_KEYS=events`, each key is a keyDown posted to the app's queue and
goes through AppKit, the first responder's `keyDown`, `interpretKeyEvents` (each view is an
`NSTextInputClient`, as SwiftTerm's and Ghostty.app's are) and the setup's own key handling.

| Setup | Idle median | Idle p95 | 5 streaming, median |
|---|---|---|---|
| A, SwiftTerm | 16.1 | 21.7 | 18.4 |
| C, libghostty-vt + Alloy prototype | 18.4 | 21.9 | 17.0 |
| D, full libghostty | 23.3 | 28.8 | 22.1 |

A's lead shrinks from ~7 ms to ~2 ms idle; under load C is ahead. The key path costs every
setup ~4.5 ms (event dispatch ~3, the input system ~1.5); A pays ~9 ms. Why SwiftTerm's own
keyDown costs more is not yet established.

## 3. Presenting without waiting for vsync closes C's latency gap

`latency-experiments.jsonl` (real keys, 3 runs, A alongside):

| C variant | Idle | 5 streaming |
|---|---|---|
| base (CAMetalLayer, 2 drawables, vsync) | 18.6 | 19.1 |
| opaque layer | 18.4 | 18.7 |
| 3 drawables | 19.1 | 18.4 |
| `displaySyncEnabled = false` | 6.3 | 6.8 |
| `displaySyncEnabled = false`, opaque | 6.0 | 7.1 |
| A, for reference | 14.8 | 17.3 |

Not yet checked: tearing (none expected in a composited window, still to be looked at frame by
frame), power and frame counts under sustained output, external displays. Ghostty keeps vsync
on by default and documents why (window-vsync in Config.zig): out-of-sync rendering on macOS
14.4+ has caused kernel panics, and issues with DisplayLink-attached displays. Its mechanism
differs from this one: Ghostty renders into IOSurfaces that the main thread sets as a CALayer's
contents, paced by a CVDisplayLink (renderer/metal/IOSurfaceLayer.zig, renderer/generic.zig),
and window-vsync=false stops the pacing. Whether CAMetalLayer's own non-synced presentation
carries the same risk is unknown. A design would want vsync for sustained output and the
immediate path only for the first frame after quiet (a key's echo).

## 4. C's throughput gap is not the lock, the parser or the renderer

- **The lock:** over a whole ascii run the reader waited 2.5 ms for it in total. The 11-03
  write-up's explanation (reader and renderer sharing a lock) is wrong.
- **macOS's PTY:** it hands the master ~1 KB per read (36,456 reads for 36 MB), a limit
  Ghostty's own termio documents and designs around (Exec.zig: a gather thread that drains
  non-blocking and "bridges" refill gaps with up to 16 immediate retries, and a parse thread).
- **Two stages, and bridging, in the harness:** no change. With bridging, batches averaged
  39 KB, but throughput stayed ~140 MB/s on ascii.
- **Each setup's own clock was unfair to short runs:** C and D decide when a run ended
  differently. With the writer's own clock (`TERMBENCH_WRITER_CLOCK`: the time cat starts and
  finishes writing), tui is a tie: C 196, D 199 MB/s. ascii stays C ~145, D ~228.
- **The ascii gap is in the harness's host, not in libghostty-vt:** with parsing turned off
  (`TERMBENCH_NOPARSE`), C's process still reads the PTY at only ~150 MB/s against D's ~230.
  A standalone C program (PTY, cat, libghostty-vt, no window) reads and parses at ~165 MB/s, and
  reads unparsed at 162–184 (blocking) or 181–202 (non-blocking with a spin).
- **Ruled out for the host gap:** the child's QoS class, `login` in front of the command, and
  PTY modes (`stty -a` is identical but for `iutf8`, an input flag).
- **Still open:** what in the harness process holds the PTY to ~150 MB/s.

Side's terminals are read by the keeper, not by the app. The number that decides the design is
the keeper in the loop, next.

## 5. The keeper in the loop (`../2026-11-05-keeper/`)

Every command runs behind Side's real `SideSessionKeeper` (release build), through
`Keeper/relay.c`, in every setup alike (marked ′). The relay adds one PTY hop that Side's own
client doesn't have; it's the only way to put the keeper in front of full libghostty, whose
embedding API at this commit runs a command in a PTY of its own and can't be fed bytes. Behind
the keeper, the writer's clock times only the keeper (it buffers for its client), so each
setup's own end-to-end clock is used. Final screens were checked by screenshot.

Throughput, MB/s, 200×60, 3 runs: ascii A′ 30 / C′ 101 / D′ 96, scroll 24 / 91 / 89, tui 20 / 91
/ 100. The keeper caps C′ and D′ alike at ~100 MB/s; process CPU C′ 0.13–0.32 s, D′ 0.23–0.65 s.

Latency, real keys, ms: idle A′ 15.4–15.8, C′ 16.4–18.4, D′ 23.6; with 5 streaming A′ 18.0–18.5,
C′ 16.9–17.4, D′ 22.2. C′ without vsync: 7.7 idle (p95 11.5), 8.3 with 5 streaming (p95 13.2).
The keeper adds under 1 ms to any setup.

## 6. The Phase 0 gate (Side's terminal engine RFC)

- Latency at or below A′ with p95 under 17 ms: **met** by C′ without vsync (7.7 / 11.5 against
  A′ 15.4 / 22.2); **not met** with vsync (18.4 against 15.4).
- Throughput within 15% of D′: **met** (behind the keeper, within noise on all three).
- CPU and memory no worse than 11-03's C: CPU met; six and 24 sessions were not re-run.
- Not done: a real Claude Code capture (needs a recording; `Capture/pace.c` replays one).

## 7. A real Claude Code session (`../2026-11-05-capture/`, `scripts/replay.sh`)

**macOS changed between sections 6 and 7.** The Mac updated from macOS 26.4.1 (Xcode 26) to
27.2 (Xcode 27.2, which needs the Metal Toolchain downloaded to build SwiftTerm's shaders).
Everything in this section ran on 27.2; nothing above was re-run on it, so don't compare across
the two without re-running.

**The recording.** It's the owner's own session: 45 minutes of `claude` under `script -r`. It
holds a real conversation, so it stays out of git; only numbers are committed. Its output:
- **Volume:** 2.6 MB in 21,280 writes of a median 93 bytes (max 1,024). In the seconds with
  output, the median rate is 1 KB/s, the p95 3 KB/s and the peak 30 KB/s.
- **Shape:** nearly every write is a synchronized update (DEC 2026, 19,222 times), with the cursor
  hidden, and truecolor text throughout (37,220 SGR 38;2). Bulk throughput is irrelevant to this
  workload; what each update costs, and keypress latency, are what matter.

**C now honors synchronized output.** The 11-03 prototype ignored DEC 2026 and would draw
half-finished frames. It now uses libghostty-vt's render-hold callback, keeping the frame from
when a hold began until it ends, with a 1 s limit, as render.h describes. SwiftTerm and Ghostty
both honor the mode. `TERMBENCH_NOHOLD=1` gives the old behavior; on this recording the frame
counts hardly differ, because holds are shorter than a frame.

Final screens of a replay through C and D were compared by screenshot and match.

**All runs below were behind the keeper**, 3 runs each, interleaved; the load average was 5–8
throughout (a system service was busy after the update).

**Full speed (`pace --fast`):** each setup takes 74–78 ms for all 45 minutes of output, about
32 MB/s for every setup. That's the cost of writing 21,280 small records through the keeper,
not of the terminals.

**Six sessions, each replaying the recording, one shown (CPU s, footprint):**

| | Real pace, 60 s | | | 10× pace, 20 s | | |
|---|---|---|---|---|---|---|
| | Process | Main | MB | Process | Main | MB |
| A′ SwiftTerm | 7.27 | 6.28 | 227 | 5.88 | 5.14 | 228 |
| C′ libghostty-vt + Alloy | 1.62 | 0.80 | 182 | 2.62 | 0.90 | 183 |
| D′ full libghostty | 3.46 | 1.93 | 324 | 3.87 | 0.99 | 327 |

At real pace, C′ uses 22% of A′'s CPU and 47% of D′'s. A′'s main thread is busy 10% of the time
with six Claude sessions doing nothing unusual. C′ drew 396 frames in that minute (only the
shown session draws).

**Latency, real keys, ms (median; p95):**

| | Idle | 5 replaying at real pace |
|---|---|---|
| A′ | 8.9; 16.7 | 9.2; 17.0 |
| C′ | 15.8; 20.6 | 15.6; 20.9 |
| C′, `displaySyncEnabled = false` | 3.5; 12.3 | 3.5; 8.6 |
| D′ | 20.3; 28.2 | 20.8; 27.5 |

On 27.2, SwiftTerm's key path is much faster than on 26.4.1 (8.9 against 15.4 ms behind the
keeper); C's and D's moved by under 3 ms. Why is not established.

**The gate on real output:**
- With vsync, C′ fails latency clearly (15.8 against 8.9 ms).
- Without vsync, it passes everything: latency 3.5 ms (p95 8.6 under load), CPU at a fifth of
  SwiftTerm's, and the least memory.
- Presenting without vsync is therefore the condition of the whole design, and its safety
  (section 3) is now the deciding open question.

**Reproduced from a clean clone of the public repo** (github.com/gazishahi/side-terminal-bench at
d136d8e, empty Zig cache, `SOURCE` = Alloy's public sources), without the keeper, same recording,
same Mac, the same evening. Ghostty built in 4 minutes; every workload but `ascii` was byte-identical
to ours. Results, median of 3 runs:
- **Six sessions at real pace, 60 s:** A 7.00 s CPU (6.12 main), C 1.26 s (0.70), D 3.12 s (1.85);
  226 / 182 / 323 MB. The same order and nearly the same ratios as behind the keeper.
- **Latency, real keys, idle:** A 8.0, C 18.6, C without vsync 3.5, D 20.8 ms. With five
  replaying: 8.0 / 18.0 / 4.3 / 20.6. C with vsync is about 3 ms slower here than behind the
  keeper (15.8); the conclusion doesn't change.
- `summarize-validation.py` didn't read replay results; it does now (full.jsonl and sessions.jsonl).

## 8. Latency on the display, not the window (`../2026-11-05-clock/`, `scripts/latency-clock.sh`)

**Every latency number above used a clock that can't see the screen.** The harness stopped the
clock when `CGWindowListCreateImage`, capturing the window alone, first showed the key's glyph.
That capture returns the window's newest contents whenever it's asked; it doesn't wait for the
window server to composite them into a display frame. So it under-counts any setup whose content
reaches the window server before the next composite, and the under-count differs by setup.

**The display clock** (`TERMBENCH_CLOCK=display`, `DisplayClock.swift`) uses ScreenCaptureKit on
the display and stops at the display time of the first composited frame (SCStreamFrameInfo
`displayTime`) that shows the glyph. Scan-out and the panel come after it and are the same for
every setup. It needs Screen Recording permission, which a terminal inside Side doesn't get (the
keeper copy is the responsible process), so these ran from Terminal.app.

Both clocks, interleaved, macOS 27.2, built-in XDR display at 120 Hz, no keeper, real keys, five
hidden sessions replaying the recording at real pace for "loaded"; ms, median of 3 runs (p95):

| | Window, idle | Display, idle | Window, loaded | Display, loaded |
|---|---|---|---|---|
| A SwiftTerm | 7.7 (13.0) | 16.4 (20.4) | 8.2 (15.2) | 16.6 (24.2) |
| C, vsync | 16.9 (21.6) | 14.5 (18.5) | 17.4 (20.6) | 14.3 (18.5) |
| C, `displaySyncEnabled = false` | 4.2 (8.4) | 10.2 (21.7) | 4.0 (8.6) | 11.0 (22.4) |
| D full libghostty | 21.3 (27.2) | 24.7 (34.0) | 21.9 (26.5) | 23.4 (34.4) |

- **On the display, C with vsync is ahead of SwiftTerm** by about 2 ms, idle and loaded. The
  window clock had SwiftTerm 9 ms ahead: its CoreText view's content is visible to a window
  capture about 9 ms before it's on the display.
- **Presenting without vsync gains about 4 ms on the display, not 12.** Its frame still waits for
  the next composite; its p95 is no better than with vsync.
- **C's lead over D holds on both clocks** (10 ms on the display).
- The window clock read C with vsync about 2 ms *later* than the display did; the capture loop's
  own cost (a capture every 0.25 ms) is the likely cause. It doesn't change any order.

**`CAMetalDisplayLink`** (`TERMBENCH_EXP=metaldl`, keeping vsync and drawing into the link's
drawable with `preferredFrameLatency` 1 or 2) measured 38 ms on the display, idle and loaded.
That's a first, untuned implementation (it draws only on the link's callbacks), not a verdict
on the API.

**So the Phase 0 latency gate is met with vsync**, on the display clock. Presenting without
vsync is an optional 4 ms, not the condition of the design, and its risks (section 3) no longer
need settling before a decision. Earlier sections' latency numbers stand as window-clock
measurements, comparable with each other but not with the display.

## 9. 24 sessions behind the keeper (`../2026-11-05-scaling/`, `scripts/scaling-keeper.sh`)

Every session behind its own keeper (relay, marked ′), one shown, 200×60, macOS 27.2, 3 runs
interleaved. "Burst" is the 11-03 scaling load (`tui-burst.bin` looped, ~260 KB/s per session,
~12 s); "real" is the recording at real pace for 60 s. CPU s process (main), the harness's
footprint MB, and the keepers' summed RSS sampled near the end (the same keeper for every setup):

| | Burst, 1 | Burst, 6 | Burst, 24 | Real, 24, 60 s | Footprint at 24 (burst / real) |
|---|---|---|---|---|---|
| A′ SwiftTerm | 1.84 (1.73) | 2.87 (2.42) | 4.77 (3.69) | 9.60 (8.17) | 88 / 241 MB |
| C′ libghostty-vt + Alloy | 0.44 (0.24) | 0.64 (0.23) | 0.79 (0.16) | 1.81 (0.74) | 178 / 201 MB |
| D′ full libghostty | 0.75 (0.33) | 1.12 (0.26) | 1.60 (0.18) | 4.42 (1.71) | 763 / 742 MB |

Keepers: 8 MB for one, 48 MB for six, 190 MB for 24 (burst) and 205 MB (real), about 8 MB each.

- **The 11-03 scaling result holds behind the keeper.** From 1 to 24 sessions C′'s CPU grows
  1.8×, D′'s 2.1× and A′'s 2.6×; at 24, C′ uses half of D′'s CPU and a quarter of its memory
  (11-03 without the keeper: C 1.04–1.10 s, D 1.86–1.89 s, 178 against 738–761 MB).
- **On real output at 24 sessions, C′ uses 19% of SwiftTerm's CPU and 41% of full libghostty's.**
  SwiftTerm's main thread is busy 14% of the time with 24 idle-ish Claude sessions.
- **Side's whole cost at 24 sessions** is the app plus the keepers: about 405 MB for C′ against
  about 950 MB for D′ (real output, footprint plus keeper RSS; the two are measured differently,
  so treat the sum as approximate).
- Two runs (6 sessions, C′ and D′, run 2) printed no result; the medians at 6 use the other two
  runs. Six reruns of exactly those cases were all clean; the cause isn't known.

## 10. Where Ghostty's design should win (`../2026-11-05-robustness/`, `scripts/robustness.sh`)

Three tests of what Ghostty's architecture buys, macOS 27.2, no keeper, 3 runs interleaved.
`C-renderthread` (`TERMBENCH_EXP=renderthread`) draws on a thread of its own, as Ghostty does,
instead of the main thread; its final frames match C's pixel for pixel. The harness's copy of
Alloy's glyph atlas drops `@MainActor` for it: Alloy itself can't render off the main thread yet.
`TERMBENCH_PROBE=1` measures how long a no-op handed to the main queue every 2 ms waits to run.

**1. A busy main thread** (`TERMBENCH_MAIN_BUSY`: the main thread kept busy 5 or 10 ms, 60 times a
second, standing in for the app's UI). Latency, display clock, real keys, idle, median ms (p95):

| | Not busy | 5 ms busy | 10 ms busy |
|---|---|---|---|
| A SwiftTerm | 16.9 (22.8) | 14.9 (16.7) | 17.0 (27.1) |
| C, main thread | 15.0 (18.4) | 11.6 (17.2) | 12.9 (16.3) |
| C, render thread | 14.2 (18.4) | 11.4 (17.2) | 13.1 (15.8) |
| D full libghostty | 23.8 (33.8) | 26.5 (32.0) | 23.0 (36.1) |

No setup got materially slower, and the order held. Busy work every frame may also keep the CPU's
clocks up, which would explain the faster busy runs; this load is periodic and gentle, and a
burstier one could tell a different story.

**2. Main-thread stalls while output streams** (main-queue wait, ms, median of runs):

| | tui p50 / p99 / max | scroll max | 6 sessions at 10× (max) | Main CPU, sessions |
|---|---|---|---|---|
| A SwiftTerm | 1.2 / 9.0 / 42.5 | 16.1 | 26.6 | 5.50 s |
| C, main thread | 13.6 / 46.3 / 46.3 | 17.3 | 14.4 | 1.06 s |
| C, render thread | 0.01 / 0.2 / 0.2 | 0.2 | 0.6 | 0.31 s |
| D full libghostty | 0.01 / 0.13 / 0.13 | 0.2 | 0.5 | 1.07 s |

**Drawing on the main thread is a real flaw.** Under bulk output C's main thread waited a median
13.6 ms and up to 46 ms (most likely in `nextDrawable`, waiting for one of two drawables; not yet profiled), which would
freeze Side's whole UI. On its own thread, like D, the longest wait was 0.2 ms in bulk and 0.6 ms
across six sessions. (The first sessions run of `C-renderthread` drew no frames, since sessions
mode drew only on the display-link tick; those rows were replaced after the fix.)

**3. Does the latency lead survive a render thread?** Yes: 14.2 ms against C's 15.0 and D's 23.8
(test 1, not busy). Throughput also rose (tui 171 against 147 MB/s, scroll 121 against 106), and
process CPU in six sessions was about the same (3.5 s).

**So:** the engine must draw on its own thread, and Alloy must support that before it can render
the terminal. The latency lead over D doesn't come from drawing on the main thread; where D's
extra ~10 ms goes is still unexplained until D is profiled.

## 11. Where full libghostty's extra latency goes (`../2026-11-05-stages/`, `scripts/stages.sh`)

`TERMBENCH_STAGES=1` timestamps each key's path in-process (SIP rules out system tracing): when
the view got the key, when the key was sent, and every frame handoff to Core Animation (C's
Metal present; for D, an IOSurface set as a layer's contents, caught by hooking
`-[CALayer setContents:]`). The display clock gives the frame on the display; the frame shown is
the last handoff before it. Real keys, idle, macOS 27.2 at 120 Hz, 3 runs; ms from the key,
median:

| | Key sent | First handoff | Handoff of the shown frame | On the display |
|---|---|---|---|---|
| C, main thread | 0.6 | 1.1 | 1.1 (1 frame) | 14.5 |
| C, render thread | 0.6 | 1.1 | 1.1 (1 frame) | 14.5 |
| D full libghostty | 0.5 | 3.2 | 13.8 (2 frames) | 23.8 |
| D, `window-vsync = false` | 0.5 | 3.2 | 4.5 (2 frames) | 16.9 |

**D draws a frame without the echo first, and the echo waits for the next display-link tick.**
With vsync, Ghostty's render thread updates its cells as soon as it's woken but draws only when
the display link fires (`renderer/Thread.zig`, `drawFrame`: with vsync it draws only "when we're
forced to via `now`"). Each key here produced two frames: one at 3.2 ms that didn't change the
echo cell (the display clock didn't see it), and the echo's at 13.8 ms, about one 120 Hz refresh
plus the main-thread hop later. C draws when output arrives, so the echo's frame is handed off at
1.1 ms. That accounts for about 10 of D's extra ms.

- **Turning Ghostty's vsync off** removes most of it: the echo's frame goes at 4.5 ms and the
  display at 16.9 ms, 2.4 ms behind C. Ghostty documents that setting as its latency knob.
- **From handoff to display**, C's Metal present took 13.4 ms and D's IOSurface handoff 10.0 ms
  (12.4 without vsync). That looked like 3 ms for C to win back; section 12 tested it, and it
  isn't there.
- What makes D draw the first frame (the key itself, or something it changes) isn't established;
  `keyCallback` queues renders on some paths.

So the lead is a scheduling difference, not rendering speed: C draws when the echo arrives, D on
the display link's next tick. It's a design choice Ghostty could make differently, which makes it
a fair point to raise with its author rather than a claim that its renderer is slow.

## 12. Ghostty's frame handoff, tried in C (`../2026-11-06-stages/`, `scripts/stages.sh`)

`TERMBENCH_EXP=iosurface` hands C's frames over as Ghostty does: rendered into one of three
IOSurfaces, then set as a plain layer's contents on the main thread once the GPU is done (top-left
gravity, no implicit animation), instead of presenting a CAMetalLayer drawable. Same stage run as
section 11, 3 runs, median ms from the key:

| | Handoff | On the display | Handoff to display |
|---|---|---|---|
| C, Metal present, main thread | 1.1 | 15.0 | 13.9 |
| C, Metal present, render thread | 1.1 | 14.3 | 13.2 |
| C, IOSurface, main thread | 2.6 | 15.6 | 13.0 |
| C, IOSurface, render thread | 2.6 | 15.1 | 12.6 |
| D full libghostty | 13.1 | 23.4 | 10.3 |
| D, `window-vsync = false` | 4.4 | 16.0 | 11.6 |

**No gain: on the display the IOSurface handoff is the same or up to 0.8 ms slower.** Section 11
compared handoff points that don't mean the same thing. C's "present" is marked when the command
buffer is committed, before the GPU has drawn; an IOSurface handoff comes after the GPU is done
and a main-thread hop, so it's later by construction, and the time after it is shorter. D's
shorter handoff-to-display also has a reason of its own: it draws on display-link ticks, so its
handoffs land at a fixed point in the refresh, while C's land wherever the echo does and wait,
on average, part of a refresh longer. The way the frame is handed over isn't where any of the
latency is; when the frame is drawn is.

## 13. What draws full libghostty's frame before the echo (`../2026-11-06-ghostty-redraw/`, `scripts/ghostty-redraw.sh`)

Two places in Ghostty ask for a render as soon as a key is pressed, before its echo is back:
- `Surface.zig`, end of `keyCallback`: every non-modifier keypress that sends bytes clears the
  selection, scrolls to the bottom and calls `queueRender()`.
- `termio/Thread.zig`, `drainMailbox`: the IO thread wakes the renderer after draining any
  message ("If we have a message we always redraw"), and the key's write is a message.

With vsync, the render thread draws that state on the next display-link tick, without the echo;
the echo's state then waits for the tick after. To test it, `patches/ghostty-no-redraw-before-echo.diff`
drops the two renders in a copy of the pinned Ghostty (the stock build is untouched). Stage profile,
display clock, real keys, idle, 3 runs, median ms:

| Full libghostty | Frames per key | Echo's frame handed off | On the display |
|---|---|---|---|
| Stock, vsync | 2 | 13.8–13.9 | 23.6–26.2 (two batches) |
| Keypress render dropped only | 2 | 14.0 | 23.7 |
| Both dropped, vsync | 1 | 3.5 | 16.6 |
| Stock, `window-vsync = false` | 2 | 4.4–4.5 | 16.7–17.1 |
| Both dropped, `window-vsync = false` | 1 | 3.5 | 16.2 |

- **Dropping both removes the extra frame and 7–10 ms**; with vsync, Ghostty then matches its own
  no-vsync latency. Dropping only the keypress's render changes nothing, so the IO thread's
  redraw is enough on its own to cause it. Whether the keypress's render alone would also
  cause it wasn't tested.
- **The patch is a diagnostic, not a fix.** Those renders are there for reasons: clearing a
  selection or scrolling to the bottom must show even when nothing echoes (a password prompt),
  and other mailbox messages change what's drawn. A real fix would keep them but stop a render
  that changes nothing visible from taking the display link's tick ahead of the output that's
  about to arrive.
- With the extra frame gone, Ghostty with vsync (16.6 ms) is within about 2 ms of C (14.3–15.0).
  What remains of C's lead is small, and it isn't explained yet.
