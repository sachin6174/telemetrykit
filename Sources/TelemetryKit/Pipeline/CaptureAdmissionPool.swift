import Foundation

/// Nonblocking permits bound the number of producers simultaneously copying
/// and encoding event graphs before they reach the byte-bounded ingress queue.
internal final class CaptureAdmissionPool: @unchecked Sendable {
    private let lock = NSLock()
    private let maximumConcurrentCaptures: Int
    private var activeCaptures = 0

    internal init(limits: TelemetryQueueLimits) {
        let byteBound = max(1, limits.maximumMemoryBytes / limits.maximumEventBytes)
        maximumConcurrentCaptures = max(
            1,
            min(16, limits.maximumMemoryEventCount, byteBound)
        )
    }

    internal func tryAcquire() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeCaptures < maximumConcurrentCaptures else { return false }
        activeCaptures += 1
        return true
    }

    internal func release() {
        lock.lock()
        activeCaptures = max(0, activeCaptures - 1)
        lock.unlock()
    }
}
