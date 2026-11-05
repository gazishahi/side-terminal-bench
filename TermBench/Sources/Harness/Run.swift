import AppKit
import Darwin
import Synchronization

// Shared by every setup: arguments, the window, the PTY, the clock and the numbers.

public struct Options {
    public var setup = "?"
    public var workload = ""
    public var width: CGFloat = 1600
    public var height: CGFloat = 1000
    public var fontName = "Menlo"
    public var fontSize: CGFloat = 13
    /// "throughput": cat the workload and time it. "idle": open and stay, for a capture.
    public var mode = "throughput"
    public var cols = 200
    /// "sessions" mode: this many terminals, the first shown, the rest in hidden tabs, each
    /// streaming `workload` in bursts (20 a second for 10 seconds), as agents do.
    public var sessions = 1
    /// Latency under load: this many hidden sessions streaming `--load-workload` meanwhile.
    public var load = 0
    public var loadWorkload = ""
    public var loadCommand: [String] {
        // TERMBENCH_LOAD_PACE="<pace> [flags] <recording>": each load session replays a real
        // recording at its own pace (Capture/pace.c) instead of the synthetic burst loop.
        if let pace = ProcessInfo.processInfo.environment["TERMBENCH_LOAD_PACE"] { return Self.relay + ["/bin/sh", "-c", "exec \(pace)"] }
        return Self.relay + ["/bin/sh", "-c", "i=0; while [ $i -lt 2000 ]; do /bin/cat '\(loadWorkload)'; /bin/sleep 0.05; i=$((i+1)); done"]
    }
    /// TERMBENCH_RELAY="<keeper-relay> <SideSessionKeeper> <run dir>": every command runs behind
    /// Side's session keeper, through Keeper/relay.c, as Side's terminals do (with one more PTY
    /// hop than Side's own client, the same for every setup).
    public static let relay: [String] = {
        guard let r = ProcessInfo.processInfo.environment["TERMBENCH_RELAY"], !r.isEmpty else { return [] }
        return r.split(separator: " ").map(String.init) + ["--"]
    }()
    public var rows = 60

    public static func parse() -> Options {
        var o = Options()
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let a = args.next() {
            switch a {
            case "--setup": o.setup = args.next() ?? o.setup
            case "--workload": o.workload = args.next() ?? ""
            case "--width": o.width = CGFloat(Double(args.next() ?? "") ?? 1600)
            case "--height": o.height = CGFloat(Double(args.next() ?? "") ?? 1000)
            case "--mode": o.mode = args.next() ?? o.mode
            case "--sessions": o.sessions = Int(args.next() ?? "") ?? 1
            case "--load": o.load = Int(args.next() ?? "") ?? 0
            case "--load-workload": o.loadWorkload = args.next() ?? ""
            case "--cols": o.cols = Int(args.next() ?? "") ?? o.cols
            case "--rows": o.rows = Int(args.next() ?? "") ?? o.rows
            default: break
            }
        }
        return o
    }

    /// The command every setup runs: a shell that waits for one line, then becomes cat. The
    /// setup sizes itself to the grid first, then sends the line and starts the clock, so no
    /// setup's startup (Ghostty's login wrapper included) is measured.
    public var command: [String] {
        if mode == "latency" { return Self.relay + Latency.command }
        // TERMBENCH_PACE="<pace> [flags] <recording>": the session replays a real recording in place
        // of cat (throughput) or of the burst loop (sessions).
        if let pace = ProcessInfo.processInfo.environment["TERMBENCH_PACE"], mode != "latency" {
            return Self.relay + ["/bin/sh", "-c", "read _; exec \(pace)"]
        }
        if mode == "sessions" {
            return Self.relay + ["/bin/sh", "-c", "read _; i=0; while [ $i -lt 200 ]; do /bin/cat '\(workload)'; /bin/sleep 0.05; i=$((i+1)); done"]
        }
        // TERMBENCH_WRITER_CLOCK=<file>: the writer's own clock, the same for every setup: the time
        // before cat starts and after it has written its last byte (it blocks while the terminal
        // isn't reading), so a setup's own idea of when the run ended doesn't enter into it.
        if let clock = ProcessInfo.processInfo.environment["TERMBENCH_WRITER_CLOCK"] {
            let stamp = "/usr/bin/perl -MTime::HiRes=time -e 'printf(\"%.6f\\n\", time)' >> '\(clock)'"
            // TERMBENCH_PRE: a command run first, inside the terminal (e.g. stty -a > file).
            let pre = ProcessInfo.processInfo.environment["TERMBENCH_PRE"].map { "\($0); " } ?? ""
            return Self.relay + ["/bin/sh", "-c", "read _; \(pre)\(stamp); /bin/cat '\(workload)'; \(stamp)"]
        }
        return Self.relay + ["/bin/sh", "-c", "read _; exec /bin/cat '\(workload)'"]
    }
}

