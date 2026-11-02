import Foundation

/// Process-wide file transfer budget shared by vanilla, loaders, packs and resources.
public final class DownloadPolicy: @unchecked Sendable {
    public static let shared = DownloadPolicy()
    private let lock = NSLock()
    private var active = 0
    private var concurrency = 64
    private var bytesPerSecond = 0
    private var reservedUntil = 0.0
    public init() {}
    public var maximumConcurrent: Int { lock.withLock { concurrency } }
    public func configure(maximumConcurrent: Int, bytesPerSecond: Int) {
        lock.withLock {
            concurrency = max(1, min(256, maximumConcurrent))
            if self.bytesPerSecond != bytesPerSecond { reservedUntil = 0 }
            self.bytesPerSecond = max(0, bytesPerSecond)
        }
    }
    public func acquire() async throws {
        while true {
            try Task.checkCancellation()
            if lock.withLock({ () -> Bool in
                guard active < concurrency else { return false }; active += 1; return true
            }) { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    public func release() { lock.withLock { active = max(0, active - 1) } }
    /// Monotonic deadline; all transfers spend from the same timeline.
    func reserve(bytes: Int64, now: Double = ProcessInfo.processInfo.systemUptime) -> Double {
        lock.withLock {
            guard bytesPerSecond > 0 else { return now }
            reservedUntil = max(now, reservedUntil) + Double(max(0, bytes)) / Double(bytesPerSecond)
            return reservedUntil
        }
    }
    static func wait(until deadline: Double) async throws {
        while true {
            try Task.checkCancellation()
            let delay = deadline - ProcessInfo.processInfo.systemUptime
            if delay <= 0 { return }
            try await Task.sleep(nanoseconds: UInt64(min(delay, 60) * 1_000_000_000))
        }
    }
    public static func speedBytes(slider: Int) -> Int {
        let mb: Double
        switch slider {
        case 0...14: mb = Double(slider + 1) * 0.1
        case 15...31: mb = Double(slider - 11) * 0.5
        case 32...41: mb = Double(slider - 21)
        default: return 0
        }
        return Int((mb * 1024 * 1024).rounded())
    }
}
