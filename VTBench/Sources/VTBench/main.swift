import Foundation
import GhosttyVt
import SwiftTerm

// Emulator throughput: the same byte streams through SwiftTerm's Terminal and libghostty-vt,
// headless, same grid and scrollback, fed in PTY-sized chunks. Usage: VTBench [sourceDir]

let cols = 200, rows = 60, scrollback = 10_000, chunk = 16 * 1024, runs = 5

// MARK: - Workloads (deterministic)

struct LCG { var s: UInt64; mutating func next() -> UInt64 { s = s &* 6364136223846793005 &+ 1442695040888963407; return s >> 33 }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) } }

func repeatTo(_ bytes: [UInt8], _ size: Int) -> [UInt8] {
    var out = [UInt8](); out.reserveCapacity(size + bytes.count)
    while out.count < size { out += bytes }
    return out
}

func asciiSource(_ dir: String, _ size: Int) -> [UInt8] {
    var text = [UInt8]()
    let e = FileManager.default.enumerator(atPath: dir)
    while let p = e?.nextObject() as? String, text.count < 4_000_000 {
        guard p.hasSuffix(".swift"), let d = FileManager.default.contents(atPath: dir + "/" + p) else { continue }
        for b in d { if b == 10 { text += [13, 10] } else { text.append(b) } }
    }
    return repeatTo(text, size)
}

func colors(_ size: Int) -> [UInt8] {
    var r = LCG(s: 1), out = ""
    out.reserveCapacity(size)
    let words = ["let", "value", "return", "func", "self", "error:", "warning", "0x7f3a", "→", "done"]
    while out.utf8.count < size {
        for _ in 0..<30 {
            out += "\u{1b}[38;2;\(r.int(256));\(r.int(256));\(r.int(256))m\u{1b}[48;5;\(r.int(256))m\(words[r.int(words.count)]) "
        }
        out += "\u{1b}[0m\r\n"
    }
    return Array(out.utf8)
}

func unicode(_ size: Int) -> [UInt8] {
    var r = LCG(s: 2), out = ""
    let pieces = ["漢字テスト", "한국어", "👩‍💻", "🇯🇵", "e\u{301}", "ñ", "✓", "│", "─", "Ω≈ç√", "🙂", "a", "مرحبا", "ascii text "]
    while out.utf8.count < size {
        for _ in 0..<25 { out += pieces[r.int(pieces.count)] }
        out += "\r\n"
    }
    return Array(out.utf8)
}

func cursorMotion(_ size: Int) -> [UInt8] {
    var r = LCG(s: 3), out = ""
    while out.utf8.count < size {
        out += "\u{1b}[\(r.int(rows) + 1);\(r.int(cols) + 1)H\u{1b}[3\(r.int(8))mxyz\u{1b}[K"
        if r.int(50) == 0 { out += "\u{1b}[2J" }
    }
    return Array(out.utf8)
}

/// A Claude Code–like frame: hidden cursor, a boxed region redrawn in place, a spinner and
/// status line, erased lines, cursor shown again. Synthetic: the shape, not a recording.
func tuiRedraw(_ size: Int) -> [UInt8] {
    var r = LCG(s: 4), out = "", frame = 0
    let spinner = ["·", "✢", "✳", "✶", "✻", "✽"]
    let inner = cols - 4
    while out.utf8.count < size {
        frame += 1
        out += "\u{1b}[?25l\u{1b}[\(rows - 18);1H"
        out += "\u{1b}[38;5;245m╭" + String(repeating: "─", count: inner) + "╮\u{1b}[0m\r\n"
        for line in 0..<12 {
            var body = "\u{1b}[1m⏺\u{1b}[0m Update(\u{1b}[36mSIDE/File\(line).swift\u{1b}[0m) \u{1b}[32m+\(r.int(40))\u{1b}[0m \u{1b}[31m-\(r.int(20))\u{1b}[0m"
            body += String(repeating: " ", count: max(0, inner - 40))
            out += "\u{1b}[38;5;245m│\u{1b}[0m " + body + "\u{1b}[K\r\n"
        }
        out += "\u{1b}[38;5;245m╰" + String(repeating: "─", count: inner) + "╯\u{1b}[0m\r\n"
        out += "\u{1b}[38;5;174m\(spinner[frame % spinner.count]) Thinking… (\(frame / 10)s · ↑ \(r.int(9000)) tokens · esc to interrupt)\u{1b}[0m\u{1b}[K\r\n"
        out += "\u{1b}[K\r\n> \u{1b}[K\u{1b}[?25h"
    }
    return Array(out.utf8)
}

func scrollRegion(_ size: Int) -> [UInt8] {
    var r = LCG(s: 5), out = "\u{1b}[5;\(rows - 5)r"
    while out.utf8.count < size {
        out += "\u{1b}[\(rows - 5);1H\r\n\u{1b}[3\(r.int(8))mline \(r.next()) in a scroll region, like less or vim\u{1b}[0m"
    }
    return Array((out + "\u{1b}[r").utf8)
}

// MARK: - Engines

final class NullDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
}

protocol Engine { mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>); mutating func close() }

struct SwiftTermEngine: Engine {
    let delegate = NullDelegate()
    let terminal: Terminal
    init() { terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: cols, rows: rows, scrollback: scrollback)) }
    mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>) { terminal.feed(buffer: ArraySlice(bytes)) }
    mutating func close() {}
}

