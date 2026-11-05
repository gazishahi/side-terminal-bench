import AppKit
import Harness
import SwiftTerm

// Setup A: SwiftTerm's own view, as Side's Run uses it today (parse and CoreText drawing on the
// main thread). Setup B: SwiftTerm's Terminal fed on a reader thread, drawn by the Alloy renderer.

// MARK: - A

// SwiftTerm's draw isn't open, so A reports no frame count.
typealias CountingTerminalView = LocalProcessTerminalView

@MainActor
final class SetupA: NSObject, LocalProcessTerminalViewDelegate {
    var loadKeep: [AnyObject] = []
    let view: CountingTerminalView
    init(options: Options) {
        view = CountingTerminalView(frame: NSRect(x: 0, y: 0, width: options.width, height: options.height))
        super.init()
        view.font = NSFont(name: options.fontName, size: options.fontSize)!
        view.nativeBackgroundColor = NSColor(rgb: Theme.background)
        view.nativeForegroundColor = NSColor(rgb: Theme.foreground)
        view.processDelegate = self
    }
    func start(options: Options) {
        // SwiftTerm sizes its grid from its own cell metrics: grow or shrink the window until
        // the grid is the one asked for.
        for _ in 0..<6 {
            let t = view.getTerminal()
            if t.cols == options.cols, t.rows == options.rows { break }
            let cw = view.frame.width / CGFloat(max(t.cols, 1)), ch = view.frame.height / CGFloat(max(t.rows, 1))
            let size = NSSize(width: view.frame.width + CGFloat(options.cols - t.cols) * cw, height: view.frame.height + CGFloat(options.rows - t.rows) * ch)
            view.window?.setContentSize(size)
            view.frame.size = size
            view.layoutSubtreeIfNeeded()
        }
        let t = view.getTerminal()
        Run.shared.grid = "\(t.cols)x\(t.rows)"
        Run.shared.shot = { [view] path in
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
        view.startProcess(executable: options.command[0], args: Array(options.command.dropFirst()),
                          environment: ["TERM=xterm-256color", "LANG=en_US.UTF-8"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [view] in Run.shared.begin(); view.send(txt: "\n") }
        if options.mode == "latency" {
            // Load: hidden sessions in the same window, as Side's other Run tabs are.
            for _ in 0..<options.load {
                let v = LocalProcessTerminalView(frame: view.bounds)
                v.font = view.font
                v.isHidden = true
                view.addSubview(v)
                v.startProcess(executable: options.loadCommand[0], args: Array(options.loadCommand.dropFirst()), environment: ["TERM=xterm-256color", "LANG=en_US.UTF-8"])
                loadKeep.append(v)
            }
            let t = view.getTerminal()
            let cell = CGSize(width: GridView.cellSize(fontName: options.fontName, fontSize: options.fontSize).width, height: view.bounds.height / CGFloat(t.rows))
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [view] in
                let row = Latency.echoRow(view: view, cellSize: cell)
                Latency.run(window: view.window!, cell: { _ in row }, send: { view.send(txt: "X") })
            }
        }
    }
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            Run.shared.finish()
        }
    }
}

// MARK: - B

final class Quiet: TerminalDelegate { func send(source: Terminal, data: ArraySlice<UInt8>) {} }

final class SwiftTermSource: GridSource, @unchecked Sendable {
    let terminal: Terminal
    let quiet = Quiet()
    let lock = FairLock()
    var lastYDisp = -1

    init(cols: Int, rows: Int) {
        terminal = Terminal(delegate: quiet, options: TerminalOptions(cols: cols, rows: rows, scrollback: Int(ProcessInfo.processInfo.environment["TERMBENCH_SCROLLBACK"] ?? "") ?? 10_000))
    }

    func feed(_ bytes: UnsafeRawBufferPointer) {
        let all = bytes.bindMemory(to: UInt8.self)
        var offset = 0
        while offset < all.count {
            let end = min(all.count, offset + FairLock.slice)
            let slice = ArraySlice(UnsafeBufferPointer(rebasing: all[offset..<end]))
            lock.readerSlice { terminal.feed(buffer: slice) }
            offset = end
        }
    }

    private func resolve(_ c: Attribute.Color, isFG: Bool) -> UInt32? {
        switch c {
        case .ansi256(let code): return xterm256[Int(code)]
        case .trueColor(let r, let g, let b): return UInt32(r) << 16 | UInt32(g) << 8 | UInt32(b)
        case .defaultColor: return isFG ? Theme.foreground : nil
        case .defaultInvertedColor: return isFG ? Theme.background : Theme.foreground
        }
    }

