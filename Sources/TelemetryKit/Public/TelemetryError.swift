import Foundation

/// Errors surfaced by client creation, flushing, and persistence operations.
public enum TelemetryError: Error, Sendable, Equatable {
    case invalidConfiguration(String)
    case storageUnavailable(String)
    case encodingFailed
    case transportFailed(String)
    case operationRejected(String)
    case flushTimedOut
    case clientStopped
}

extension TelemetryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message):
            return "Invalid TelemetryKit configuration: \(message)"
        case .storageUnavailable(let message):
            return "TelemetryKit storage is unavailable: \(message)"
        case .encodingFailed:
            return "TelemetryKit could not encode an event."
        case .transportFailed(let message):
            return "TelemetryKit could not deliver telemetry: \(message)"
        case .operationRejected(let message):
            return "TelemetryKit rejected the operation: \(message)"
        case .flushTimedOut:
            return "TelemetryKit did not finish flushing before the timeout."
        case .clientStopped:
            return "The TelemetryKit client has stopped."
        }
    }
}
