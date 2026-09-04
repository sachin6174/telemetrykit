import Foundation

/// The stable, version-one record stored by ``DiskEventQueue``.
///
/// Keeping storage metadata separate from `TelemetryEvent` lets the queue evolve
/// without coupling its on-disk format to the public event encoding.
internal struct StoredEnvelope: Codable, Sendable, Equatable {
    internal let id: UUID
    internal let sequence: UInt64
    internal let createdAt: Date
    internal let payload: Data

    internal init(id: UUID, sequence: UInt64, createdAt: Date, payload: Data) {
        self.id = id
        self.sequence = sequence
        self.createdAt = createdAt
        self.payload = payload
    }
}

/// The result of attempting to append an item to the bounded disk queue.
internal enum QueueEnqueueResult: Sendable, Equatable {
    case accepted
    case acceptedAfterDroppingOldest(Int)
    case rejectedFull
    case rejectedOversized
}

internal enum DiskEventQueueError: Error, Sendable, Equatable {
    case invalidLimits
    case invalidBatchLimits
    case sequenceExhausted
    case unableToCreateDirectory(String)
    case unableToReadQueue(String)
    case unableToPersistEvent(String)
    case unableToRemoveEvent(String)
}
