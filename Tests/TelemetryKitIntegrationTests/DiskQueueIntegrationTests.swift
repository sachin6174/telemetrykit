import Foundation
import XCTest

@testable import TelemetryKit

final class DiskQueueIntegrationTests: XCTestCase, @unchecked Sendable {
    func testStorageDirectoryLeasePreventsConcurrentOwnershipAndCanBeReleased() throws {
        let directory = try makeTemporaryDirectory()
        let first = try StorageDirectoryLease.acquire(for: directory)

        XCTAssertThrowsError(try StorageDirectoryLease.acquire(for: directory)) { error in
            guard let telemetryError = error as? TelemetryError,
                case .storageUnavailable = telemetryError
            else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        first.release()
        let replacement = try StorageDirectoryLease.acquire(for: directory)
        replacement.release()
    }

    func testQueueRejectsInvalidConstructionAndBatchLimits() async throws {
        let invalidDirectory = try makeTemporaryDirectory()
        var invalidLimits = makeLimits()
        invalidLimits.maximumEventCount = 0

        XCTAssertThrowsError(try DiskEventQueue(directory: invalidDirectory, limits: invalidLimits)) {
            XCTAssertEqual($0 as? DiskEventQueueError, .invalidLimits)
        }

        let queue = try DiskEventQueue(
            directory: try makeTemporaryDirectory(),
            limits: makeLimits()
        )
        do {
            _ = try await queue.peekBatch(maxCount: 0, maxBytes: 1, now: Date())
            XCTFail("Expected an invalid batch limit error")
        } catch {
            XCTAssertEqual(error as? DiskEventQueueError, .invalidBatchLimits)
        }
        do {
            _ = try await queue.peekBatch(maxCount: 1, maxBytes: 0, now: Date())
            XCTFail("Expected an invalid batch limit error")
        } catch {
            XCTAssertEqual(error as? DiskEventQueueError, .invalidBatchLimits)
        }
    }

    func testExistingFileCannotBeUsedAsQueueDirectory() throws {
        let parent = try makeTemporaryDirectory()
        let file = parent.appendingPathComponent("occupied")
        try Data("file".utf8).write(to: file)

        XCTAssertThrowsError(try DiskEventQueue(directory: file, limits: makeLimits())) { error in
            guard case .unableToCreateDirectory = error as? DiskEventQueueError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDuplicateEnqueueIsIdempotentAndKeepsOriginalPayload() async throws {
        let queue = try DiskEventQueue(
            directory: try makeTemporaryDirectory(),
            limits: makeLimits()
        )
        let id = UUID()
        let createdAt = Date().addingTimeInterval(60)

        let firstResult = try await queue.enqueue(
            payload: Data("first".utf8),
            id: id,
            createdAt: createdAt
        )
        let duplicateResult = try await queue.enqueue(
            payload: Data("replacement".utf8),
            id: id,
            createdAt: createdAt
        )
        XCTAssertEqual(firstResult, .accepted)
        XCTAssertEqual(duplicateResult, .accepted)

        let batch = try await queue.peekBatch(maxCount: 10, maxBytes: 100, now: createdAt)
        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(batch.first?.payload, Data("first".utf8))
        let status = await queue.status()
        XCTAssertEqual(status.eventCount, 1)
    }

    func testPeekReturnsOnlyOldestPrefixThatFitsBothLimits() async throws {
        let queue = try DiskEventQueue(
            directory: try makeTemporaryDirectory(),
            limits: makeLimits(maximumEventCount: 10, maximumDiskBytes: 100, maximumEventBytes: 20)
        )
        let now = Date().addingTimeInterval(60)
        let identifiers = [UUID(), UUID(), UUID()]
        for (index, size) in [3, 4, 2].enumerated() {
            _ = try await queue.enqueue(
                payload: Data(repeating: UInt8(index), count: size),
                id: identifiers[index],
                createdAt: now.addingTimeInterval(TimeInterval(index))
            )
        }

        let countLimited = try await queue.peekBatch(maxCount: 2, maxBytes: 100, now: now)
        let byteLimited = try await queue.peekBatch(maxCount: 10, maxBytes: 7, now: now)
        let blockedByHead = try await queue.peekBatch(maxCount: 10, maxBytes: 2, now: now)
        XCTAssertEqual(countLimited.map(\.id), Array(identifiers.prefix(2)))
        XCTAssertEqual(byteLimited.map(\.id), Array(identifiers.prefix(2)))
        XCTAssertTrue(
            blockedByHead.isEmpty,
            "A later small event must not jump ahead of an oversized FIFO head"
        )
    }

    func testRemoveSpecificIdentifiersAndRemoveAllUpdateDurableStatus() async throws {
        let directory = try makeTemporaryDirectory()
        let queue = try DiskEventQueue(directory: directory, limits: makeLimits())
        let identifiers = [UUID(), UUID(), UUID()]
        let now = Date().addingTimeInterval(60)
        for id in identifiers {
            _ = try await queue.enqueue(
                payload: Data(repeating: 1, count: 2),
                id: id,
                createdAt: now
            )
        }

        try await queue.remove(ids: [identifiers[1], UUID()])
        let statusAfterRemoval = await queue.status()
        XCTAssertEqual(statusAfterRemoval.eventCount, 2)
        XCTAssertEqual(statusAfterRemoval.byteCount, 4)

        let reopened = try DiskEventQueue(directory: directory, limits: makeLimits())
        let recovered = try await reopened.peekBatch(maxCount: 10, maxBytes: 100, now: now)
        XCTAssertEqual(recovered.map(\.id), [identifiers[0], identifiers[2]])

        try await reopened.removeAll()
        let emptyStatus = await reopened.status()
        let latestSequence = await reopened.latestSequence()
        XCTAssertEqual(emptyStatus.eventCount, 0)
        XCTAssertNil(latestSequence)
        let eventFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".tkevent") }
        XCTAssertTrue(eventFiles.isEmpty)
    }

    func testExpirationBoundaryIsExclusiveAndRemovalIsDurable() async throws {
        let directory = try makeTemporaryDirectory()
        let limits = makeLimits(maximumEventAge: 10)
        let queue = try DiskEventQueue(directory: directory, limits: limits)
        let createdAt = Date().addingTimeInterval(60)
        let id = UUID()
        _ = try await queue.enqueue(payload: Data([1]), id: id, createdAt: createdAt)

        let atBoundary = try await queue.peekBatch(
            maxCount: 1,
            maxBytes: 1,
            now: createdAt.addingTimeInterval(10)
        )
        let afterBoundary = try await queue.peekBatch(
            maxCount: 1,
            maxBytes: 1,
            now: createdAt.addingTimeInterval(10.001)
        )
        XCTAssertEqual(atBoundary.map(\.id), [id])
        XCTAssertTrue(afterBoundary.isEmpty)

        let reopened = try DiskEventQueue(directory: directory, limits: limits)
        let recoveredStatus = await reopened.status()
        XCTAssertEqual(recoveredStatus.eventCount, 0)
    }

    func testRecoveryOrdersByPersistedSequenceNotFilename() async throws {
        let directory = try makeTemporaryDirectory()
        let olderID = UUID()
        let newerID = UUID()
        let createdAt = Date()
        try writeEnvelope(
            StoredEnvelope(id: newerID, sequence: 9, createdAt: createdAt, payload: Data("new".utf8)),
            named: "000-first.tkevent",
            to: directory
        )
        try writeEnvelope(
            StoredEnvelope(id: olderID, sequence: 2, createdAt: createdAt, payload: Data("old".utf8)),
            named: "999-last.tkevent",
            to: directory
        )

        let queue = try DiskEventQueue(directory: directory, limits: makeLimits())
        let batch = try await queue.peekBatch(maxCount: 10, maxBytes: 100, now: createdAt)

        XCTAssertEqual(batch.map(\.id), [olderID, newerID])
        XCTAssertEqual(batch.map(\.sequence), [2, 9])
    }

    func testRecoveryRemovesDuplicateIdentifiersAndContinuesHighestSequence() async throws {
        let directory = try makeTemporaryDirectory()
        let duplicateID = UUID()
        let uniqueID = UUID()
        let now = Date()
        try writeEnvelope(
            StoredEnvelope(id: duplicateID, sequence: 1, createdAt: now, payload: Data("kept".utf8)),
            named: "duplicate-low.tkevent",
            to: directory
        )
        try writeEnvelope(
            StoredEnvelope(id: duplicateID, sequence: 4, createdAt: now, payload: Data("removed".utf8)),
            named: "duplicate-high.tkevent",
            to: directory
        )
        try writeEnvelope(
            StoredEnvelope(id: uniqueID, sequence: 7, createdAt: now, payload: Data("unique".utf8)),
            named: "unique.tkevent",
            to: directory
        )

        let queue = try DiskEventQueue(directory: directory, limits: makeLimits())
        let newID = UUID()
        _ = try await queue.enqueue(payload: Data("next".utf8), id: newID, createdAt: now)
        let batch = try await queue.peekBatch(maxCount: 10, maxBytes: 100, now: now)

        XCTAssertEqual(batch.map(\.id), [duplicateID, uniqueID, newID])
        XCTAssertEqual(batch.map(\.sequence), [1, 7, 8])
        XCTAssertEqual(batch.first?.payload, Data("kept".utf8))
        let latestSequence = await queue.latestSequence()
        XCTAssertEqual(latestSequence, 8)
    }

    func testRecoveryDeduplicatesBeforeApplyingQueueBounds() async throws {
        let directory = try makeTemporaryDirectory()
        let duplicateID = UUID()
        let uniqueID = UUID()
        let now = Date()
        try writeEnvelope(
            StoredEnvelope(id: duplicateID, sequence: 1, createdAt: now, payload: Data([1])),
            named: "a-duplicate-low.tkevent",
            to: directory
        )
        try writeEnvelope(
            StoredEnvelope(id: duplicateID, sequence: 2, createdAt: now, payload: Data([2])),
            named: "b-duplicate-high.tkevent",
            to: directory
        )
        try writeEnvelope(
            StoredEnvelope(id: uniqueID, sequence: 3, createdAt: now, payload: Data([3])),
            named: "c-unique.tkevent",
            to: directory
        )
        let limits = makeLimits(
            maximumEventCount: 2,
            maximumDiskBytes: 2,
            maximumEventBytes: 1,
            overflowPolicy: .dropNewest
        )

        let queue = try DiskEventQueue(directory: directory, limits: limits)
        let recovered = try await queue.peekBatch(maxCount: 2, maxBytes: 2, now: now)

        XCTAssertEqual(recovered.map(\.id), [duplicateID, uniqueID])
        XCTAssertEqual(recovered.map(\.sequence), [1, 3])
        XCTAssertEqual(recovered.first?.payload, Data([1]))
    }

    func testRecoveryHonorsDropNewestWhileRestoringBounds() async throws {
        let directory = try makeTemporaryDirectory()
        let now = Date()
        let identifiers = [UUID(), UUID(), UUID()]
        for index in identifiers.indices {
            try writeEnvelope(
                StoredEnvelope(
                    id: identifiers[index],
                    sequence: UInt64(index),
                    createdAt: now,
                    payload: Data(repeating: UInt8(index), count: 3)
                ),
                named: "record-\(index).tkevent",
                to: directory
            )
        }
        let limits = makeLimits(
            maximumEventCount: 2,
            maximumDiskBytes: 6,
            maximumEventBytes: 3,
            overflowPolicy: .dropNewest
        )

        let queue = try DiskEventQueue(directory: directory, limits: limits)
        let recovered = try await queue.peekBatch(maxCount: 10, maxBytes: 10, now: now)
        let status = await queue.status()
        XCTAssertEqual(recovered.map(\.id), Array(identifiers.prefix(2)))
        XCTAssertEqual(status.eventCount, 2)
        XCTAssertEqual(status.byteCount, 6)
    }

    func testRecoveryHonorsDropOldestWhileRestoringBounds() async throws {
        let directory = try makeTemporaryDirectory()
        let now = Date()
        let identifiers = [UUID(), UUID(), UUID()]
        for index in identifiers.indices {
            try writeEnvelope(
                StoredEnvelope(
                    id: identifiers[index],
                    sequence: UInt64(index),
                    createdAt: now,
                    payload: Data(repeating: UInt8(index), count: 3)
                ),
                named: "record-\(index).tkevent",
                to: directory
            )
        }
        let limits = makeLimits(
            maximumEventCount: 2,
            maximumDiskBytes: 6,
            maximumEventBytes: 3,
            overflowPolicy: .dropOldest
        )

        let queue = try DiskEventQueue(directory: directory, limits: limits)
        let recovered = try await queue.peekBatch(maxCount: 10, maxBytes: 10, now: now)
        XCTAssertEqual(recovered.map(\.id), Array(identifiers.suffix(2)))
    }

    func testRecoveryDeletesExpiredCorruptAndOversizedRecordsButIgnoresOtherFiles() async throws {
        let directory = try makeTemporaryDirectory()
        let now = Date()
        let validID = UUID()
        try writeEnvelope(
            StoredEnvelope(id: validID, sequence: 1, createdAt: now, payload: Data([1])),
            named: "valid.tkevent",
            to: directory
        )
        try writeEnvelope(
            StoredEnvelope(
                id: UUID(),
                sequence: 2,
                createdAt: now.addingTimeInterval(-101),
                payload: Data([2])
            ),
            named: "expired.tkevent",
            to: directory
        )
        try writeEnvelope(
            StoredEnvelope(
                id: UUID(),
                sequence: 3,
                createdAt: now,
                payload: Data(repeating: 3, count: 5)
            ),
            named: "oversized.tkevent",
            to: directory
        )
        try Data("not an envelope".utf8).write(
            to: directory.appendingPathComponent("corrupt.tkevent")
        )
        try Data("keep me".utf8).write(to: directory.appendingPathComponent("README.txt"))

        let queue = try DiskEventQueue(
            directory: directory,
            limits: makeLimits(maximumEventBytes: 4, maximumEventAge: 100)
        )
        let recovered = try await queue.peekBatch(maxCount: 10, maxBytes: 100, now: now)
        XCTAssertEqual(recovered.map(\.id), [validID])
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("README.txt").path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("expired.tkevent").path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("oversized.tkevent").path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("corrupt.tkevent").path))
    }

    func testEmptyPayloadDoesNotCorruptQueueAccounting() async throws {
        let directory = try makeTemporaryDirectory()
        let queue = try DiskEventQueue(directory: directory, limits: makeLimits())
        let now = Date().addingTimeInterval(60)
        let id = UUID()

        let result = try await queue.enqueue(payload: Data(), id: id, createdAt: now)
        let status = await queue.status()
        let batch = try await queue.peekBatch(maxCount: 1, maxBytes: 1, now: now)
        XCTAssertEqual(result, .accepted)
        XCTAssertEqual(status.eventCount, 1)
        XCTAssertEqual(status.byteCount, 0)
        XCTAssertEqual(batch.map(\.id), [id])
    }

    func testRemoveAllDeletesUntrackedAndTemporaryQueueArtifacts() async throws {
        let directory = try makeTemporaryDirectory()
        let queue = try DiskEventQueue(directory: directory, limits: makeLimits())
        let orphan = directory.appendingPathComponent("hidden-orphan.tkevent")
        let temporary = directory.appendingPathComponent("event.tkevent.tmp-deadbeef")
        let unrelated = directory.appendingPathComponent("README.txt")
        try Data("private".utf8).write(to: orphan)
        try Data("private".utf8).write(to: temporary)
        try Data("public".utf8).write(to: unrelated)

        try await queue.removeAll()

        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    func testPendingPurgeMarkerFailsClosedAcrossReinitialization() async throws {
        let directory = try makeTemporaryDirectory()
        let eventURL = directory.appendingPathComponent("surviving.tkevent")
        let markerURL = directory.appendingPathComponent(".telemetrykit-purge-required")
        try writeEnvelope(
            StoredEnvelope(
                id: UUID(),
                sequence: 1,
                createdAt: Date(),
                payload: Data("private".utf8)
            ),
            named: eventURL.lastPathComponent,
            to: directory
        )
        try Data([0x31]).write(to: markerURL)

        let queue = try DiskEventQueue(directory: directory, limits: makeLimits())

        let status = await queue.status()
        XCTAssertEqual(status.eventCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: eventURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: markerURL.path))
    }

    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        func testQueueDirectoryIsExcludedFromBackup() async throws {
            let directory = try makeTemporaryDirectory()
            _ = try DiskEventQueue(directory: directory, limits: makeLimits())

            let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
            XCTAssertEqual(values.isExcludedFromBackup, true)
        }
    #endif

    private func makeLimits(
        maximumEventCount: Int = 20,
        maximumDiskBytes: Int = 1_024,
        maximumEventBytes: Int = 128,
        maximumEventAge: TimeInterval = 3_600,
        overflowPolicy: TelemetryQueueOverflowPolicy = .dropOldest
    ) -> TelemetryQueueLimits {
        TelemetryQueueLimits(
            maximumMemoryEventCount: 20,
            maximumMemoryBytes: 1_024,
            maximumEventCount: maximumEventCount,
            maximumDiskBytes: maximumDiskBytes,
            maximumEventBytes: maximumEventBytes,
            maximumEventAge: maximumEventAge,
            overflowPolicy: overflowPolicy
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TelemetryKitIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func writeEnvelope(
        _ envelope: StoredEnvelope,
        named filename: String,
        to directory: URL
    ) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        try encoder.encode(envelope).write(
            to: directory.appendingPathComponent(filename),
            options: .atomic
        )
    }
}
