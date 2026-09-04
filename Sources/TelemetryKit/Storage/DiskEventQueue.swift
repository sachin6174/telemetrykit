import Foundation

/// An actor-isolated, append-only, file-backed event queue.
///
/// Every event lives in its own atomically replaced file. There is deliberately
/// no separate index to become inconsistent after a process termination. The
/// actor reconstructs ordering from each envelope's persisted sequence number.
internal actor DiskEventQueue {
    private struct Entry: Sendable {
        let id: UUID
        let sequence: UInt64
        let createdAt: Date
        let payloadByteCount: Int
        let fileURL: URL

        init(envelope: StoredEnvelope, fileURL: URL) {
            id = envelope.id
            sequence = envelope.sequence
            createdAt = envelope.createdAt
            payloadByteCount = envelope.payload.count
            self.fileURL = fileURL
        }
    }

    private static let fileExtension = "tkevent"
    private static let purgeMarkerName = ".telemetrykit-purge-required"
    private static let maximumEnvelopeOverhead = 64 * 1_024

    private let directory: URL
    private let limits: TelemetryQueueLimits
    private var entries: [Entry]
    private var payloadByteCount: Int
    private var nextSequence: UInt64

    internal init(directory: URL, limits: TelemetryQueueLimits) throws {
        guard limits.maximumEventCount > 0,
            limits.maximumDiskBytes > 0,
            limits.maximumEventBytes > 0,
            limits.maximumEventAge > 0,
            limits.maximumEventBytes <= limits.maximumDiskBytes
        else {
            throw DiskEventQueueError.invalidLimits
        }

        let normalizedDirectory = directory.standardizedFileURL
        try TelemetryFileProtection.prepareDirectory(at: normalizedDirectory)
        try Self.completePendingPurge(in: normalizedDirectory)

        var recovered = try Self.recoverEntries(
            from: normalizedDirectory,
            limits: limits
        )
        recovered.sort { lhs, rhs in
            if lhs.sequence == rhs.sequence {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.sequence < rhs.sequence
        }

        recovered = try Self.removeDuplicateIdentifiers(from: recovered)
        recovered = try Self.trimRecoveredEntries(recovered, to: limits, now: Date())

        let highestSequence = recovered.last?.sequence
        if highestSequence == UInt64.max {
            throw DiskEventQueueError.sequenceExhausted
        }

        self.directory = normalizedDirectory
        self.limits = limits
        self.entries = recovered
        self.payloadByteCount = recovered.reduce(into: 0) { total, entry in
            total = Self.addingWithoutOverflow(total, entry.payloadByteCount)
        }
        self.nextSequence = highestSequence.map { $0 + 1 } ?? 0
    }

    internal func enqueue(
        payload: Data,
        id: UUID,
        createdAt: Date
    ) throws -> QueueEnqueueResult {
        guard payload.count <= limits.maximumEventBytes,
            payload.count <= limits.maximumDiskBytes
        else {
            return .rejectedOversized
        }

        try pruneExpired(now: Date())

        // Retried submissions with the same identity are idempotent.
        if entries.contains(where: { $0.id == id }) {
            return .accepted
        }

        let requiredCount = entries.count + 1
        let requiredBytes = Self.addingWithoutOverflow(payloadByteCount, payload.count)
        let exceedsLimits =
            requiredCount > limits.maximumEventCount
            || requiredBytes > limits.maximumDiskBytes

        if exceedsLimits, limits.overflowPolicy == .dropNewest {
            return .rejectedFull
        }

        guard nextSequence < UInt64.max else {
            throw DiskEventQueueError.sequenceExhausted
        }

        var entriesToDrop: [Entry] = []
        if exceedsLimits {
            var projectedCount = requiredCount
            var projectedBytes = requiredBytes
            for candidate in entries {
                guard
                    projectedCount > limits.maximumEventCount
                        || projectedBytes > limits.maximumDiskBytes
                else {
                    break
                }
                entriesToDrop.append(candidate)
                projectedCount -= 1
                projectedBytes -= candidate.payloadByteCount
            }
        }

        let envelope = StoredEnvelope(
            id: id,
            sequence: nextSequence,
            createdAt: createdAt,
            payload: payload
        )
        let destination = fileURL(for: envelope)
        try persist(envelope, to: destination)

        // Persist first. A termination between this write and eviction can only
        // create a recoverable over-limit queue; it cannot lose both old and new
        // telemetry. Initialization deterministically restores the configured cap.
        let newEntry = Entry(envelope: envelope, fileURL: destination)
        entries.append(newEntry)
        payloadByteCount = Self.addingWithoutOverflow(payloadByteCount, payload.count)
        nextSequence += 1

        do {
            try removeEntries(entriesToDrop)
        } catch {
            // Best-effort rollback keeps the actor's in-memory view consistent.
            try? FileManager.default.removeItem(at: destination)
            entries.removeAll { $0.id == id }
            payloadByteCount = max(0, payloadByteCount - payload.count)
            throw error
        }

        if entriesToDrop.isEmpty {
            return .accepted
        }
        return .acceptedAfterDroppingOldest(entriesToDrop.count)
    }

    /// Returns the oldest non-expired prefix that fits both batch limits.
    internal func peekBatch(
        maxCount: Int,
        maxBytes: Int,
        now: Date
    ) throws -> [StoredEnvelope] {
        guard maxCount > 0, maxBytes > 0 else {
            throw DiskEventQueueError.invalidBatchLimits
        }

        try pruneExpired(now: now)

        var batch: [StoredEnvelope] = []
        batch.reserveCapacity(min(maxCount, entries.count))
        var bytes = 0

        let candidates = Array(entries.prefix(maxCount))
        for entry in candidates {
            let prospectiveBytes = Self.addingWithoutOverflow(bytes, entry.payloadByteCount)
            guard prospectiveBytes <= maxBytes else {
                break
            }
            batch.append(try loadEnvelope(for: entry))
            bytes = prospectiveBytes
        }
        return batch
    }

    internal func remove(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        let identifiers = Set(ids)
        let matches = entries.filter { identifiers.contains($0.id) }
        try removeEntries(matches)
    }

    internal func removeAll() throws {
        let marker = directory.appendingPathComponent(Self.purgeMarkerName)
        if !FileManager.default.fileExists(atPath: marker.path) {
            try TelemetryFileProtection.writeAtomically(Data([0x31]), to: marker)
        }

        do {
            try Self.removeQueueArtifacts(in: directory, preservingPurgeMarker: true)
            entries.removeAll(keepingCapacity: true)
            payloadByteCount = 0
            try FileManager.default.removeItem(at: marker)
        } catch {
            // Keep accounting aligned with partial deletion. The marker remains
            // as a fail-closed tombstone for the next initialization.
            entries.removeAll { !FileManager.default.fileExists(atPath: $0.fileURL.path) }
            payloadByteCount = entries.reduce(into: 0) { total, entry in
                total = Self.addingWithoutOverflow(total, entry.payloadByteCount)
            }
            throw DiskEventQueueError.unableToRemoveEvent(error.localizedDescription)
        }
    }

    /// Rewrites recovered records through the current privacy policy before
    /// any delivery can begin. Returning `nil` drops the record durably.
    @discardableResult
    internal func reconcilePayloads(
        _ transform: @Sendable (StoredEnvelope) -> Data?
    ) throws -> Int {
        var reconciled: [Entry] = []
        reconciled.reserveCapacity(entries.count)
        var reconciledBytes = 0
        var droppedCount = 0

        for entry in entries {
            let storedEnvelope = try loadEnvelope(for: entry)
            guard let payload = transform(storedEnvelope),
                payload.count <= limits.maximumEventBytes
            else {
                do {
                    try Self.removeFileIfPresent(entry.fileURL)
                } catch {
                    throw DiskEventQueueError.unableToRemoveEvent(error.localizedDescription)
                }
                droppedCount += 1
                continue
            }

            if payload == storedEnvelope.payload {
                try retainReconciledEntry(
                    entry,
                    entries: &reconciled,
                    byteCount: &reconciledBytes,
                    droppedCount: &droppedCount
                )
                continue
            }

            let envelope = StoredEnvelope(
                id: entry.id,
                sequence: entry.sequence,
                createdAt: entry.createdAt,
                payload: payload
            )
            try persist(envelope, to: entry.fileURL)
            try retainReconciledEntry(
                Entry(envelope: envelope, fileURL: entry.fileURL),
                entries: &reconciled,
                byteCount: &reconciledBytes,
                droppedCount: &droppedCount
            )
        }

        entries = reconciled
        payloadByteCount = reconciledBytes
        return droppedCount
    }

    internal func status() -> TelemetryQueueStatus {
        TelemetryQueueStatus(
            eventCount: entries.count,
            byteCount: payloadByteCount,
            oldestEventDate: entries.lazy.map(\.createdAt).min()
        )
    }

    /// Returns a payload-free watermark for bounded flush operations.
    internal func latestSequence() -> UInt64? {
        entries.last?.sequence
    }

    private func pruneExpired(now: Date) throws {
        let expired = entries.filter { entry in
            now.timeIntervalSince(entry.createdAt) > limits.maximumEventAge
        }
        try removeEntries(expired)
    }

    private func removeEntries(_ entriesToRemove: [Entry]) throws {
        guard !entriesToRemove.isEmpty else { return }

        var removedIdentifiers = Set<UUID>()
        var removedBytes = 0
        for entry in entriesToRemove {
            do {
                if FileManager.default.fileExists(atPath: entry.fileURL.path) {
                    try FileManager.default.removeItem(at: entry.fileURL)
                }
                removedIdentifiers.insert(entry.id)
                removedBytes = Self.addingWithoutOverflow(
                    removedBytes,
                    entry.payloadByteCount
                )
            } catch {
                // Reflect every successful deletion before surfacing the error.
                entries.removeAll { removedIdentifiers.contains($0.id) }
                payloadByteCount = max(0, payloadByteCount - removedBytes)
                throw DiskEventQueueError.unableToRemoveEvent(error.localizedDescription)
            }
        }

        entries.removeAll { removedIdentifiers.contains($0.id) }
        payloadByteCount = max(0, payloadByteCount - removedBytes)
    }

    private func loadEnvelope(for entry: Entry) throws -> StoredEnvelope {
        do {
            let maximumEncodedSize = Self.addingWithoutOverflow(
                limits.maximumEventBytes,
                Self.maximumEnvelopeOverhead
            )
            let resourceValues = try entry.fileURL.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = resourceValues.fileSize,
                fileSize > 0,
                fileSize <= maximumEncodedSize
            else {
                throw DiskEventQueueError.unableToReadQueue(
                    "A queue record has an invalid encoded size."
                )
            }
            let data = try Data(contentsOf: entry.fileURL, options: .mappedIfSafe)
            let envelope = try PropertyListDecoder().decode(StoredEnvelope.self, from: data)
            guard envelope.id == entry.id,
                envelope.sequence == entry.sequence,
                envelope.createdAt == entry.createdAt,
                envelope.payload.count == entry.payloadByteCount,
                envelope.payload.count <= limits.maximumEventBytes
            else {
                throw DiskEventQueueError.unableToReadQueue(
                    "A queue record changed after recovery."
                )
            }
            return envelope
        } catch {
            do {
                try removeEntries([entry])
            } catch {
                throw DiskEventQueueError.unableToRemoveEvent(error.localizedDescription)
            }
            throw DiskEventQueueError.unableToReadQueue(error.localizedDescription)
        }
    }

    private func retainReconciledEntry(
        _ entry: Entry,
        entries reconciled: inout [Entry],
        byteCount: inout Int,
        droppedCount: inout Int
    ) throws {
        reconciled.append(entry)
        byteCount = Self.addingWithoutOverflow(byteCount, entry.payloadByteCount)
        while reconciled.count > limits.maximumEventCount
            || byteCount > limits.maximumDiskBytes
        {
            let index =
                limits.overflowPolicy == .dropOldest
                ? reconciled.startIndex : reconciled.index(before: reconciled.endIndex)
            let overflow = reconciled.remove(at: index)
            byteCount = max(0, byteCount - overflow.payloadByteCount)
            do {
                try Self.removeFileIfPresent(overflow.fileURL)
            } catch {
                throw DiskEventQueueError.unableToRemoveEvent(error.localizedDescription)
            }
            droppedCount += 1
        }
    }

    private func persist(_ envelope: StoredEnvelope, to fileURL: URL) throws {
        do {
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let data = try encoder.encode(envelope)
            try TelemetryFileProtection.writeAtomically(data, to: fileURL)
        } catch let error as DiskEventQueueError {
            throw error
        } catch {
            throw DiskEventQueueError.unableToPersistEvent(error.localizedDescription)
        }
    }

    private func fileURL(for envelope: StoredEnvelope) -> URL {
        let rawSequence = String(envelope.sequence)
        let sequence =
            String(
                repeating: "0",
                count: max(0, 20 - rawSequence.count)
            ) + rawSequence
        let filename = "\(sequence)-\(envelope.id.uuidString.lowercased()).\(Self.fileExtension)"
        return directory.appendingPathComponent(filename, isDirectory: false)
    }
}

extension DiskEventQueue {
    private static func recoverEntries(
        from directory: URL,
        limits: TelemetryQueueLimits
    ) throws -> [Entry] {
        var enumerationFailure: Error?
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, error in
                    enumerationFailure = error
                    return false
                }
            )
        else {
            throw DiskEventQueueError.unableToReadQueue(
                "The queue directory could not be enumerated."
            )
        }

        var result: [Entry] = []
        result.reserveCapacity(min(limits.maximumEventCount, 1_024))
        var retainedIdentifiers: [UUID: Entry] = [:]
        retainedIdentifiers.reserveCapacity(min(limits.maximumEventCount, 1_024))
        var retainedPayloadBytes = 0
        let decoder = PropertyListDecoder()
        let recoveryDate = Date()

        for case let fileURL as URL in enumerator {
            if isTemporaryQueueArtifact(fileURL) {
                try removeFileIfPresent(fileURL)
                continue
            }
            guard fileURL.pathExtension == fileExtension else { continue }

            let recoveredEntry: Entry
            do {
                let maximumEncodedSize = addingWithoutOverflow(
                    limits.maximumEventBytes,
                    maximumEnvelopeOverhead
                )
                let resourceValues = try fileURL.resourceValues(forKeys: [.fileSizeKey])
                guard let fileSize = resourceValues.fileSize,
                    fileSize > 0,
                    fileSize <= maximumEncodedSize
                else {
                    throw DiskEventQueueError.unableToReadQueue(
                        "A queue record has an invalid encoded size."
                    )
                }

                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                let envelope = try decoder.decode(StoredEnvelope.self, from: data)
                guard envelope.payload.count <= limits.maximumEventBytes else {
                    throw DiskEventQueueError.unableToReadQueue(
                        "A queue record exceeds the configured event limit."
                    )
                }
                guard
                    recoveryDate.timeIntervalSince(envelope.createdAt)
                        <= limits.maximumEventAge
                else {
                    throw DiskEventQueueError.unableToReadQueue(
                        "A queue record has expired."
                    )
                }
                recoveredEntry = Entry(envelope: envelope, fileURL: fileURL)
            } catch {
                // An unreadable record cannot be safely uploaded or inspected. It
                // is removed rather than quarantined with potentially private data.
                do {
                    try removeFileIfPresent(fileURL)
                } catch {
                    throw DiskEventQueueError.unableToRemoveEvent(error.localizedDescription)
                }
                continue
            }

            if let existing = retainedIdentifiers[recoveredEntry.id] {
                let keepRecovered = recoveryEntryIsOrderedBefore(recoveredEntry, existing)
                let duplicate = keepRecovered ? existing : recoveredEntry
                do {
                    try removeFileIfPresent(duplicate.fileURL)
                } catch {
                    throw DiskEventQueueError.unableToRemoveEvent(error.localizedDescription)
                }
                guard keepRecovered else {
                    continue
                }
                guard
                    let existingIndex = result.firstIndex(where: {
                        $0.id == recoveredEntry.id
                    })
                else {
                    throw DiskEventQueueError.unableToReadQueue(
                        "Recovered queue identity bookkeeping became inconsistent."
                    )
                }
                retainedPayloadBytes = max(
                    0,
                    retainedPayloadBytes - existing.payloadByteCount
                )
                result[existingIndex] = recoveredEntry
                retainedIdentifiers[recoveredEntry.id] = recoveredEntry
                retainedPayloadBytes = addingWithoutOverflow(
                    retainedPayloadBytes,
                    recoveredEntry.payloadByteCount
                )
            } else {
                result.append(recoveredEntry)
                retainedIdentifiers[recoveredEntry.id] = recoveredEntry
                retainedPayloadBytes = addingWithoutOverflow(
                    retainedPayloadBytes,
                    recoveredEntry.payloadByteCount
                )
            }
            while result.count > limits.maximumEventCount
                || retainedPayloadBytes > limits.maximumDiskBytes
            {
                guard
                    let overflowIndex = recoveryOverflowIndex(
                        in: result,
                        policy: limits.overflowPolicy
                    )
                else {
                    break
                }
                let overflow = result.remove(at: overflowIndex)
                retainedIdentifiers.removeValue(forKey: overflow.id)
                retainedPayloadBytes = max(
                    0,
                    retainedPayloadBytes - overflow.payloadByteCount
                )
                do {
                    try removeFileIfPresent(overflow.fileURL)
                } catch {
                    throw DiskEventQueueError.unableToRemoveEvent(
                        error.localizedDescription
                    )
                }
            }
        }
        if let enumerationFailure {
            throw DiskEventQueueError.unableToReadQueue(
                enumerationFailure.localizedDescription
            )
        }
        return result
    }

    private static func completePendingPurge(in directory: URL) throws {
        let marker = directory.appendingPathComponent(purgeMarkerName)
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        do {
            try removeQueueArtifacts(in: directory, preservingPurgeMarker: true)
            try removeFileIfPresent(marker)
        } catch {
            throw DiskEventQueueError.unableToRemoveEvent(error.localizedDescription)
        }
    }

    private static func removeQueueArtifacts(
        in directory: URL,
        preservingPurgeMarker: Bool
    ) throws {
        var enumerationFailure: Error?
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants],
                errorHandler: { _, error in
                    enumerationFailure = error
                    return false
                }
            )
        else {
            throw DiskEventQueueError.unableToReadQueue(
                "The queue directory could not be enumerated."
            )
        }

        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent
            if preservingPurgeMarker, name == purgeMarkerName { continue }
            guard
                fileURL.pathExtension == fileExtension
                    || isTemporaryQueueArtifact(fileURL)
            else {
                continue
            }
            try removeFileIfPresent(fileURL)
        }
        if let enumerationFailure {
            throw DiskEventQueueError.unableToReadQueue(
                enumerationFailure.localizedDescription
            )
        }
    }

    private static func isTemporaryQueueArtifact(_ fileURL: URL) -> Bool {
        let name = fileURL.lastPathComponent
        return name.contains(".\(fileExtension).tmp-")
            || name.hasPrefix("\(purgeMarkerName).tmp-")
    }

    private static func removeFileIfPresent(_ fileURL: URL) throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func recoveryOverflowIndex(
        in entries: [Entry],
        policy: TelemetryQueueOverflowPolicy
    ) -> Int? {
        let comparison: (Entry, Entry) -> Bool
        switch policy {
        case .dropNewest:
            comparison = { $0.sequence > $1.sequence }
        case .dropOldest:
            comparison = { $0.sequence < $1.sequence }
        }
        return entries.indices.reduce(nil as Int?) { selectedIndex, candidateIndex in
            guard let selectedIndex else { return candidateIndex }
            return comparison(entries[candidateIndex], entries[selectedIndex])
                ? candidateIndex
                : selectedIndex
        }
    }

    private static func recoveryEntryIsOrderedBefore(_ lhs: Entry, _ rhs: Entry) -> Bool {
        if lhs.sequence != rhs.sequence {
            return lhs.sequence < rhs.sequence
        }
        return lhs.fileURL.lastPathComponent < rhs.fileURL.lastPathComponent
    }

    private static func removeDuplicateIdentifiers(from entries: [Entry]) throws -> [Entry] {
        var identifiers = Set<UUID>()
        var unique: [Entry] = []
        for entry in entries {
            if identifiers.insert(entry.id).inserted {
                unique.append(entry)
            } else {
                do {
                    try FileManager.default.removeItem(at: entry.fileURL)
                } catch {
                    throw DiskEventQueueError.unableToRemoveEvent(error.localizedDescription)
                }
            }
        }
        return unique
    }

    private static func trimRecoveredEntries(
        _ entries: [Entry],
        to limits: TelemetryQueueLimits,
        now: Date
    ) throws -> [Entry] {
        var retained = entries
        let expired = retained.filter {
            now.timeIntervalSince($0.createdAt) > limits.maximumEventAge
        }
        try removeRecoveredEntries(expired)
        let expiredIdentifiers = Set(expired.map(\.id))
        retained.removeAll { expiredIdentifiers.contains($0.id) }

        var byteCount = retained.reduce(into: 0) { total, entry in
            total = addingWithoutOverflow(total, entry.payloadByteCount)
        }
        var overflow: [Entry] = []
        while retained.count > limits.maximumEventCount
            || byteCount > limits.maximumDiskBytes
        {
            let index =
                limits.overflowPolicy == .dropOldest
                ? retained.startIndex : retained.index(before: retained.endIndex)
            let entry = retained.remove(at: index)
            byteCount = max(0, byteCount - entry.payloadByteCount)
            overflow.append(entry)
        }

        if !overflow.isEmpty {
            try removeRecoveredEntries(overflow)
        }
        return retained
    }

    private static func removeRecoveredEntries(_ entries: [Entry]) throws {
        for entry in entries {
            do {
                if FileManager.default.fileExists(atPath: entry.fileURL.path) {
                    try FileManager.default.removeItem(at: entry.fileURL)
                }
            } catch {
                throw DiskEventQueueError.unableToRemoveEvent(error.localizedDescription)
            }
        }
    }

    fileprivate static func addingWithoutOverflow(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }
}
