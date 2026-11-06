import AppKit
import GhosttyVt
import Harness

// Setup C: libghostty-vt fed on a reader thread; each frame copies its render state (under the
// lock), then reads the dirty rows from that copy (outside it) into the Alloy renderer's grid.

final class GhosttySource: GridSource, @unchecked Sendable {
    var terminal: GhosttyTerminal?
    var state: GhosttyRenderState?
    var rowIterator: GhosttyRenderStateRowIterator?
    var cells: GhosttyRenderStateRowCells?
    let lock = FairLock()
    var dirtySinceFrame = true

    init(cols: Int, rows: Int) {
        ghostty_terminal_new(nil, &terminal, UInt16(cols), UInt16(rows))
        var lines = 10_000
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines)
        // The C API's default byte limit is 10,000 bytes (about two pages, ~390 rows at 200
        // columns), which silently overrides the line limit. Removed, so 10,000 lines are kept.
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, nil)
        // Grapheme clustering (mode 2027), on as in Ghostty.app: flags and ZWJ emoji are one cell.
        var clustering = GhosttyTerminalModeConfig()
        clustering.mode = ghostty_mode_new(2027, false)
        clustering.value = true
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE, &clustering)
        ghostty_render_state_new(nil, &state)
        ghostty_render_state_new(nil, &holdState)
        ghostty_render_state_row_iterator_new(nil, &rowIterator)
        ghostty_render_state_row_cells_new(nil, &cells)
        // Synchronized output (mode 2026), which Claude Code wraps nearly every update in: the
        // frame on screen when a hold begins is kept until it ends (render.h, Render Holds), as
        // SwiftTerm and Ghostty both do. TERMBENCH_NOHOLD=1 ignores holds (the 11-03 prototype).
        if ProcessInfo.processInfo.environment["TERMBENCH_NOHOLD"] != "1" {
            var me: UnsafeMutableRawPointer? = Unmanaged.passUnretained(self).toOpaque()
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, me)
            let hold: GhosttyTerminalRenderHoldFn = { terminal, userdata, held in
                Unmanaged<GhosttySource>.fromOpaque(userdata!).takeUnretainedValue().renderHold(held)
            }
            ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_RENDER_HOLD, unsafeBitCast(hold, to: UnsafeRawPointer.self))
            _ = me
        }
    }

    // A hold's frame is captured into its own render state on the reader thread (which holds the
    // lock during vt_write); a frame swaps it in under the lock, so the state the main thread
    // reads outside the lock is never the one the reader writes.
    var holdState: GhosttyRenderState?
    var held = false, holdCaptured = false, holdStart = 0.0
    func renderHold(_ on: Bool) {
        if on {
            ghostty_render_state_update(holdState, terminal)
            held = true; holdCaptured = true; holdStart = Metrics.now()
        } else {
            held = false
        }
        dirtySinceFrame = true
    }

    /// TERMBENCH_NOPARSE=1: read and drop (a diagnosis: the PTY's pace in this process, unparsed).
    static let noParse = ProcessInfo.processInfo.environment["TERMBENCH_NOPARSE"] == "1"

    func feed(_ bytes: UnsafeRawBufferPointer) {
        if Self.noParse { return }
        let base = bytes.bindMemory(to: UInt8.self).baseAddress!
        var offset = 0
        while offset < bytes.count {
            let n = min(bytes.count - offset, FairLock.slice)
            lock.readerSlice {
                ghostty_terminal_vt_write(terminal, base + offset, n)
                dirtySinceFrame = true
            }
            offset += n
        }
    }

    private static func pack(_ c: GhosttyColorRgb) -> UInt32 { UInt32(c.r) << 16 | UInt32(c.g) << 8 | UInt32(c.b) }

    func snapshot(into grid: Grid) -> Bool {
        let changed: Bool = lock.frame {
            if held, Metrics.now() - holdStart < 1 {
                // Held: show the frame from when the hold began, once, then nothing new.
                guard holdCaptured else { return false }
                holdCaptured = false
                swap(&state, &holdState)
                return true
            }
            guard dirtySinceFrame else { return false }
            dirtySinceFrame = false
            ghostty_render_state_update(state, terminal)
            return true
        }
        guard changed else { return false }

        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rowIterator)
        var y: UInt16 = 0
        var buf = [UInt32](repeating: 0, count: 16)
        while ghostty_render_state_row_iterator_next_dirty(rowIterator, &y) {
            let row = Int(y)
            guard row < grid.rows else { continue }
            ghostty_render_state_row_get(rowIterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells)
            var x = 0
            while ghostty_render_state_row_cells_next(cells), x < grid.cols {
                var cell = Cell()
                var raw: GhosttyCell = 0
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw)
                var wide = GHOSTTY_CELL_WIDE_NARROW
                ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
                if wide == GHOSTTY_CELL_WIDE_WIDE { cell.flags |= Cell.wide }
                if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD { cell.flags |= Cell.spacer }
                var len: UInt32 = 0
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &len)
                if len > 0 {
                    buf.withUnsafeMutableBufferPointer { _ = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, $0.baseAddress) }
                    cell.scalar = buf[0]
                    if len > 1 {
                        var s = String.UnicodeScalarView()
                        for i in 0..<Int(min(len, 16)) { if let u = UnicodeScalar(buf[i]) { s.append(u) } }
                        cell.cluster = String(s)
                    }
                }
                var style = GhosttyStyle()
                style.size = MemoryLayout<GhosttyStyle>.size
                ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style)
                var fg = GhosttyColorRgb(), bg = GhosttyColorRgb()
                var fgv = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg) == GHOSTTY_SUCCESS ? Self.pack(fg) : Theme.foreground
                var bgv: UInt32? = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) == GHOSTTY_SUCCESS ? Self.pack(bg) : nil
                if style.inverse { let f = fgv; fgv = bgv ?? Theme.background; bgv = f }
                cell.fg = fgv
                if let bgv { cell.bg = bgv; cell.flags &= ~Cell.defaultBG }
                if style.bold { cell.flags |= Cell.bold }
                if style.underline != 0 { cell.flags |= Cell.underline }
                grid.cells[row][x] = cell
                x += 1
            }
            grid.dirty[row] = true
            var clean = false
            ghostty_render_state_row_set(rowIterator, GHOSTTY_RENDER_STATE_ROW_OPTION_DIRTY, &clean)
        }
        var cursor = GhosttyRenderStateCursor()
        cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor)
        grid.cursor = (Int(cursor.viewport_x), Int(cursor.viewport_y), cursor.visible && cursor.viewport_has_value)
        ghostty_render_state_clean(state)
        return true
    }
}