    func snapshot(into grid: Grid) -> Bool { lock.frame { copy(into: grid) } }

    private func copy(into grid: Grid) -> Bool {
        var range = terminal.getUpdateRange()
        let yDisp = terminal.buffer.yDisp
        if yDisp != lastYDisp { lastYDisp = yDisp; range = (0, grid.rows - 1) }
        guard let range else { return false }
        terminal.clearUpdateRange()
        for y in max(0, range.startY)...min(grid.rows - 1, range.endY) {
            guard let line = terminal.getLine(row: y) else { continue }
            for x in 0..<min(grid.cols, line.count) {
                let cd = line[x]
                var cell = Cell()
                if cd.width == 0 { cell.flags |= Cell.spacer }
                if cd.width == 2 { cell.flags |= Cell.wide }
                let ch = terminal.getCharacter(for: cd)
                let scalars = ch.unicodeScalars
                cell.scalar = scalars.first?.value ?? 0
                if scalars.count > 1 { cell.cluster = String(ch) }
                let a = cd.attribute
                var fg = resolve(a.fg, isFG: true) ?? Theme.foreground
                var bg = resolve(a.bg, isFG: false)
                if a.style.contains(.inverse) { let f = fg; fg = bg ?? Theme.background; bg = f }
                cell.fg = fg
                if let bg { cell.bg = bg; cell.flags &= ~Cell.defaultBG }
                if a.style.contains(.bold) { cell.flags |= Cell.bold }
                if a.style.contains(.underline) { cell.flags |= Cell.underline }
                grid.cells[y][x] = cell
            }
            grid.dirty[y] = true
        }
        let cursor = terminal.getCursorLocation()
        grid.cursor = (cursor.x, cursor.y, true)
        return true
    }
}

@MainActor
final class SetupB {
    var loadKeep: [AnyObject] = []
    let view: GridView
    let source: SwiftTermSource
    init(options: Options) {
        let cell = GridView.cellSize(fontName: options.fontName, fontSize: options.fontSize)
        let cols = options.cols, rows = options.rows
        view = GridView(cols: cols, rows: rows, fontName: options.fontName, fontSize: options.fontSize,
                        frame: NSRect(x: 0, y: 0, width: CGFloat(cols) * cell.width, height: CGFloat(rows) * cell.height))
        source = SwiftTermSource(cols: cols, rows: rows)
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
                let extra = SwiftTermSource(cols: options.cols, rows: options.rows)
                let p = PTYProcess(command: options.loadCommand, cols: options.cols, rows: options.rows)
                p.startReading(consume: { extra.feed($0) }, done: {})
                loadKeep.append(extra)
            }
            let cell = GridView.cellSize(fontName: options.fontName, fontSize: options.fontSize)
            // A typed key goes to the PTY as its characters, as a terminal view's keyDown does.
            view.onKey = { text in
                let bytes = Array(text.utf8)
                _ = bytes.withUnsafeBytes { write(pty.master, $0.baseAddress, $0.count) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [view] in
                let row = Latency.echoRow(view: view, cellSize: cell)
                Latency.run(window: view.window!, cell: { _ in row }, send: { _ = write(pty.master, "X", 1) })
            }
        }
        let view = self.view
        pty.startReading(consume: { source.feed($0); view.requestFrame() }, done: {
            var status: Int32 = 0
            waitpid(pty.pid, &status, 0)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // The last of the output on screen before the clock stops.
                    if source.snapshot(into: self.view.grid) { self.view.needsDisplay = true }
                    Run.shared.frames = self.view.frames
                    Run.shared.finish()
                }
            }
        })
    }
}

extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Sessions (A and B): one shown, the rest in hidden tabs

@MainActor
final class SessionsA: NSObject, LocalProcessTerminalViewDelegate {
    let container: NSView
    var views: [LocalProcessTerminalView] = []
    var exited = 0
    init(options: Options, size: NSSize) {
        container = NSView(frame: NSRect(origin: .zero, size: size))
        super.init()
        for i in 0..<options.sessions {
            let v = LocalProcessTerminalView(frame: container.bounds)
            v.font = NSFont(name: options.fontName, size: options.fontSize)!
            v.nativeBackgroundColor = NSColor(rgb: Theme.background)
            v.nativeForegroundColor = NSColor(rgb: Theme.foreground)
            v.processDelegate = self
            v.isHidden = i > 0
            container.addSubview(v)
            views.append(v)
        }
    }
    func start(options: Options) {
        for v in views {
            v.startProcess(executable: options.command[0], args: Array(options.command.dropFirst()), environment: ["TERM=xterm-256color", "LANG=en_US.UTF-8"])
        }
        let t = views[0].getTerminal()
        Run.shared.grid = "\(t.cols)x\(t.rows)"
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [views] in
            Run.shared.begin()
            for v in views { v.send(txt: "\n") }
        }
    }
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        MainActor.assumeIsolated {
            exited += 1
            if exited == views.count { Run.shared.finish() }
        }
    }
}

