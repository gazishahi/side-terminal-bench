import Foundation
import IOSurface
import ObjectiveC
import QuartzCore

/// TERMBENCH_STAGES=1: where a key's latency goes. Each latency key arms the recorder; setups
/// mark the first time each stage happens after it, in ms from the key:
///   keyDown   the view received the key event
///   keySent   the key was handed to the terminal (written to the PTY, or ghostty_surface_key)
///   wakeup    full libghostty asked the app for a tick (its threads had something for main)
///   present   C committed a frame with a drawable (CAMetalLayer)
///   contents  an IOSurface was set as a layer's contents (full libghostty's frame handoff),
///             seen by hooking -[CALayer setContents:]
/// The display clock gives the last stage, the frame on the display.
public enum Stages {
    public static let enabled = ProcessInfo.processInfo.environment["TERMBENCH_STAGES"] == "1"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var t0 = 0.0
    nonisolated(unsafe) private static var marks: [String: Double] = [:]
    /// Every time a frame was handed off (present, contents) since the key, not just the first.
    nonisolated(unsafe) private static var handoffs: [Double] = []
    nonisolated(unsafe) private static var history: [[String: Double]] = []

    static func arm(_ t: Double) {
        guard enabled else { return }
        lock.lock(); t0 = t; marks = [:]; handoffs = []; lock.unlock()
    }

    public static func mark(_ name: String) {
        guard enabled else { return }
        let now = Metrics.now()
        lock.lock(); defer { lock.unlock() }
        guard t0 > 0 else { return }
        let ms = (now - t0) * 1000
        if marks[name] == nil { marks[name] = ms }
        if name == "present" || name == "contents" { handoffs.append(ms) }
    }

    /// Ends a key: its marks join the history, and the recorder disarms. With the key's display
    /// time (ms), it also records the last handoff before it (lastHandoff, the frame that was
    /// shown) and how many frames were handed off up to then (handoffs).
    static func close(shownAt: Double?) {
        guard enabled else { return }
        lock.lock()
        if let shownAt {
            let before = handoffs.filter { $0 <= shownAt }
            if let last = before.last { marks["lastHandoff"] = last }
            marks["handoffs"] = Double(before.count)
        }
        history.append(marks); t0 = 0
        lock.unlock()
    }

    /// `,"stages":{"keyDown":…}`: each stage's median over the keys that reached it.
    static func fields() -> String {
        guard enabled else { return "" }
        lock.lock(); let all = history; lock.unlock()
        let names = Set(all.flatMap(\.keys)).sorted()
        let parts = names.map { name -> String in
            let v = all.compactMap { $0[name] }.sorted()
            return String(format: "\"%@\":%.2f,\"%@N\":%d", name, v[v.count / 2], name, v.count)
        }
        return ",\"stages\":{" + parts.joined(separator: ",") + "}"
    }

    /// Hooks -[CALayer setContents:] to mark "contents" whenever the new contents is an IOSurface.
    static func hookLayerContents() {
        guard enabled else { return }
        let sel = #selector(setter: CALayer.contents)
        guard let method = class_getInstanceMethod(CALayer.self, sel) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Setter.self)
        let block: @convention(block) (AnyObject, AnyObject?) -> Void = { layer, contents in
            if let contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() { mark("contents") }
            original(layer, sel, contents)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}
