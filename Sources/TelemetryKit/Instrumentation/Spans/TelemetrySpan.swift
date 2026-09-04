import Foundation

#if canImport(os)
    import os
#endif

/// The outcome of a measured operation.
public enum TelemetrySpanStatus: String, Codable, Sendable, Hashable {
    case ok
    case cancelled
    case error
}

/// A thread-safe, end-once performance measurement.
///
/// Dropping a span without ending it does not report a successful operation.
public final class TelemetrySpan: @unchecked Sendable {
    public let id: UUID
    public let operation: String

    private weak var client: TelemetryClient?
    private let initialAttributes: [String: TelemetryValue]
    private let startedAt = DispatchTime.now().uptimeNanoseconds
    private let lock = NSLock()
    private var ended = false

    #if canImport(os)
        private static let signpostLog = OSLog(
            subsystem: "dev.telemetrykit.sdk",
            category: "spans"
        )
        private let signpostID: OSSignpostID
    #endif

    internal init(
        operation: String,
        attributes: [String: TelemetryValue],
        client: TelemetryClient
    ) {
        id = UUID()
        self.operation = operation
        self.initialAttributes = attributes
        self.client = client
        #if canImport(os)
            signpostID = OSSignpostID(log: Self.signpostLog)
            os_signpost(
                .begin,
                log: Self.signpostLog,
                name: "Telemetry span",
                signpostID: signpostID
            )
        #endif
    }

    /// Ends the span once. Later calls are ignored and return `false`.
    @discardableResult
    public func end(
        status: TelemetrySpanStatus = .ok,
        attributes: [String: TelemetryValue] = [:]
    ) -> Bool {
        lock.lock()
        guard !ended else {
            lock.unlock()
            return false
        }
        ended = true
        lock.unlock()

        let endedAt = DispatchTime.now().uptimeNanoseconds
        let elapsed = endedAt >= startedAt ? endedAt - startedAt : 0

        #if canImport(os)
            let statusCode: Int
            switch status {
            case .ok:
                statusCode = 0
            case .cancelled:
                statusCode = 1
            case .error:
                statusCode = 2
            }
            os_signpost(
                .end,
                log: Self.signpostLog,
                name: "Telemetry span",
                signpostID: signpostID,
                "status_code=%{public}d",
                statusCode
            )
        #endif

        guard let client else { return true }
        var merged = initialAttributes
        for (key, value) in client.sanitizedSpanEndAttributes(attributes) {
            merged[key] = value
        }
        merged["span_id"] = .string(id.uuidString.lowercased())
        merged["operation"] = .string(operation)
        merged["status"] = .string(status.rawValue)
        merged["duration_ms"] = .double(Double(elapsed) / 1_000_000)

        _ = client.capture(
            "span.finished",
            attributes: merged,
            category: .span,
            level: status == .error ? .error : .info
        )
        return true
    }
}
