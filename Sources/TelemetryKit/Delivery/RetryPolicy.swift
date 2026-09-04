import Foundation

/// Applies retry-cycle exhaustion and server guidance around the public policy's
/// deterministic full-jitter calculation.
internal struct RetryDelayCalculator: Sendable {
    private static let maximumAcceptedServerDelay: TimeInterval = 24 * 60 * 60

    internal let policy: TelemetryRetryPolicy

    internal init(policy: TelemetryRetryPolicy) {
        self.policy = policy
    }

    /// - Parameters:
    ///   - attempt: Zero-based number of the retry being scheduled. `0` is the
    ///     first retry after an initial failed request.
    ///   - randomUnit: An injected value in `0 ... 1`, clamped defensively.
    ///   - retryAfter: Optional absolute date supplied by the server.
    /// - Returns: `nil` when the configured retry cycle is exhausted.
    internal func delay(
        attempt: Int,
        randomUnit: Double,
        retryAfter: Date?,
        now: Date
    ) -> TimeInterval? {
        guard attempt >= 0, attempt < policy.maximumAttemptsPerCycle else {
            return nil
        }

        let safeRandomUnit = randomUnit.isFinite ? randomUnit : 0
        let jitterDelay = policy.delay(attempt: attempt, randomUnit: safeRandomUnit)
        guard let retryAfter else { return jitterDelay }

        let rawServerDelay = retryAfter.timeIntervalSince(now)
        guard rawServerDelay.isFinite, rawServerDelay > 0 else {
            return jitterDelay
        }
        let serverDelay = min(rawServerDelay, Self.maximumAcceptedServerDelay)
        return max(jitterDelay, serverDelay)
    }
}