struct GhosttyEngine: Engine {
    var terminal: GhosttyTerminal?
    init() {
        guard ghostty_terminal_new(nil, &terminal, UInt16(cols), UInt16(rows)) == GHOSTTY_SUCCESS else { fatalError("ghostty_terminal_new") }
        var lines = scrollback
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines)
        // The C API's default byte limit is 10,000 bytes (about two pages, ~390 rows at 200
        // columns), which silently overrides the line limit. Removed, so 10,000 lines are kept.
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, nil)
        // Grapheme clustering (mode 2027), on as in Ghostty.app: flags and ZWJ emoji are one cell.
        var clustering = GhosttyTerminalModeConfig()
        clustering.mode = ghostty_mode_new(2027, false)
        clustering.value = true
        ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_MODE, &clustering)
    }
    mutating func feed(_ bytes: UnsafeBufferPointer<UInt8>) { ghostty_terminal_vt_write(terminal, bytes.baseAddress, bytes.count) }
    mutating func close() { ghostty_terminal_free(terminal) }
}

func measure<E: Engine>(_ make: () -> E, _ data: [UInt8]) -> Double {
    var times: [Double] = []
    for run in 0...runs {
        var engine = make()
        let start = DispatchTime.now().uptimeNanoseconds
        data.withUnsafeBufferPointer { all in
            var offset = 0
            while offset < all.count {
                let n = min(chunk, all.count - offset)
                engine.feed(UnsafeBufferPointer(rebasing: all[offset..<offset + n]))
                offset += n
            }
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        engine.close()
        if run > 0 { times.append(elapsed) } // run 0 is warm-up
    }
    let median = times.sorted()[times.count / 2]
    return Double(data.count) / median / 1_048_576
}

// MARK: - Run

let source = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath
let mb = 1 << 20
let workloads: [(String, [UInt8])] = [
    ("ascii (source code)", asciiSource(source, 32 * mb)),
    ("truecolor + 256-color SGR", colors(32 * mb)),
    ("unicode (CJK, emoji, RTL)", unicode(16 * mb)),
    ("cursor motion", cursorMotion(16 * mb)),
    ("TUI redraw (Claude-like)", tuiRedraw(16 * mb)),
    ("scroll region", scrollRegion(16 * mb)),
]

if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "dump" {
    let names = ["ascii", "colors", "unicode", "cursor", "tui", "scroll"]
    for (i, (_, data)) in workloads.enumerated() {
        FileManager.default.createFile(atPath: CommandLine.arguments[3] + "/" + names[i] + ".bin", contents: Data(data))
    }
    exit(0)
}
print("grid \(cols)x\(rows), scrollback \(scrollback) lines, \(chunk / 1024) KB chunks, median of \(runs) runs\n")
print("workload".padding(toLength: 28, withPad: " ", startingAt: 0) + "     size   SwiftTerm   libghostty-vt   ratio")
for (name, data) in workloads where CommandLine.arguments.count < 3 {
    let st = measure(SwiftTermEngine.init, data)
    let gh = measure(GhosttyEngine.init, data)
    print(name.padding(toLength: 28, withPad: " ", startingAt: 0)
          + String(format: "%6.0f MB %8.1f MB/s %10.1f MB/s %6.1fx", Double(data.count) / Double(mb), st, gh, gh / st))
}

// MARK: - Sanity: both engines end on the same screen

func screens(_ data: [UInt8]) -> (String, String) {
    var st = SwiftTermEngine(), gh = GhosttyEngine()
    data.withUnsafeBufferPointer { st.feed($0); gh.feed($0) }
    var lines: [String] = []
    for y in 0..<rows {
        var line = ""
        for x in 0..<cols { let c = st.terminal.getCharacter(col: x, row: y) ?? " "; line += c == "\0" ? " " : String(c) }
        while line.last == " " { line.removeLast() }
        lines.append(line)
    }
    while lines.last == "" { lines.removeLast() }
    var opts = GhosttyFormatterTerminalOptions()
    opts.size = MemoryLayout<GhosttyFormatterTerminalOptions>.size
    opts.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
    opts.trim = true
    var formatter: GhosttyFormatter?
    ghostty_formatter_terminal_new(nil, &formatter, gh.terminal, opts)
    var buf: UnsafeMutablePointer<UInt8>?; var len = 0
    ghostty_formatter_format_alloc(formatter, nil, &buf, &len)
    let all = String(decoding: UnsafeBufferPointer(start: buf, count: len), as: UTF8.self)
    let tail = all.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines.count).joined(separator: "\n")
    return (lines.joined(separator: "\n"), tail)
}

for (name, data) in workloads {
    let (a, b) = screens(Array(data.prefix(1 << 20)))
    let al = a.split(separator: "\n", omittingEmptySubsequences: false), bl = b.split(separator: "\n", omittingEmptySubsequences: false)
    let same = zip(al, bl).filter { $0 == $1 }.count
    print("screen check \(name): \(same)/\(max(al.count, bl.count)) visible rows identical")
}
if CommandLine.arguments.count > 3 {
    let (a, b) = screens(Array(workloads[2].1.prefix(1 << 20)))
    print("--- swiftterm last 3\n" + a.split(separator: "\n", omittingEmptySubsequences: false).suffix(3).map { "[\($0.prefix(80))]" }.joined(separator: "\n"))
    print("--- ghostty last 3\n" + b.split(separator: "\n", omittingEmptySubsequences: false).suffix(3).map { "[\($0.prefix(80))]" }.joined(separator: "\n"))
}