public enum Theme {
    public static let background: UInt32 = 0x1E1E1E
    public static let foreground: UInt32 = 0xD0D0D0
}

// MARK: - Metrics

public enum Metrics {
    nonisolated(unsafe) static var mainThread: thread_act_t = 0

    /// Call on the main thread before anything is measured.
    public static func captureMainThread() { mainThread = mach_thread_self() }

    /// CPU seconds the main thread has used.
    public static func mainThreadCPU() -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(mainThread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard r == KERN_SUCCESS else { return -1 }
        return Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
            + Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
    }

    /// CPU seconds the whole process has used (every thread, not children).
    public static func processCPU() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    /// Physical footprint in MB, as Activity Monitor's Memory column shows it.
    public static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return r == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    public static func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
}

// MARK: - Run controller

/// Starts the clock when the command starts, stops it when the setup says the command has exited
/// and its output is consumed, prints one JSON line, and quits.
@MainActor
public final class Run {
    public static let shared = Run()
    public var options = Options.parse()
    public var frames = -1
    public var grid = ""
    private var start = 0.0, mainStart = 0.0, cpuStart = 0.0
    private var finished = false

    public func begin() {
        start = Metrics.now()
        mainStart = Metrics.mainThreadCPU()
        cpuStart = Metrics.processCPU()
        // A setup that never finishes still reports.
        DispatchQueue.main.asyncAfter(deadline: .now() + 300) { [weak self] in self?.finish(note: "timeout") }
    }

    /// Set by a setup: writes its current frame to a PNG (TERMBENCH_SHOT=path).
    public var shot: ((String) -> Void)?

    public func finish(note: String = "") {
        guard !finished, options.mode == "throughput" || options.mode == "sessions" else { return }
        finished = true
        let m = Measured(wall: Metrics.now() - start, main: Metrics.mainThreadCPU() - mainStart, cpu: Metrics.processCPU() - cpuStart, footprint: Metrics.footprintMB())
        if let path = ProcessInfo.processInfo.environment["TERMBENCH_SHOT"], let shot {
            // After the clock: a last frame for the eye, not part of the measurement.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [self] in shot(path); report(m, note: note) }
            return
        }
        report(m, note: note)
    }

    private struct Measured { let wall, main, cpu, footprint: Double }

    private func report(_ m: Measured, note: String) {
        let wall = m.wall
        let size = (try? FileManager.default.attributesOfItem(atPath: options.workload)[.size] as? Int) ?? 0
        let json = """
        {"setup":"\(options.setup)","workload":"\((options.workload as NSString).lastPathComponent)","bytes":\(size),"grid":"\(grid)",\
        "seconds":\(String(format: "%.3f", wall)),"MBps":\(String(format: "%.1f", Double(size) / wall / 1_048_576)),\
        "mainCPU":\(String(format: "%.3f", m.main)),"processCPU":\(String(format: "%.3f", m.cpu)),\
        "footprintMB":\(String(format: "%.0f", m.footprint)),"frames":\(frames),"mode":"\(options.mode)","sessions":\(options.sessions),"note":"\(note)"}
        """
        print(json)
        fflush(stdout)
        ReaderStats.report()
        // --hold keeps the window up for a screenshot.
        let hold = Double(ProcessInfo.processInfo.environment["TERMBENCH_HOLD"] ?? "0") ?? 0
        if hold > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + hold) { exit(0) } } else { exit(0) }
    }
}