@MainActor
final class SetupC {
    var loadKeep: [AnyObject] = []
    let view: GridView
    let source: GhosttySource
    init(options: Options) {
        let cell = GridView.cellSize(fontName: options.fontName, fontSize: options.fontSize)
        let cols = options.cols, rows = options.rows
        view = GridView(cols: cols, rows: rows, fontName: options.fontName, fontSize: options.fontSize,
                        frame: NSRect(x: 0, y: 0, width: CGFloat(cols) * cell.width, height: CGFloat(rows) * cell.height))
        source = GhosttySource(cols: cols, rows: rows)
        view.source = source
        Run.shared.grid = "\(cols)x\(rows)"
    }
    func start(options: Options) {
        Run.shared.shot = { [view] in view.writeShot(to: $0) }
        let pty = PTYProcess(command: options.command, cols: view.grid.cols, rows: view.grid.rows)
        let source = self.source
        defer {
            // The shell is waiting on its line: the clock starts as it gets it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { Run.shared.begin(); _ = write(pty.master, "\n", 1) }
        }
        if options.mode == "latency" {
            for _ in 0..<options.load {
                let extra = GhosttySource(cols: options.cols, rows: options.rows)
                let p = PTYProcess(command: options.loadCommand, cols: options.cols, rows: options.rows)
                p.startReading(consume: { extra.feed($0) }, done: {})
                loadKeep.append(extra)
            }
            let cell = GridView.cellSize(fontName: options.fontName, fontSize: options.fontSize)
            // A typed key goes to the PTY as its characters, as a terminal view's keyDown does.
            view.onKey = { text in
                let bytes = Array(text.utf8)
                _ = bytes.withUnsafeBytes { write(pty.master, $0.baseAddress, $0.count) }
                Stages.mark("keySent")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [view] in
                let row = Latency.echoRow(view: view, cellSize: cell)
                Latency.run(window: view.window!, cell: { _ in row }, send: { _ = write(pty.master, "X", 1) })
            }
        }
        let view = self.view
        pty.startReading(consume: { Stages.mark("echoRead"); source.feed($0); view.requestFrame() }, done: {
            var status: Int32 = 0
            waitpid(pty.pid, &status, 0)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    _ = source.snapshot(into: self.view.grid)
                    Run.shared.frames = self.view.frames
                    Run.shared.finish()
                }
            }
        })
    }
}

