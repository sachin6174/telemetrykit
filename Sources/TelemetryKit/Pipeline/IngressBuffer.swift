import Foundation

internal struct PendingEvent: Sendable {
    let id: UUID
    let createdAt: Date
    let category: TelemetryCategory
    let payload: Data

    var byteCount: Int { payload.count }
}

internal struct IngressSnapshot: Sendable {
    let events: [PendingEvent]
    let byteCount: Int
}

internal enum IngressCaptureAdmission: Sendable, Equatable {
    case allowed(revision: UInt64)
    case rejected(TelemetryCaptureResult)
}

/// A small synchronous boundary in front of the actor pipeline.
///
/// Calls to `capture` never allocate a task. Producers briefly take this lock,
/// append one already-encoded value, and signal the single long-lived consumer.
/// Both count and encoded bytes are bounded.
internal final class IngressBuffer: @unchecked Sendable {
    private enum State {
        case accepting(TelemetryConsent)
        case stopped
    }

    private let lock = NSLock()
    private let limits: TelemetryQueueLimits
    private let enabledCategories: Set<TelemetryCategory>
    private var state: State
    private var revision: UInt64 = 0
    private var events: [PendingEvent] = []
    private var bytes = 0

    init(
        limits: TelemetryQueueLimits,
        enabledCategories: Set<TelemetryCategory>,
        consent: TelemetryConsent
    ) {
        self.limits = limits
        self.enabledCategories = enabledCategories
        self.state = .accepting(consent)
        events.reserveCapacity(min(limits.maximumMemoryEventCount, 512))
    }

    /// Returns a revision token that prevents work begun before an erase or
    /// consent transition from being admitted after the boundary has passed.
    func beginCapture(category: TelemetryCategory) -> IngressCaptureAdmission {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .stopped:
            return .rejected(.clientStopped)
        case .accepting(.pending):
            return .rejected(.consentRequired)
        case .accepting(.denied):
            return .rejected(.collectionDisabled)
        case .accepting(.granted):
            return enabledCategories.contains(category)
                ? .allowed(revision: revision)
                : .rejected(.collectionDisabled)
        }
    }

    func offer(_ event: PendingEvent) -> TelemetryCaptureResult {
        offer(event, admissionRevision: nil)
    }

    func offer(
        _ event: PendingEvent,
        admissionRevision: UInt64?
    ) -> TelemetryCaptureResult {
        lock.lock()
        defer { lock.unlock() }

        switch state {
        case .stopped:
            return .clientStopped
        case .accepting(.pending):
            return .consentRequired
        case .accepting(.denied):
            return .collectionDisabled
        case .accepting(.granted):
            break
        }

        if let admissionRevision, admissionRevision != revision {
            return .collectionDisabled
        }

        guard enabledCategories.contains(event.category) else {
            return .collectionDisabled
        }
        guard event.byteCount <= limits.maximumEventBytes,
            event.byteCount <= limits.maximumMemoryBytes
        else {
            return .eventTooLarge
        }

        let prospectiveBytes = Self.addingWithoutOverflow(bytes, event.byteCount)
        let wouldExceedCount = events.count + 1 > limits.maximumMemoryEventCount
        let wouldExceedBytes = prospectiveBytes > limits.maximumMemoryBytes
        if wouldExceedCount || wouldExceedBytes {
            switch limits.overflowPolicy {
            case .dropNewest:
                return .queueFull
            case .dropOldest:
                while !events.isEmpty,
                    events.count + 1 > limits.maximumMemoryEventCount
                        || Self.addingWithoutOverflow(bytes, event.byteCount)
                            > limits.maximumMemoryBytes
                {
                    bytes -= events.removeFirst().byteCount
                }
            }
        }

        guard events.count + 1 <= limits.maximumMemoryEventCount,
            Self.addingWithoutOverflow(bytes, event.byteCount) <= limits.maximumMemoryBytes
        else {
            return .queueFull
        }

        events.append(event)
        bytes = Self.addingWithoutOverflow(bytes, event.byteCount)
        return .accepted
    }

    func drain() -> IngressSnapshot {
        lock.lock()
        defer { lock.unlock() }

        let snapshot = IngressSnapshot(events: events, byteCount: bytes)
        events.removeAll(keepingCapacity: true)
        bytes = 0
        return snapshot
    }

    /// Restores events that could not be persisted. Events accepted while the
    /// actor was writing are merged according to the configured overflow rule.
    func restore(_ olderEvents: [PendingEvent]) {
        guard !olderEvents.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard case .accepting(.granted) = state else { return }

        var combined = olderEvents + events
        var combinedBytes = combined.reduce(into: 0) { total, event in
            let (sum, overflow) = total.addingReportingOverflow(event.byteCount)
            total = overflow ? Int.max : sum
        }

        while !combined.isEmpty,
            combined.count > limits.maximumMemoryEventCount
                || combinedBytes > limits.maximumMemoryBytes
        {
            let removed: PendingEvent
            switch limits.overflowPolicy {
            case .dropNewest:
                removed = combined.removeLast()
            case .dropOldest:
                removed = combined.removeFirst()
            }
            combinedBytes = max(0, combinedBytes - removed.byteCount)
        }

        events = combined
        bytes = combinedBytes
    }

    func updateConsent(_ consent: TelemetryConsent) {
        lock.lock()
        defer { lock.unlock() }

        guard case .accepting = state else { return }
        revision &+= 1
        state = .accepting(consent)
        if consent != .granted {
            events.removeAll(keepingCapacity: true)
            bytes = 0
        }
    }

    func erase() {
        lock.lock()
        defer { lock.unlock() }
        revision &+= 1
        events.removeAll(keepingCapacity: true)
        bytes = 0
    }

    func stopAccepting() {
        lock.lock()
        defer { lock.unlock() }
        revision &+= 1
        state = .stopped
    }

    func status() -> (eventCount: Int, byteCount: Int, oldestDate: Date?) {
        lock.lock()
        defer { lock.unlock() }
        return (events.count, bytes, events.first?.createdAt)
    }

    private static func addingWithoutOverflow(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}
