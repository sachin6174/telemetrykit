import Foundation

internal struct TelemetrySDKMetadata: Codable, Sendable {
    let name: String
    let version: String

    static let version = "0.1.0"
    static let current = TelemetrySDKMetadata(name: "telemetrykit-swift", version: version)
}

internal struct TelemetryUploadBatch: Codable, Sendable {
    /// A conservative allowance for the fixed batch keys, metadata, UUID, date,
    /// array delimiters, and one separating comma. Validation reserves this so
    /// every accepted maximum-sized event can fit in a one-event request.
    static let maximumEnvelopeOverhead = 512

    let schemaVersion: Int
    let batchID: UUID
    let sentAt: Date
    let sdk: TelemetrySDKMetadata
    let events: [TelemetryEvent]

    init(events: [TelemetryEvent], sentAt: Date = Date()) {
        self.schemaVersion = 1
        self.batchID = UUID()
        self.sentAt = sentAt
        self.sdk = .current
        self.events = events
    }
}
