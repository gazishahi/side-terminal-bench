import Foundation

/// TERMBENCH_PROBE=1: how responsive the main thread stays. A background thread hands the main
/// queue a no-op every 2 ms (one at a time) and records how long it waited to run, which is what
/// the app's own UI work would wait. Reported as mainLag p50, p99 and max, in ms.
enum MainProbe {
    static let enabled = ProcessInfo.processInfo.environment["TERMBENCH_PROBE"] == "1"
    nonisolated(unsafe) private static var lags: [Double] = []
    private static let lock = NSLock()

    static func start() {
        guard enabled else { return }
        Thread.detachNewThread {
            let ran = DispatchSemaphore(value: 0)
            while true {
                let t0 = Metrics.now()
                DispatchQueue.main.async {
                    let lag = (Metrics.now() - t0) * 1000
                    lock.lock(); lags.append(lag); lock.unlock()
                    ran.signal()
                }
                ran.wait()
                usleep(2000)
            }
        }
    }

    /// `,"mainLagP50Ms":…` for a result line, or "" when the probe is off.
    static func fields() -> String {
        guard enabled else { return "" }
        lock.lock(); let sorted = lags.sorted(); lock.unlock()
        guard !sorted.isEmpty else { return "" }
        let q = { (p: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        return String(format: ",\"mainLagP50Ms\":%.2f,\"mainLagP99Ms\":%.2f,\"mainLagMaxMs\":%.2f,\"mainLagSamples\":%d", q(0.5), q(0.99), sorted.last!, sorted.count)
    }
}

/// TERMBENCH_MAIN_BUSY=ms: the app's own UI work, stood in for by a main-thread timer that keeps
/// the main thread busy for that many ms, 60 times a second.
enum MainBusy {
    @MainActor static func start() {
        guard let ms = Double(ProcessInfo.processInfo.environment["TERMBENCH_MAIN_BUSY"] ?? ""), ms > 0 else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            let until = Metrics.now() + ms / 1000
            while Metrics.now() < until {}
        }
        RunLoop.main.add(timer, forMode: .common)
    }
}
