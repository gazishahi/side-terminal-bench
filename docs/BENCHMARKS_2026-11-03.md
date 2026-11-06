# Side terminal engine benchmarks

Status: decisions pending — benchmark findings (2026-11-03) for choosing Run's terminal engine; nothing here is built into Side yet.

**Result: libghostty-vt drawn by Alloy (setup C) came out ahead overall.** It used the least CPU of the four, scaled best with many sessions, and drew frames 5–35× cheaper than Side's current CoreText path, ultrawide included. It has two weak spots:
- **Throughput:** full Ghostty (D) is 6–63% ahead of it on bulk output, because C's reader and renderer share a lock.
- **Keypress latency:** today's SwiftTerm view is still the quickest (6.8 ms median idle, against C's 12–14 ms). That gap comes from how frames are presented.

The prototype hasn't been tuned for either yet.

**Corrections, 2026-11-05** (Phase 0 of Side's terminal engine RFC; the runs and notes are in `results/validation/2026-11-05/NOTES.md`). The numbers below reproduce, but three conclusions don't hold:
- **Keypress latency:** no setup here received a real key. A wrote through SwiftTerm's `send(txt:)`, B and C wrote to the PTY and D called `ghostty_surface_text`. With a real keyDown through AppKit and the input system in every setup, idle medians are A 16.1, C 18.4 and D 23.3 ms. SwiftTerm's lead is about 2 ms, not 7, and C is ahead under load. With `displaySyncEnabled = false`, C answers in 6.3 ms; the risks of that are in the notes.
- **Every latency number here is a window-clock number** (corrected later the same day, notes section 8). The clock stopped when a capture of the window alone showed the key, which doesn't wait for the window server's composite. At the composited display frame, on macOS 27.2 with real keys, idle: C 14.5 ms with vsync, A 16.4, D 24.7, and C without vsync 10.2. C is ahead of SwiftTerm with vsync, and skipping vsync gains about 4 ms, not 12.
- **The throughput gap isn't the lock.** C's reader waited 2.5 ms for it over a whole ascii run. macOS hands the master about 1 KB per read, which Ghostty's termio handles with a gather-and-parse pipeline. Even so, that pipeline didn't move C in this harness, and C's process reads the PTY at only about 150 MB/s with parsing turned off. That gap is in the harness's host code, not libghostty-vt, and its cause is still open.
- **Each setup's own clock was unfair to short runs.** On the writer's clock, tui is a tie (C 196, D 199 MB/s). Behind Side's session keeper, as Side really runs, C′ and D′ are equal on every workload (about 90–100 MB/s), capped by the keeper.

**Correction, 2026-11-03.** The first version of this report understated C's work. libghostty-vt's C API caps scrollback at 10,000 bytes by default, which silently overrode the 10,000-line limit, so C kept about 390 rows. Every libghostty-vt result below was re-run with the cap removed. The biggest change: plain text emulator-only went from 856 to 462 MB/s, and C's end-to-end plain-text throughput from 178 to 136 MB/s.

## The question

Run is the stage Side is actually used in, and its terminal is the speed ceiling. The lag that started this was a separate bug: git started on the main thread for every terminal event in a project that isn't a repo, fixed in `270116a`. Profiling also showed that drawing the visible terminal was about 68% of Side's main-thread work. SwiftTerm draws text on the CPU with CoreText, row by row, on the main thread.

Two jobs make a terminal fast or slow: **emulating** (parsing program output into a grid of cells) and **drawing** (turning that grid into pixels). Each setup swaps one or both:

| Setup | Emulator | Drawing | Threads |
| --- | --- | --- | --- |
| **A**, Side today | SwiftTerm 1.20.0 | SwiftTerm's CoreText view | Parse and draw on the main thread |
| **B** | SwiftTerm 1.20.0 | Alloy renderer prototype (Metal) | Parse on a reader thread, draw on main |
| **C** | libghostty-vt | Alloy renderer prototype (Metal) | Parse on a reader thread, draw on main |
| **D** | full libghostty | Ghostty's own Metal renderer | Ghostty's IO and render threads |

B and C share the same renderer, so any gap between them is the emulator. C and D share the same emulator, so any gap between them is the renderer and how it's hosted.

## How we measured

**Machine:** Apple M3 Pro with 18 GB of memory, macOS 26.4.1, plugged in. The built-in 1800×1169 pt Retina display runs at up to 120 Hz (ProMotion). Ghostty was built from `main` (commit `c7f68a7`, 2026-11-03) with Zig 0.17.0 in ReleaseFast. SwiftTerm is 1.20.0, the version Side ships.

**There were five benchmarks:**

1. **Emulator only:** the same bytes fed straight into SwiftTerm and libghostty-vt, with no window or PTY. 200×60 grid, 10,000 lines of scrollback, 16 KB chunks, median of 5 runs.
2. **Throughput, end to end:** a real window, a real PTY, and `cat` of a workload file. Timed from the moment the shell gets its start line until `cat` exits and its output is consumed. Median of 3 runs, with setups interleaved so drift hits all of them alike.
3. **Frame cost:** one frame drawn offscreen at 2×, after a full-screen change and after a one-row change. Snapshot, quad building, encoding and GPU time are measured; 60 frames each. D can't draw offscreen, so it's not in this one.
4. **Six sessions:** six terminals in one window, one shown and five hidden like Side's other Run tabs. Each streams a 13 KB Claude-shaped burst 20 times a second for 10 seconds, about 260 KB/s per session.
5. **Keypress latency:** 60 keys per run, spaced at random 30–70 ms intervals so they don't line up with vsync. The window's echo row is captured from the window server every ¼ ms until it changes; a capture takes 0.16 ms. Run idle and with five hidden sessions streaming; median of 3 runs.

**The six workloads were generated deterministically:**

| Workload | What it is | Size |
| --- | --- | --- |
| ascii | Side's own Swift sources, with CRLF line endings | 34 MB |
| colors | Words, each with a random 24-bit foreground and 256-color background | 32 MB |
| unicode | CJK, Korean, Arabic, emoji (including ZWJ sequences and flags), combining marks | 16 MB |
| cursor | Random cursor jumps with short writes and line erases, plus a clear every ~50 moves | 16 MB |
| tui | A Claude Code–shaped redraw: hidden cursor, boxed region, colored diff stats, spinner and status line | 16 MB |
| scroll | Lines scrolling inside a scroll region, as in `less` or vim | 16 MB |

**Fairness rules:**

- Every setup uses the same font (Menlo 13), colors, grid and command.
- Each window is sized from that engine's own cell metrics, so all four get exactly the same grid.
- The command is `sh -c 'read _; exec cat …'`. The clock starts only when the shell gets its line, so startup isn't counted. That includes Ghostty's `/usr/bin/login` wrapper.
- libghostty-vt runs with grapheme clustering (mode 2027) on, as Ghostty.app does.
- B and C use 10,000 lines of scrollback (for C with libghostty-vt's default 10,000-byte cap removed; see the correction above), and D Ghostty's 10 MB. A keeps the 500-line default Side ships today, which flatters A (see Other findings).
- Every setup's final frame was checked by screenshot before its numbers counted. That caught two invalid runs, both fixed and re-run: a quoting bug that meant D never ran `cat`, and a spinning lock that starved B's frames.

## Throughput

**Ghostty's emulator (C and D) handles 4–17× more output than Side today (A) in a real window.** On bulk output, D runs near the PTY's ceiling of about 200 MB/s, and C up to 160 MB/s. Moving SwiftTerm off the main thread (B) barely helps it: SwiftTerm's parse is the limit, not where it runs.

End to end at 200×60, in MB/s (median of 3):

| Workload | A (Side today) | B | C | D |
| --- | --- | --- | --- | --- |
| ascii | 31.5 | 34.7 | 136.4 | 222.3 |
| colors | 13.6 | 24.6 | 137.0 | 199.3 |
| unicode | 5.6 | 9.9 | 95.8 | 136.8 |
| cursor | 11.7 | 10.7 | 50.5 | 58.4 |
| tui | 20.8 | 24.3 | 159.4 | 168.8 |
| scroll | 25.7 | 26.0 | 112.7 | 160.1 |

At 80×24, in MB/s:

| Workload | A | B | C | D |
| --- | --- | --- | --- | --- |
| ascii | 39.9 | 39.4 | 170.4 | 201.0 |
| colors | 24.9 | 25.1 | 112.9 | 159.1 |
| unicode | 9.7 | 10.4 | 95.9 | 134.2 |
| cursor | 11.9 | 1.8 | 73.8 | 94.0 |
| tui | 21.4 | 22.1 | 137.1 | 162.9 |
| scroll | 31.9 | 32.0 | 147.6 | 167.9 |

B's 1.8 MB/s on cursor at 80×24 comes from SwiftTerm's handling of a 10,000-line scrollback, covered under Other findings. Run-to-run spread was within about 20% for every cell.

D is 6–63% ahead of C at 200×60 (most on plain text and scrolling, least on the TUI redraw). The emulator is the same, so the gap is the host: Ghostty reads and parses on its own IO thread with nothing shared with drawing, while C's reader and frame snapshot share one lock.

**The emulator alone**, with no PTY or window (200×60, 10,000 lines of scrollback, median of 5), shows how far apart they really are. This is the headroom C and D have beyond what the PTY lets through:

| Workload | SwiftTerm | libghostty-vt | Faster by |
| --- | --- | --- | --- |
| ascii | 47.7 MB/s | 461.9 MB/s | 9.7× |
| colors | 31.4 MB/s | 288.6 MB/s | 9.2× |
| unicode | 11.8 MB/s | 199.8 MB/s | 17.0× |
| cursor | 12.2 MB/s | 73.2 MB/s | 6.0× |
| tui | 29.5 MB/s | 623.4 MB/s | 21.1× |
| scroll | 34.9 MB/s | 288.2 MB/s | 8.3× |

Both emulators ended on identical screens for all six workloads, checked row by row.

## CPU

**C uses the least total CPU of the four, and A is the only one that loads the main thread heavily.** The main thread is the one that handles typing, tab switches and everything else in Side's UI. In A it carries both the parse and the drawing, which is what made Run feel stuck.

CPU seconds to process each workload at 200×60, shown as main thread / whole process (median of 3):

| Workload | A (Side today) | B | C | D |
| --- | --- | --- | --- | --- |
| ascii | 1.06 / 1.43 | 0.11 / 1.04 | 0.04 / 0.25 | 0.003 / 0.36 |
| colors | 2.33 / 2.79 | 0.20 / 1.44 | 0.05 / 0.25 | 0.003 / 0.43 |
| unicode | 2.77 / 3.05 | 0.20 / 1.75 | 0.04 / 0.19 | 0.003 / 0.27 |
| cursor | 1.35 / 1.55 | 0.11 / 1.56 | 0.03 / 0.34 | 0.004 / 0.43 |
| tui | 0.69 / 0.89 | 0.05 / 0.70 | 0.03 / 0.11 | 0.002 / 0.17 |
| scroll | 0.60 / 0.80 | 0.07 / 0.65 | 0.02 / 0.15 | 0.002 / 0.24 |

- **D** keeps almost nothing on the main thread (≤ 4 ms), because Ghostty parses and renders on threads of its own. Its total is 1.3–2.9× C's: its renderer does more per frame, and it draws more frames.
- **C**'s main-thread time is the snapshot and the frame, since this prototype draws on the main thread. Moving drawing to its own thread, as Ghostty does, would bring it close to D's.
- **Memory** (physical footprint after the run, 200×60): A 230–280 MB, B 178–240 MB, C 174–204 MB, D 194–214 MB.

## Frame cost

**Alloy draws a full screen in 0.3–2.0 ms even at an ultrawide 440×96 grid. Side's CoreText path takes 10–11 ms there, more than a whole frame at 120 Hz (8.3 ms).** This is the cost the ultrawide display in Side's backlog would pay on every full-screen change.

Milliseconds per frame (median of 60), drawn offscreen at 2×. For B and C, CPU (snapshot + build + encode) + GPU:

| Grid | Workload | A full screen | B full screen | C full screen | A one row | B one row | C one row |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 80×24 | tui | 1.32 | 0.12 + 0.03 | 0.11 + 0.05 | 0.09 | 0.12 + 0.03 | 0.02 + 0.05 |
| 80×24 | ascii | 0.60 | 0.13 + 0.03 | 0.12 + 0.10 | 0.08 | 0.13 + 0.03 | 0.02 + 0.09 |
| 200×60 | tui | 4.51 | 0.19 + 0.10 | 0.17 + 0.10 | 0.18 | 0.43 + 0.14 | 0.03 + 0.10 |
| 200×60 | ascii | 3.30 | 0.61 + 0.11 | 0.56 + 0.10 | 0.20 | 0.61 + 0.11 | 0.04 + 0.10 |
| 440×96 | tui | 10.87 | 0.35 + 0.29 | 0.31 + 0.29 | 0.19 | 0.89 + 0.29 | 0.05 + 0.29 |
| 440×96 | ascii | 10.26 | 1.86 + 0.54 | 1.58 + 0.31 | 0.20 | 1.84 + 0.53 | 0.06 + 0.31 |

- A's figures are CPU only. Its pixels then go to Core Animation, whose compositing cost isn't included.
- **A one-row change costs C almost nothing (0.02–0.06 ms CPU).** libghostty-vt reports exactly which rows changed. SwiftTerm's dirty range is coarse: a one-row change through save/restore cursor marks a span of rows, so B copies and rebuilds nearly a full screen (0.6–1.8 ms).
- The "full screen" tui rows change only the bottom ~18 rows (the TUI's region), which is why tui costs less than ascii scrolling.
- GPU time is flat at 0.1–0.5 ms: one instanced draw of every quad on screen.

## Six sessions

**With six agents streaming, A's main thread was busy for 2.7 s of a roughly 12-second run, about 22% of it. The other three used 0.3 s.** This is the situation from your Side project: several Claude sessions working while you type in another tab.

Six sessions at 200×60, one shown, five hidden, each at about 260 KB/s for 10 s (median of 3):

| Setup | Main-thread CPU | Process CPU | Footprint |
| --- | --- | --- | --- |
| A (Side today) | 2.74 s | 3.28 s | 78 MB |
| B | 0.30 s | 1.97 s | 177 MB |
| C | 0.31 s | 0.79 s | 176 MB |
| D | 0.32 s | 1.40 s | 324 MB |

- A parses hidden tabs on the main thread too. B, C and D parse them on background threads and draw only the visible one.
- C did the whole job on 0.79 s of CPU: 56% of D, 40% of B, 24% of A.
- D's footprint is the largest, but not because of its emulator; see the breakdown below. A's is the smallest, partly because its scrollback is 500 lines, not 10,000.
- Wall time (12–14 s) is set by the shell's sleep loop, not the terminal, so it isn't compared.

**Memory, checked.** The gap between C and D is framebuffers, not terminal state. A per-category breakdown from macOS's `footprint` tool, taken 7 s into a sessions run at 200×60:

| | C, 1 session | C, 6 sessions | D, 1 session | D, 6 sessions |
| --- | --- | --- | --- | --- |
| Terminal state (malloc heap) | 11 MB | 12 MB | 14 MB | 17 MB |
| Framebuffers (IOSurface) | 49 MB | 49 MB | 66 MB | 176 MB |
| Other GPU memory (driver, atlas, window) | 102 MB | 102 MB | 101 MB | 113 MB |
| Total footprint | 175 MB | 176 MB | 193 MB | 322 MB |

- Both emulators are lean: five more sessions add about 1 MB of heap in C and 3 MB in D.
- Every libghostty surface keeps framebuffers at full window size (about 22 MB each), even while hidden. C draws only the visible session, so hidden ones have none. That is a hosting choice, not Ghostty being heavier: at one session the two are 18 MB apart.
- About 150 MB in every setup is the same graphics baseline (Metal, the window's backing, the atlas). In Side, Make and Run would share most of it.

## Scaling with sessions

**C scales flattest. Going from 1 to 24 sessions, its CPU only doubles and its memory barely moves. D's memory grows by about 23 MB per session.** Same bursty Claude-shaped load as above (about 260 KB/s per session for 10 s), one session shown, at 200×60, median of 2 runs (`results/scaling.jsonl`).

Process CPU (main-thread CPU in brackets), and footprint:

| Sessions | A (Side today) | B | C | D |
| --- | --- | --- | --- | --- |
| 1 | 1.76 s (1.67), 74 MB | 0.69 s (0.29), 175 MB | 0.53 s (0.28), 175 MB | 0.78 s (0.35), 195 MB |
| 6 | 3.35 s (2.80), 78 MB | 2.07 s (0.33), 177 MB | 0.78 s (0.30), 177 MB | 1.70 s (0.38), 323 MB |
| 12 | 4.03 s (3.26), 82 MB | 3.45 s (0.29), 182 MB | 0.89 s (0.26), 177 MB | 2.12 s (0.24), 478 MB |
| 24 | 5.39 s (4.16), 90 MB | 4.15 s (0.22), 190 MB | 1.07 s (0.24), 178 MB | 1.88 s (0.20), 750 MB |

- **C** parses hidden sessions on background threads at libghostty-vt's speed and draws only the one shown. That's why its cost barely grows: 24 sessions cost 2× one session.
- **D** has the same emulator, but every session is a full surface with its own renderer and framebuffers, hidden or not. Memory grows linearly, reaching 750 MB at 24. Its CPU at 24 (1.88 s) came in below 12 (2.12 s) in both runs; why isn't known, so treat the 12–24 range as roughly flat.
- **A** does everything on the main thread. At 24 sessions the main thread was busy 4.2 s of about 12.5, a third of the time, before you type anything.
- **B** shows that the emulator decides CPU: the same renderer as C, but SwiftTerm's parse makes it grow 6× from 1 to 24.

**What this load doesn't exercise: scrollback.** A Claude-shaped redraw happens in place, so these sessions kept almost no scrollback. Output that scrolls adds up to about 16 MB per session at 10,000 lines and 200 columns of plain text, in C and D alike, about 1.3 MB once compressed (Side's session restore RFC, Memory). D's framebuffers come on top of that.

**The cost of C's approach:** a hidden session has no frame ready, so showing it means building one. At 200×60 that's under 1 ms (Frame cost), well inside one frame.

## Keypress latency

**Side's current CoreText view had the lowest latency: 6.8 ms median idle. C and B ran at 12–15 ms and D at about 20–22 ms.** All four stayed under 27 ms at the 95th percentile. That's below one frame at 60 Hz plus a little, and not something you'd feel day to day, but it's the one place C is behind A.

Key to pixels on screen, in ms (median across 3 runs):

| Setup | Idle median | Idle p95 | Idle best | Loaded median | Loaded p95 |
| --- | --- | --- | --- | --- | --- |
| A (Side today) | 6.8 | 16.6 | 4.2 | 9.1 | 15.3 |
| B | 14.7 | 17.0 | 5.5 | 11.5 | 17.0 |
| C | 13.7 | 17.8 | 5.7 | 12.6 | 17.2 |
| D | 21.9 | 26.2 | 12.2 | 20.3 | 25.8 |

"Loaded" means five hidden sessions streaming at about 260 KB/s each.

- **B and C lose time in presentation, not drawing.** Their frames cost under 0.5 ms (Frame cost), but a Metal layer's frame reaches the screen on Metal's schedule, which can cost an extra vsync. A's drawing goes out with the regular Core Animation commit.
- **What was tried:**
  - Drawing as soon as output arrives, rather than at the next display-link tick, and cutting the drawables in flight from 3 to 2: about 15 → 12 ms. This is in the numbers above.
  - Presenting with the Core Animation transaction (`presentsWithTransaction`): worse, 16–17 ms. Reverted.
- **B and C were slower idle than loaded (B 14.7 vs 11.5 ms, C 13.7 vs 12.6 ms).** The likely cause is ProMotion dropping the refresh rate when the screen is quiet, which delays a lone Metal frame. An earlier single run measured C at 12.9 ms idle. The best-case numbers (5–6 ms) show the pipeline can match A when a frame lines up.
- **D is consistently slowest.** Ghostty draws on its own vsync-paced render thread, after its IO thread has parsed; that's a design that favors throughput. Two checks that this isn't the harness's doing:
    - Telling Ghostty its display (`ghostty_surface_set_display_id`, as Ghostty.app does) changed nothing: 17.3–18.5 ms median with it, 17.5–18.2 ms without.
    - Ghostty's own `window-vsync = false` brought it to about 16 ms. Ghostty documents that trade: it keeps vsync on by default because rendering out of sync can cause kernel panics on macOS 14.4+.
    So D's latency is Ghostty's default behavior, not a hosting flaw.
- Light agent load barely moves any setup: about 1.3 MB/s in total doesn't saturate even A's main thread. Heavier output would hit A hardest, as the Six sessions numbers show.

## Other findings

- **SwiftTerm slows sharply with a long scrollback.** With 10,000 lines, the cursor workload at 80×24 ran at 1.8 MB/s and used 9.3 s of CPU. With Side's 500 lines it ran at 10.5 MB/s. Output that clears the screen often fills and trims scrollback constantly. Side couldn't raise its scrollback much on SwiftTerm without hitting this.
- **libghostty-vt caps scrollback at 10,000 bytes by default.** The C API's byte limit wins over any line limit, so a host that sets 10,000 lines without clearing the byte limit (`GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES` to NULL) keeps about 390 rows. Side's integration has to clear it, and this report's first version didn't.
- **libghostty-vt needs grapheme clustering turned on.** Mode 2027 is off by default in the library, and with it off, flags (🇯🇵) and ZWJ emoji (👩‍💻) split into their parts. Ghostty.app turns it on; Side would need to as well.
- **Arabic is the one text-fidelity difference.** SwiftTerm's view lays out each row with CoreText, so Arabic comes out shaped and joined. C and D draw one letter per cell, unjoined, which is how Ghostty itself draws it. CJK, Korean, emoji, combining marks and box drawing matched across all four.
- **Embedding full libghostty (D) has rough edges:**
  - On macOS, Ghostty always starts commands through `/usr/bin/login`, which prints a "Last login" line unless `~/.hushlogin` exists.
  - The surface API takes the command as one shell string. The `direct:` prefix that skips the shell works only in Ghostty's config file.
  - The embedding API isn't officially supported for apps other than Ghostty.
- **Side's own lag wasn't the terminal.** The git-on-main-thread bug (`270116a`) caused the one-second `cd`. The terminal engine is the next ceiling, not the cause of that symptom.

## Caveats

- **One machine and one display.** There was no external or ultrawide monitor, so the 440×96 grid was tested offscreen only, and D wasn't part of that test.
- **B and C's renderer reuses only part of Alloy:** its glyph atlas and its quad shaders, unchanged. Alloy's document layout (CoreText line layout, folding, LaTeX and image replacements) isn't involved; a terminal grid doesn't need it. These numbers say nothing about the cost of that layer.
- **B and C's renderer is a prototype written in an afternoon.** It has no selection, cursor styles, ligatures, IME (marked text), accessibility, mouse reporting or hyperlinks, and it rebuilds whole rows. Ghostty's renderer has years of tuning. Treat B and C's drawing numbers as roughly a floor for Alloy, and D's as a mature reference.
- **The workloads are synthetic.** The tui workload is shaped like Claude Code's output but isn't a recording. A real capture replayed through all four is the most useful next test.
- **The PTY caps end-to-end throughput at about 200 MB/s,** which compresses the differences at the top. The emulator-only benchmark shows the uncapped difference.
- **Latency is measured where the window server composites the window.** It doesn't include display scan-out or the panel. It's right for comparing the four setups, not as an absolute input-to-photon figure.
- **A ran with 500 lines of scrollback** while the others had 10,000 lines (or 10 MB). With matching scrollback, A would be slower than shown.
- **D's frame cost and frame counts weren't available,** because Ghostty renders on its own thread into its own surface.

## Recommendation and next steps

**Build Run's terminal on libghostty-vt with Alloy drawing it (setup C).**

**Why C:**

- It leaves SwiftTerm 4–17× behind at bulk output. Full Ghostty is still 6–63% ahead of it there, which is the lock to remove (next step 3).
- It uses the least CPU of all four, under a single stream and with six sessions, and draws ultrawide frames in about 2 ms.
- It keeps one text engine across Make and Run, so the editor and terminal look the same.
- It uses half of D's memory with six sessions. That's because only the visible session holds framebuffers, a design C makes easy; the emulators themselves are equally lean.
- libghostty-vt is meant for embedding, with a C API. Full libghostty's embedding is unsupported outside Ghostty.

**What it costs:**

- **The renderer is ours to build and maintain:** selection, cursor styles, IME, accessibility, mouse, hyperlinks, and later images.
- **libghostty-vt's C API isn't declared stable yet.** Pin a commit and wrap it behind one Swift layer.
- **The build gains a Zig 0.17 step.** Ship a prebuilt xcframework rather than building Ghostty in Side's Xcode build. Ghostty is MIT-licensed, so add it to the third-party notices.

**Next steps, in order:**

1. **Replay a real Claude Code capture** through all four setups. Record it from Side's raw terminal data hook.
2. **Close the latency gap to A**, with a target of ≤ 7 ms median. Try a `CAMetalDisplayLink`, present-at-time, and drawing on a thread of its own, and measure each with this harness.
3. **Remove the lock contention between reader and renderer.** For example, double-buffer the render state, as Ghostty's own threads do. That's where C trails D on throughput.
4. **Session restore around it:** drafted in Side's session restore RFC. A keeper process per session owns its PTY and a headless libghostty-vt terminal.
5. **Build out the renderer's missing features** before switching Run over, then re-run this suite against the real thing.
6. **Re-run on an external ultrawide display** when one is available.

## Sources

- Ghostty and libghostty-vt: https://github.com/ghostty-org/ghostty (commit `c7f68a7`, built with Zig 0.17.0)
- SwiftTerm: https://github.com/migueldeicaza/SwiftTerm (1.20.0)
- Benchmark code, scripts and raw results: this repository (see its README). The harness is three executables over a shared library: `TermBenchST` (A, B), `TermBenchGV` (C) and `TermBenchGK` (D). Raw results are in `results/*.jsonl`, and the memory breakdowns in `results/memory/`.
