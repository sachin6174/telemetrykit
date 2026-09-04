import Foundation

internal protocol TelemetryRuntimeClock: Sendable {
    func now() -> Date
    func sleep(for delay: TimeInterval) async throws
}

internal struct SystemTelemetryClock: TelemetryRuntimeClock {
    internal func now() -> Date { Date() }

    internal func sleep(for delay: TimeInterval) async throws {
        guard delay > 0 else {
            try Task.checkCancellation()
            return
        }
        let boundedDelay = min(delay, 24 * 60 * 60)
        let nanoseconds = UInt64((boundedDelay * 1_000_000_000).rounded())
        try await Task.sleep(nanoseconds: nanoseconds)
    }
}

internal protocol TelemetryRandomSource: Sendable {
    func nextUnit() async -> Double
}

internal struct SystemTelemetryRandomSource: TelemetryRandomSource {
    internal func nextUnit() async -> Double {
        Double.random(in: 0...1)
    }
}
