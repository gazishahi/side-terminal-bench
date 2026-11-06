import CoreMedia
import Darwin
import ScreenCaptureKit

/// TERMBENCH_CLOCK=display: the latency clock stops when the key's glyph is in a frame the window
/// server composited for the display, at that frame's display time (SCStreamFrameInfo.displayTime),
/// instead of when a capture of the window alone first shows it. A window capture returns the
/// window's newest contents whenever it's asked, so it can't see the wait for the compositor's
/// next frame, which a setup that presents without vsync still pays before anything is on glass.
/// Needs Screen Recording permission. Scan-out and the panel's own response come after this
/// and are the same for every setup.
final class DisplayClock: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: [UInt8] = []
    private var frames: [(time: Double, pixels: [UInt8])] = []
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "termbench.displayclock", qos: .userInteractive)
    private static let tick: Double = {
        var info = mach_timebase_info_data_t(); mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1e9
    }()

    /// `rect`: screen points, top-left origin, on the main display.
    static func start(rect: CGRect, scale: CGFloat) -> DisplayClock? {
        let clock = DisplayClock()
        let ready = DispatchSemaphore(value: 0)
        var ok = false
        Task.detached {
            defer { ready.signal() }
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else { return }
            let config = SCStreamConfiguration()
            config.sourceRect = rect
            config.width = Int(rect.width * scale); config.height = Int(rect.height * scale)
            config.minimumFrameInterval = CMTime(value: 1, timescale: 240)
            config.queueDepth = 3
            config.showsCursor = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: config, delegate: nil)
            do {
                try stream.addStreamOutput(clock, type: .screen, sampleHandlerQueue: clock.queue)
                try await stream.startCapture()
                clock.stream = stream; ok = true
            } catch { FileHandle.standardError.write("display clock: \(error)\n".data(using: .utf8)!) }
        }
        ready.wait()
        return ok ? clock : nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let infos = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = infos.first, let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let shown = info[.displayTime] as? UInt64, let image = CMSampleBufferGetImageBuffer(buffer) else { return }
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { return }
        let pixels = [UInt8](UnsafeRawBufferPointer(start: base, count: CVPixelBufferGetBytesPerRow(image) * CVPixelBufferGetHeight(image)))
        lock.lock(); latest = pixels; frames.append((Double(shown) * Self.tick, pixels)); lock.unlock()
    }

    /// The newest composited pixels, and frames recorded from here on.
    func mark() -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        frames.removeAll()
        return latest
    }

    /// The display time of the first frame since `mark` that differs from `before`, if any yet.
    func firstChange(from before: [UInt8], differs: ([UInt8], [UInt8]) -> Bool) -> Double? {
        lock.lock(); let seen = frames; lock.unlock()
        return seen.first(where: { differs($0.pixels, before) })?.time
    }

    func stop() {
        let stream = stream
        Task.detached { try? await stream?.stopCapture() }
    }
}