// MARK: - Window

@MainActor
public func makeWindow(content: NSView, options: Options) -> NSWindow {
    NSApp.setActivationPolicy(.regular)
    let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: options.width, height: options.height),
                          styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "TermBench \(options.setup)"
    window.contentView = content
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(content)
    NSApp.activate(ignoringOtherApps: true)
    return window
}

// MARK: - PTY (setups B and C; A and D bring their own)

public final class PTYProcess: @unchecked Sendable {
    public let master: Int32
    public let pid: pid_t

    public init(command: [String], cols: Int, rows: Int) {
        var m: Int32 = 0, s: Int32 = 0
        var size = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&m, &s, nil, nil, &size) == 0 else { fatalError("openpty") }
        let slaveName = String(cString: ptsname(m))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addopen(&actions, 0, slaveName, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&actions, 0, 1)
        posix_spawn_file_actions_adddup2(&actions, 0, 2)
        posix_spawn_file_actions_addclose(&actions, m)
        posix_spawn_file_actions_addclose(&actions, s)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        // TERMBENCH_CHILD_QOS=user-initiated|user-interactive|utility: the child's QoS class. Ghostty
        // forks its child from a thread it set to user-initiated, and a forked child keeps it.
        switch ProcessInfo.processInfo.environment["TERMBENCH_CHILD_QOS"] {
        case "user-initiated": posix_spawnattr_set_qos_class_np(&attr, QOS_CLASS_USER_INITIATED)
        case "user-interactive": posix_spawnattr_set_qos_class_np(&attr, QOS_CLASS_USER_INTERACTIVE)
        case "utility": posix_spawnattr_set_qos_class_np(&attr, QOS_CLASS_UTILITY)
        default: break
        }
        var env: [UnsafeMutablePointer<CChar>?] = (["TERM=xterm-256color", "LANG=en_US.UTF-8"] as [String]).map { strdup($0) } + [nil]
        var argv: [UnsafeMutablePointer<CChar>?] = command.map { strdup($0) } + [nil]
        var child: pid_t = 0
        let r = posix_spawn(&child, command[0], &actions, &attr, &argv, &env)
        guard r == 0 else { fatalError("posix_spawn \(r)") }
        close(s)
        master = m
        pid = child
    }

    /// TERMBENCH_READER=pipeline: two threads, as Ghostty's termio reader has (Exec.zig, gather
    /// and parse stages). macOS hands out a PTY's output about 1 KB per read; one thread that reads
    /// and then parses leaves the writer blocked while it parses. Here a gather thread only reads,
    /// appending to a batch, and a parse thread takes whole batches, so the two overlap.
    public static let pipelined = ["pipeline", "bridge"].contains(ProcessInfo.processInfo.environment["TERMBENCH_READER"] ?? "")
    /// TERMBENCH_READER=bridge: the gather thread also bridges refill gaps as Ghostty's does
    /// (Exec.zig: non-blocking reads; once a full ~1 KiB read says the writer is saturated, up to
    /// 16 immediate retries, then polls of 1 ms, within 3 ms per batch) instead of sleeping in
    /// read(2) for every kilobyte.
    public static let bridging = ProcessInfo.processInfo.environment["TERMBENCH_READER"] == "bridge"

    /// Reads on a thread of its own until EOF, handing each read to `consume`; then `done`.
    public func startReading(consume: @escaping @Sendable (UnsafeRawBufferPointer) -> Void, done: @escaping @Sendable () -> Void) {
        if Self.pipelined { return startPipeline(consume: consume, done: done) }
        let fd = master
        let thread = Thread {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64 * 1024, alignment: 16)
            while true {
                let t0 = ReaderStats.on ? Metrics.now() : 0
                let n = read(fd, buffer, 64 * 1024)
                if n > 0 {
                    let t1 = ReaderStats.on ? Metrics.now() : 0
                    consume(UnsafeRawBufferPointer(start: buffer, count: n))
                    if ReaderStats.on { ReaderStats.record(bytes: n, read: t1 - t0, consume: Metrics.now() - t1) }
                    continue
                }
                if n < 0, errno == EINTR { continue }
                break // EOF, or EIO once the child has gone and the slave is closed
            }
            done()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}