@MainActor
final class SessionsB {
    let view: GridView
    var sources: [SwiftTermSource] = []
    var exited = 0
    init(options: Options) {
        let cell = GridView.cellSize(fontName: options.fontName, fontSize: options.fontSize)
        view = GridView(cols: options.cols, rows: options.rows, fontName: options.fontName, fontSize: options.fontSize,
                        frame: NSRect(x: 0, y: 0, width: CGFloat(options.cols) * cell.width, height: CGFloat(options.rows) * cell.height))
        sources = (0..<options.sessions).map { _ in SwiftTermSource(cols: options.cols, rows: options.rows) }
        view.source = sources[0]
        Run.shared.grid = "\(options.cols)x\(options.rows)"
    }
    func start(options: Options) {
        var ptys: [PTYProcess] = []
        for source in sources {
            let pty = PTYProcess(command: options.command, cols: options.cols, rows: options.rows)
            ptys.append(pty)
            pty.startReading(consume: { source.feed($0) }, done: {
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

// MARK: - Main

@MainActor func frameCost(_ setup: SetupB) {
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
        if options.mode == "sessions" {
            if options.setup == "A" {
                let probe = SetupA(options: options)
                let w = makeWindow(content: probe.view, options: options); window = w
                // Size to the grid with one view, then hold N of that size.
                for _ in 0..<6 {
                    let t = probe.view.getTerminal()
                    if t.cols == options.cols, t.rows == options.rows { break }
                    let cw = probe.view.frame.width / CGFloat(max(t.cols, 1)), ch = probe.view.frame.height / CGFloat(max(t.rows, 1))
                    let size = NSSize(width: probe.view.frame.width + CGFloat(options.cols - t.cols) * cw, height: probe.view.frame.height + CGFloat(options.rows - t.rows) * ch)
                    w.setContentSize(size); probe.view.frame.size = size; probe.view.layoutSubtreeIfNeeded()
                }
                let a = SessionsA(options: options, size: probe.view.frame.size); keep = a
                w.contentView = a.container
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { a.start(options: options) }
            } else {
                let b = SessionsB(options: options); keep = b
                window = makeWindow(content: b.view, options: options)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { b.start(options: options) }
            }
            return
        }
        if options.mode == "framecost" {
            if options.setup == "A" {
                let a = SetupA(options: options); keep = a
                // Offscreen, at 2x, sized to the grid: SwiftTerm's own CoreText drawing, timed.
                let w = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 100, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
                w.contentView = a.view
                window = w
                for _ in 0..<6 {
                    let t = a.view.getTerminal()
                    if t.cols == options.cols, t.rows == options.rows { break }
                    let cw = a.view.frame.width / CGFloat(max(t.cols, 1)), ch = a.view.frame.height / CGFloat(max(t.rows, 1))
                    let size = NSSize(width: a.view.frame.width + CGFloat(options.cols - t.cols) * cw, height: a.view.frame.height + CGFloat(options.rows - t.rows) * ch)
                    w.setContentSize(size); a.view.frame.size = size; a.view.layoutSubtreeIfNeeded()
                }
                let rep = a.view.bitmapImageRepForCachingDisplay(in: a.view.bounds)!
                let rowRect = NSRect(x: 0, y: a.view.bounds.height - a.view.bounds.height / CGFloat(options.rows), width: a.view.bounds.width, height: a.view.bounds.height / CGFloat(options.rows))
                FrameCost.run(options: options, feed: { a.view.feed(byteArray: $0[...]) }, frame: { oneRow in
                    let start = Metrics.now()
                    a.view.cacheDisplay(in: oneRow ? rowRect : a.view.bounds, to: rep)
                    return ((Metrics.now() - start) * 1000, -1)
                })
            } else {
                frameCost(SetupB(options: options))
            }
            return
        }
        if options.setup == "A" {
            let a = SetupA(options: options); keep = a
            window = makeWindow(content: a.view, options: options)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { a.start(options: options) }
        } else {
            let b = SetupB(options: options); keep = b
            window = makeWindow(content: b.view, options: options)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { b.start(options: options) }
        }
    }
}
app.run()
