import Foundation

/// The collection channel for an event.
public enum TelemetryCategory: String, CaseIterable, Codable, Sendable, Hashable {
    case custom
    case network
    case session
    case span
    case metricKitMetric
    case metricKitDiagnostic
    case sdkDiagnostic
}

/// The severity attached to an event.
public enum TelemetryLevel: String, CaseIterable, Codable, Sendable, Hashable {
    case debug
    case info
    case warning
    case error
    case fatal
}

/// An immutable identity plus typed metadata describing one observation.
public struct TelemetryEvent: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var timestamp: Date
    public var level: TelemetryLevel
    public var category: TelemetryCategory
    public var attributes: [String: TelemetryValue]

    public init(
        id: UUID = UUID(),
        name: String,
        timestamp: Date = Date(),
        level: TelemetryLevel = .info,
        category: TelemetryCategory = .custom,
        attributes: [String: TelemetryValue] = [:]
    ) {
        self.id = id
        self.name = name
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.attributes = attributes
    }
}

/// Why an event was or was not accepted by the SDK.
public enum TelemetryCaptureResult: String, Codable, Sendable, Hashable {
    case accepted
    case collectionDisabled
    case consentRequired
    case invalidEvent
    case eventTooLarge
    case queueFull
    case clientStopped
}

/// A stable snapshot of the bounded offline queue.
public struct TelemetryQueueStatus: Codable, Sendable, Equatable {
    public let eventCount: Int
    public let byteCount: Int
    public let oldestEventDate: Date?

    public init(eventCount: Int, byteCount: Int, oldestEventDate: Date?) {
        self.eventCount = eventCount
        self.byteCount = byteCount
        self.oldestEventDate = oldestEventDate
    }
}

/// The result of a bounded flush operation.
public struct TelemetryFlushReport: Codable, Sendable, Equatable {
    public let uploadedEventCount: Int
    public let permanentlyDroppedEventCount: Int
    public let remainingEventCount: Int

    public init(
        uploadedEventCount: Int,
        permanentlyDroppedEventCount: Int,
        remainingEventCount: Int
    ) {
        self.uploadedEventCount = uploadedEventCount
        self.permanentlyDroppedEventCount = permanentlyDroppedEventCount
        self.remainingEventCount = remainingEventCount
    }
}