extension PTYProcess {
    func startPipeline(consume: @escaping @Sendable (UnsafeRawBufferPointer) -> Void, done: @escaping @Sendable () -> Void) {
        final class Batch: @unchecked Sendable {
            let lock = NSLock()
            var pending: [UInt8] = []
            var finished = false
            let ready = DispatchSemaphore(value: 0)
        }
        let batch = Batch()
        batch.pending.reserveCapacity(1 << 20)
        let fd = master
        let gather = Thread {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: 64 * 1024, alignment: 16)
            if Self.bridging {
                _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
                var ended = false
                while !ended {
                    var total = 0, spins = 0
                    let started = Metrics.now()
                    gather: while total < 64 * 1024 {
                        let n = read(fd, buffer + total, 64 * 1024 - total)
                        if n > 0 { total += n; continue }
                        if n == 0 { ended = true; break }
                        if errno == EINTR { continue }
                        guard errno == EAGAIN else { ended = true; break }
                        if total < 1024 {
                            if total > 0 { break gather }
                            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                            _ = poll(&p, 1, -1)
                            continue
                        }
                        if spins < 16 { spins += 1; continue }
                        if Metrics.now() - started > 0.003 { break gather }
                        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                        if poll(&p, 1, 1) <= 0 { break gather }
                    }
                    if total > 0 {
                        batch.lock.lock()
                        let wasEmpty = batch.pending.isEmpty
                        batch.pending.append(contentsOf: UnsafeRawBufferPointer(start: buffer, count: total))
                        batch.lock.unlock()
                        if ReaderStats.on { ReaderStats.record(bytes: total, read: 0, consume: 0) }
                        if wasEmpty { batch.ready.signal() }
                    }
                }
                batch.lock.lock(); batch.finished = true; batch.lock.unlock()
                batch.ready.signal()
                return
            }
            while true {
                let t0 = ReaderStats.on ? Metrics.now() : 0
                let n = read(fd, buffer, 64 * 1024)
                if n > 0 {
                    batch.lock.lock()
                    let wasEmpty = batch.pending.isEmpty
                    batch.pending.append(contentsOf: UnsafeRawBufferPointer(start: buffer, count: n))
                    batch.lock.unlock()
                    if ReaderStats.on { ReaderStats.record(bytes: n, read: Metrics.now() - t0, consume: 0) }
                    if wasEmpty { batch.ready.signal() }
                    continue
                }
                if n < 0, errno == EINTR { continue }
                break
            }
            batch.lock.lock(); batch.finished = true; batch.lock.unlock()
            batch.ready.signal()
        }
        let parse = Thread {
            var working: [UInt8] = []
            working.reserveCapacity(1 << 20)
            while true {
                batch.ready.wait()
                while true {
                    batch.lock.lock()
                    swap(&working, &batch.pending)
                    let finished = batch.finished
                    batch.lock.unlock()
                    if working.isEmpty {
                        if finished { done(); return }
                        break
                    }
                    let t0 = ReaderStats.on ? Metrics.now() : 0
                    working.withUnsafeBytes { consume($0) }
                    if ReaderStats.on { ReaderStats.batches += 1; ReaderStats.batchConsume += Metrics.now() - t0 }
                    working.removeAll(keepingCapacity: true)
                }
            }
        }
        gather.qualityOfService = .userInteractive
        parse.qualityOfService = .userInteractive
        gather.start()
        parse.start()
    }
}

