import Foundation

#if canImport(os)
    import os
#endif

internal struct TelemetryUploadSignpost: @unchecked Sendable {
    #if canImport(os)
        fileprivate let identifier: OSSignpostID
    #endif
}

/// Payload-free SDK diagnostics. Event data, endpoints, headers, and auth values
/// are intentionally never accepted by this API.
internal final class TelemetryDiagnostics: @unchecked Sendable {
    #if canImport(os)
        private let log = OSLog(subsystem: "dev.telemetrykit.sdk", category: "delivery")
    #endif

    func uploadBegan(eventCount: Int) -> TelemetryUploadSignpost {
        #if canImport(os)
            let identifier = OSSignpostID(log: log)
            os_signpost(
                .begin,
                log: log,
                name: "Telemetry upload",
                signpostID: identifier,
                "event_count=%{public}d",
                eventCount
            )
            return TelemetryUploadSignpost(identifier: identifier)
        #else
            return TelemetryUploadSignpost()
        #endif
    }

    func uploadEnded(_ signpost: TelemetryUploadSignpost, statusCode: Int?) {
        #if canImport(os)
            os_signpost(
                .end,
                log: log,
                name: "Telemetry upload",
                signpostID: signpost.identifier,
                "status=%{public}d",
                statusCode ?? 0
            )
        #endif
    }

    func queueDroppedEvent(reasonCode: Int) {
        #if canImport(os)
            os_log(
                "Telemetry event dropped; reason=%{public}d",
                log: log,
                type: .info,
                reasonCode
            )
        #endif
    }

    func deliveryPaused(reasonCode: Int) {
        #if canImport(os)
            os_log(
                "Telemetry delivery paused; reason=%{public}d",
                log: log,
                type: .error,
                reasonCode
            )
        #endif
    }
}
