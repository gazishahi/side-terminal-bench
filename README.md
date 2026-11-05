# Terminal engine benchmarks

The harness behind `docs/BENCHMARKS_2026-11-03.md`: four ways to build the
terminal in [Side](https://github.com/gazishahi/side-releases), a Mac code editor, measured the
same way. Its question is which engine Side's terminal should move to; the results are the
evidence, and this harness is here so anyone can re-run them and check.

| Setup | Emulator | Drawing |
| --- | --- | --- |
| A | SwiftTerm 1.20.0 | SwiftTerm's CoreText view (Side today) |
| B | SwiftTerm 1.20.0, on a reader thread | Alloy renderer prototype |
| C | libghostty-vt, on a reader thread | Alloy renderer prototype |
| D | full libghostty | Ghostty's own renderer |

## Layout

- `VTBench/` measures emulator-only throughput (SwiftTerm vs libghostty-vt, no window or PTY) and writes the workloads.
- `TermBench/` is the end-to-end harness. `Harness` is shared: the PTY, metrics, the Alloy grid renderer (`GridRenderer.swift`, over Alloy's atlas copied in as `AlloyGlyphAtlas.swift`), frame cost and latency. It builds three executables, because GhosttyKit and libghostty-vt can't link into one binary:
  - `TermBenchST`: setups A and B
  - `TermBenchGV`: setup C
  - `TermBenchGK`: setup D
- `Keeper/keeper.c` is the prototype session keeper behind the memory figures in Side's session restore RFC: a PTY and a headless libghostty-vt terminal, measured idle, with full scrollback, and compressed.
- `scripts/` holds the build, workload, suite and summary scripts.
- `results/` holds the raw results the write-up was made from, plus `memory/`, the `footprint` breakdowns.

## Running

```sh
brew install zig                 # 0.17
scripts/build-ghostty.sh         # pinned Ghostty commit -> the two xcframeworks (git-ignored)
SOURCE=~/src/some-swift-project scripts/make-workloads.sh   # workloads/*.bin (git-ignored)
scripts/run-all.sh               # about 30 minutes; SETUPS="B C" scripts/run-all.sh for a subset
```

The `ascii` workload is plain text made from the Swift sources in `SOURCE` (also needed by `run-all.sh`). Our results used Side's own sources, which aren't public, so your `ascii` bytes differ from ours. The other five workloads are generated and identical for everyone.

Windows open and close on screen while it runs. Leave them uncovered, because Ghostty stops drawing a surface that's hidden. Keypress latency captures the harness's own windows, which needs no Screen Recording permission.

One run by hand:

```sh
TermBench/.build/release/TermBenchGV --setup C --workload workloads/tui.bin --cols 200 --rows 60
```

- Modes are `--mode throughput` (the default), `framecost`, `sessions --sessions 6`, and `latency [--load 5 --load-workload workloads/tui-burst.bin]`.
- `TERMBENCH_SHOT=/path.png` writes the final frame, so you can check a run drew what it should.
- `TERMBENCH_SCROLLBACK=500` sets B's scrollback.

## Replaying a real session

The Phase 0 results in `results/validation/2026-11-05-capture/` come from a real Claude Code session. That recording holds a private conversation and isn't published, so to check the results, record a session of your own: any program works, though the RFC's question is about Claude Code.

```sh
script -r ~/session.rec claude   # work as usual; exit claude to stop recording
cc -O2 -o /tmp/pace Capture/pace.c
(cd TermBench && for p in TermBenchST TermBenchGV TermBenchGK; do swift build -c release --product $p; done)
REC=~/session.rec PACE=/tmp/pace scripts/replay.sh            # PART=full|sessions|latency for one part
python3 -I scripts/summarize-validation.py results/validation/<date>-capture-direct
```

- `pace --dump session.rec out.bin` gives the recording's output alone, to inspect or to use as a `--workload`. Only output is replayed, never what was typed.
- A recording will differ from ours in size and shape, so compare the setups' ratios, not the absolute numbers. NOTES.md section 7 describes our recording's shape (write sizes, rates, how much is synchronized output) so you can tell how close yours is.
- Without `KEEPER` and `RELAY`, the setups read their PTYs directly. Our committed runs were behind Side's session keeper (`Keeper/relay.c` in front of `SideSessionKeeper`, which ships with Side rather than with this harness): `KEEPER=<SideSessionKeeper> RELAY=<cc -O2 Keeper/relay.c> scripts/replay.sh`. On 26.4.1 the keeper added under 1 ms of latency to any setup and capped C and D alike at about 100 MB/s (NOTES.md section 5), so direct runs read faster than ours on bulk output.
- Leave the windows uncovered, note your macOS version, and don't compare runs across macOS versions: SwiftTerm's key latency moved by 6 ms between 26.4.1 and 27.2.

## Rules that keep it fair

- Same font (Menlo 13), colors and command for all four. Each window is sized from its engine's own cell metrics, so every setup gets the same grid.
- The clock starts when the shell, already waiting on `read`, gets its line. No setup's startup is counted, Ghostty's `login` wrapper included.
- libghostty-vt runs with grapheme clustering (mode 2027) on, as Ghostty.app does, and with its default 10,000-byte scrollback cap removed (it overrides the line limit).
- Check the screenshots before trusting a number. Two invalid runs were caught that way.