/// TERMBENCH_STATS=1: where the reader thread's time goes (in read(2), in the setup's consume,
/// and within that, waiting for the frame's lock and parsing), printed to stderr at exit.
public enum ReaderStats {
    public static let on = ProcessInfo.processInfo.environment["TERMBENCH_STATS"] == "1"
    nonisolated(unsafe) static var reads = 0, bytes = 0, readTime = 0.0, consumeTime = 0.0
    nonisolated(unsafe) public static var lockWait = 0.0, parse = 0.0, yields = 0, batches = 0, batchConsume = 0.0
    static func record(bytes n: Int, read: Double, consume: Double) {
        reads += 1; bytes += n; readTime += read; consumeTime += consume
    }
    public static func report() {
        guard on, reads > 0 else { return }
        FileHandle.standardError.write(String(format: "{\"stats\":1,\"reads\":%d,\"avgRead\":%d,\"readMs\":%.1f,\"consumeMs\":%.1f,\"lockWaitMs\":%.1f,\"parseMs\":%.1f,\"yields\":%d,\"batches\":%d,\"batchConsumeMs\":%.1f}\n",
                                                  reads, bytes / reads, readTime * 1000, consumeTime * 1000, lockWait * 1000, parse * 1000, yields, batches, batchConsume * 1000).data(using: .utf8)!)
    }
}

/// The emulator's lock, with a fair handoff: the reader parses in slices and steps aside between
/// them while a frame is waiting, so a slow parse can't starve the renderer. B and C share it.
public final class FairLock: @unchecked Sendable {
    private let lock = NSLock()
    private let frameWaiting = Atomic<Bool>(false)
    /// Signalled when a frame has had its turn; the reader blocks on it rather than spinning (a
    /// spinning reader at high priority kept the main thread from ever taking its turn).
    private let frameDone = DispatchSemaphore(value: 0)
    private let readerWaiting = Atomic<Bool>(false)
    public init() {}
    public func readerSlice(_ body: () -> Void) {
        let t0 = ReaderStats.on ? Metrics.now() : 0
        if !Self.greedy, frameWaiting.load(ordering: .acquiring) {
            readerWaiting.store(true, ordering: .releasing)
            // Re-checked after announcing: the frame may have finished in between.
            if frameWaiting.load(ordering: .acquiring) { _ = frameDone.wait(timeout: .now() + .milliseconds(4)) }
            readerWaiting.store(false, ordering: .releasing)
            if ReaderStats.on { ReaderStats.yields += 1 }
        }
        lock.lock()
        let t1 = ReaderStats.on ? Metrics.now() : 0
        body()
        lock.unlock()
        if ReaderStats.on { ReaderStats.lockWait += t1 - t0; ReaderStats.parse += Metrics.now() - t1 }
    }
    /// TERMBENCH_READER=greedy: the reader never steps aside for a waiting frame.
    static let greedy = ProcessInfo.processInfo.environment["TERMBENCH_READER"] == "greedy"
    public func frame<T>(_ body: () -> T) -> T {
        frameWaiting.store(true, ordering: .releasing)
        lock.lock()
        frameWaiting.store(false, ordering: .releasing)
        let result = body()
        lock.unlock()
        // Only a reader that is actually waiting is woken: signals don't pile up.
        if readerWaiting.load(ordering: .acquiring) { frameDone.signal() }
        return result
    }
    /// The reader's input in slices of this many bytes.
    public static let slice = Int(ProcessInfo.processInfo.environment["TERMBENCH_SLICE"] ?? "") ?? 16 * 1024
}

// MARK: - Frame cost (offscreen)