@MainActor
final class SessionsC {
    let view: GridView
    var sources: [GhosttySource] = []
    var exited = 0
    init(options: Options) {
        let cell = GridView.cellSize(fontName: options.fontName, fontSize: options.fontSize)
        view = GridView(cols: options.cols, rows: options.rows, fontName: options.fontName, fontSize: options.fontSize,
                        frame: NSRect(x: 0, y: 0, width: CGFloat(options.cols) * cell.width, height: CGFloat(options.rows) * cell.height))
        sources = (0..<options.sessions).map { _ in GhosttySource(cols: options.cols, rows: options.rows) }
        view.source = sources[0]
        Run.shared.grid = "\(options.cols)x\(options.rows)"
    }
    func start(options: Options) {
        var ptys: [PTYProcess] = []
        // The shown session draws on the display link's ticks; with renderthread there's no link,
        // so its output asks the render thread for a frame instead.
        let view = view, onRenderThread = GridView.experiments.contains("renderthread")
        for (i, source) in sources.enumerated() {
            let pty = PTYProcess(command: options.command, cols: options.cols, rows: options.rows)
            ptys.append(pty)
            let shown = i == 0 && onRenderThread
            pty.startReading(consume: { source.feed($0); if shown { view.requestFrame() } }, done: {
                var status: Int32 = 0
                waitpid(pty.pid, &status, 0)
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    self.exited += 1
                    if self.exited == self.sources.count { Run.shared.frames = self.view.frames; Run.shared.finish() }
                } }
            })
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { Run.shared.begin(); for p in ptys { _ = write(p.master, "\n", 1) } }
    }
}

@MainActor func frameCost(_ setup: SetupC) {
    let cell = GridView.cellSize(fontName: options.fontName, fontSize: options.fontSize)
    let pixels = CGSize(width: CGFloat(options.cols) * cell.width * 2, height: CGFloat(options.rows) * cell.height * 2)
    FrameCost.run(options: options, feed: { bytes in bytes.withUnsafeBytes { setup.source.feed($0) } }, frame: { _ in
        let start = Metrics.now()
        _ = setup.source.snapshot(into: setup.view.grid)
        let snap = (Metrics.now() - start) * 1000
        let f = setup.view.measureFrame(scale: 2, pixels: pixels)
        return (snap + f.cpuMs, f.gpuMs)
    })
}

let app = NSApplication.shared
Metrics.captureMainThread()
let options = MainActor.assumeIsolated { Run.shared.options }
var keep: AnyObject?
var window: NSWindow?
DispatchQueue.main.async {
    MainActor.assumeIsolated {
        if options.mode == "framecost" { frameCost(SetupC(options: options)); return }
        if options.mode == "sessions" {
            let c = SessionsC(options: options); keep = c
            window = makeWindow(content: c.view, options: options)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { c.start(options: options) }
            return
        }
        let c = SetupC(options: options); keep = c
        window = makeWindow(content: c.view, options: options)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { c.start(options: options) }
    }
}
app.run()