/// Times one frame after a full-screen change and after a one-row change, from the same bytes for
/// every setup. `feed` hands the emulator bytes (untimed); `frame` takes the snapshot and draws,
/// returning CPU and GPU milliseconds (GPU -1 where there is none).
@MainActor
public enum FrameCost {
    public static func run(options: Options, feed: ([UInt8]) -> Void, frame: (_ oneRow: Bool) -> (cpu: Double, gpu: Double)) {
        let data = Array((FileManager.default.contents(atPath: options.workload) ?? Data()).prefix(4 << 20))
        // A screenful's worth of the workload per full-screen change.
        let screen = max(4096, options.cols * options.rows * 2)
        var offset = 0
        func next() -> [UInt8] {
            if offset + screen > data.count { offset = 0 }
            defer { offset += screen }
            return Array(data[offset..<offset + screen])
        }
        for _ in 0..<5 { feed(next()); _ = frame(false) } // warm the atlas and caches
        var full: [(Double, Double)] = [], row: [(Double, Double)] = []
        for i in 0..<60 {
            feed(next()); full.append(frame(false))
            feed(Array("\u{1b}[s\u{1b}[1;1H\u{1b}[3\(i % 7 + 1)mrow change \(i)\u{1b}[0m\u{1b}[u".utf8)); row.append(frame(true))
        }
        func stat(_ xs: [Double]) -> String {
            let s = xs.sorted(); guard !s.isEmpty, s[0] >= 0 else { return "null" }
            return String(format: "{\"median\":%.3f,\"p95\":%.3f}", s[s.count / 2], s[min(s.count - 1, s.count * 95 / 100)])
        }
        print("""
        {"setup":"\(options.setup)","mode":"framecost","workload":"\((options.workload as NSString).lastPathComponent)","grid":"\(options.cols)x\(options.rows)",\
        "fullCPU":\(stat(full.map(\.0))),"fullGPU":\(stat(full.map(\.1))),"rowCPU":\(stat(row.map(\.0))),"rowGPU":\(stat(row.map(\.1)))}
        """)
        fflush(stdout)
        exit(0)
    }
}

// MARK: - Keypress latency

/// Key to pixels: a key is sent, and its cell (as the window server composites the window) is
/// captured every quarter millisecond, off the main thread, until it changes. Same capture for
/// every setup; no Screen Recording permission is needed for one's own window.
public enum Latency {
    typealias CaptureFn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
    nonisolated(unsafe) static let capture: CaptureFn = {
        let h = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW)
        return unsafeBitCast(dlsym(h, "CGWindowListCreateImage")!, to: CaptureFn.self)
    }()

    static func pixels(_ rect: CGRect, window: UInt32) -> [UInt8] {
        guard let img = capture(rect, 8, window, 0)?.takeRetainedValue(), let data = img.dataProvider?.data as Data? else { return [] }
        return [UInt8](data)
    }

    static func differs(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count, !a.isEmpty else { return false }
        var total = 0
        for i in 0..<a.count { total += abs(Int(a[i]) - Int(b[i])) }
        return total > 20_000 // one glyph's worth of change, not noise
    }

    /// The command for latency runs: hide the cursor (so only the echoed glyph changes the cell),
    /// wait for the start line, then sit while the tty echoes keys.
    public static let command = ["/bin/sh", "-c", "printf '\\033[?25l'; read _; exec /bin/sleep 600"]

    /// `cell(i)`: key i's cell in screen coordinates (top-left origin), in points.
    /// `send`: sends one key on the main thread.
    /// TERMBENCH_KEYS=events: each key is a real keyDown and keyUp posted to the app's event queue,
    /// so it takes the path a typed key takes: AppKit's dispatch, the first responder's keyDown and
    /// the setup's own key handling. Otherwise `send` hands the key to the setup directly, which
    /// skips that path and isn't the same path in every setup (setups A to D first used that).
    public static let realKeys = ProcessInfo.processInfo.environment["TERMBENCH_KEYS"] == "events"

    @MainActor
    static func postKey(window: NSWindow) {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x",
                                            isARepeat: false, keyCode: 7) {
                NSApp.postEvent(event, atStart: false)
            }
        }
    }

    @MainActor
    public static func run(window: NSWindow, keys: Int = 60, cell: @escaping @Sendable (Int) -> CGRect, send direct: @escaping @MainActor () -> Void) {
        let send: @MainActor () -> Void = realKeys ? { [weak window] in if let window { postKey(window: window) } } : direct
        let id = UInt32(window.windowNumber)
        if let dir = ProcessInfo.processInfo.environment["TERMBENCH_DEBUG"] {
            // What the capture sees: the whole window and the echo row, before any key.
            let whole = window.frame, screenH = NSScreen.screens[0].frame.height
            let wrect = CGRect(x: whole.minX, y: screenH - whole.maxY, width: whole.width, height: whole.height)
            for (name, r) in [("window", wrect), ("row", cell(0))] {
                if let img = capture(r, 8, id, 0)?.takeRetainedValue() {
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/\(Run.shared.options.setup)-\(name).png"))
                }
            }
            print("window", wrect, "row", cell(0))
        }
        DispatchQueue.global(qos: .userInteractive).async {
            var results: [Double] = []
            var timeouts = 0
            for i in 0..<keys {
                let rect = cell(i).insetBy(dx: 1, dy: 1)
                let before = pixels(rect, window: id)
                let sent = DispatchSemaphore(value: 0)
                var t0 = 0.0
                DispatchQueue.main.async { MainActor.assumeIsolated { t0 = Metrics.now(); send(); sent.signal() } }
                sent.wait()
                var seen = false
                while Metrics.now() - t0 < 0.5 {
                    if differs(pixels(rect, window: id), before) { results.append((Metrics.now() - t0) * 1000); seen = true; break }
                    usleep(250)
                }
                if !seen { timeouts += 1 }
                usleep(UInt32.random(in: 30_000...70_000))
            }
            results.sort()
            let pick = { (q: Double) in results.isEmpty ? -1 : results[min(results.count - 1, Int(Double(results.count) * q))] }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let o = Run.shared.options
                    print(String(format: "{\"setup\":\"%@\",\"mode\":\"latency\",\"input\":\"%@\",\"exp\":\"%@\",\"load\":%d,\"grid\":\"%dx%d\",\"keys\":%d,\"timeouts\":%d,\"minMs\":%.2f,\"medianMs\":%.2f,\"p95Ms\":%.2f,\"maxMs\":%.2f}",
                                 o.setup, realKeys ? "events" : "direct", ProcessInfo.processInfo.environment["TERMBENCH_EXP"] ?? "", o.load, o.cols, o.rows, results.count, timeouts, pick(0), pick(0.5), pick(0.95), results.last ?? -1))
                    fflush(stdout)
                    exit(0)
                }
            }
        }
    }

    /// Where keys echo (rows 1-3, the first 80 columns; Ghostty's login wrapper prints a line
    /// first, which moves its echo down a row), in screen coordinates, top-left origin. Nothing
    /// else changes there, so any change is the key landing and no exact cell width matters.
    @MainActor
    public static func echoRow(view: NSView, cellSize: CGSize) -> CGRect {
        let r = cellRect(view: view, col: 0, row: 1, cellSize: cellSize)
        return CGRect(x: r.minX, y: r.minY, width: cellSize.width * 80, height: cellSize.height * 3)
    }

    @MainActor
    public static func cellRect(view: NSView, col: Int, row: Int, cellSize: CGSize) -> CGRect {
        let inWindow = view.convert(NSRect(x: 0, y: view.isFlipped ? 0 : view.bounds.height, width: 0, height: 0), to: nil)
        let onScreen = view.window!.convertToScreen(NSRect(origin: inWindow.origin, size: .zero))
        let screenH = NSScreen.screens[0].frame.height
        return CGRect(x: onScreen.minX + CGFloat(col) * cellSize.width, y: screenH - onScreen.minY + CGFloat(row) * cellSize.height,
                      width: cellSize.width, height: cellSize.height)
    }
}
