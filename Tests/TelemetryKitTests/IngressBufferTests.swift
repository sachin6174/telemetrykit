import Foundation
import XCTest

@testable import TelemetryKit

final class IngressBufferTests: XCTestCase {
    func testConsentAndCategoryGatesRejectBeforeBuffering() {
        let pending = makeBuffer(consent: .pending)
        XCTAssertEqual(pending.offer(makeEvent()), .consentRequired)
        XCTAssertEqual(pending.status().eventCount, 0)

        let denied = makeBuffer(consent: .denied)
        XCTAssertEqual(denied.offer(makeEvent()), .collectionDisabled)
        XCTAssertEqual(denied.status().eventCount, 0)

        let categoryDisabled = makeBuffer(
            enabledCategories: [.network],
            consent: .granted
        )
        XCTAssertEqual(categoryDisabled.offer(makeEvent(category: .custom)), .collectionDisabled)
        XCTAssertEqual(categoryDisabled.status().eventCount, 0)
    }

    func testExactByteAndCountBoundariesAreAccepted() {
        let buffer = makeBuffer(maximumCount: 2, maximumBytes: 4, maximumEventBytes: 2)

        XCTAssertEqual(buffer.offer(makeEvent(byteCount: 2)), .accepted)
        XCTAssertEqual(buffer.offer(makeEvent(byteCount: 2)), .accepted)
        XCTAssertEqual(buffer.status().eventCount, 2)
        XCTAssertEqual(buffer.status().byteCount, 4)
    }

    func testOversizedEventIsRejectedWithoutEvictingBufferedEvents() {
        let retained = makeEvent(byteCount: 2)
        let buffer = makeBuffer(maximumCount: 2, maximumBytes: 4, maximumEventBytes: 2)
        XCTAssertEqual(buffer.offer(retained), .accepted)

        XCTAssertEqual(buffer.offer(makeEvent(byteCount: 3)), .eventTooLarge)
        let snapshot = buffer.drain()
        XCTAssertEqual(snapshot.events.map(\.id), [retained.id])
        XCTAssertEqual(snapshot.byteCount, 2)
    }

    func testDropNewestBackpressurePreservesExistingFIFOContents() {
        let first = makeEvent(byteCount: 2)
        let second = makeEvent(byteCount: 2)
        let rejected = makeEvent(byteCount: 1)
        let buffer = makeBuffer(
            maximumCount: 2,
            maximumBytes: 4,
            maximumEventBytes: 2,
            overflowPolicy: .dropNewest
        )

        XCTAssertEqual(buffer.offer(first), .accepted)
        XCTAssertEqual(buffer.offer(second), .accepted)
        XCTAssertEqual(buffer.offer(rejected), .queueFull)

        XCTAssertEqual(buffer.drain().events.map(\.id), [first.id, second.id])
    }

    func testDropOldestEvictsEnoughEventsForBothLimits() {
        let first = makeEvent(byteCount: 1)
        let second = makeEvent(byteCount: 2)
        let third = makeEvent(byteCount: 3)
        let buffer = makeBuffer(
            maximumCount: 3,
            maximumBytes: 4,
            maximumEventBytes: 3,
            overflowPolicy: .dropOldest
        )

        XCTAssertEqual(buffer.offer(first), .accepted)
        XCTAssertEqual(buffer.offer(second), .accepted)
        XCTAssertEqual(buffer.offer(third), .accepted)

        let snapshot = buffer.drain()
        XCTAssertEqual(snapshot.events.map(\.id), [third.id])
        XCTAssertEqual(snapshot.byteCount, 3)
    }

    func testDrainIsAtomicAndResetsStatus() {
        let first = makeEvent(createdAt: Date(timeIntervalSince1970: 10), byteCount: 2)
        let second = makeEvent(createdAt: Date(timeIntervalSince1970: 20), byteCount: 1)
        let buffer = makeBuffer()
        _ = buffer.offer(first)
        _ = buffer.offer(second)

        XCTAssertEqual(buffer.status().oldestDate, first.createdAt)
        let snapshot = buffer.drain()
        XCTAssertEqual(snapshot.events.map(\.id), [first.id, second.id])
        XCTAssertEqual(snapshot.byteCount, 3)
        XCTAssertEqual(buffer.status().eventCount, 0)
        XCTAssertEqual(buffer.status().byteCount, 0)
        XCTAssertNil(buffer.status().oldestDate)
        XCTAssertTrue(buffer.drain().events.isEmpty)
    }

    func testRestoreDropNewestPrioritizesOlderUnpersistedEvents() {
        let older = [makeEvent(), makeEvent()]
        let concurrentlyAccepted = makeEvent()
        let buffer = makeBuffer(maximumCount: 2, overflowPolicy: .dropNewest)
        _ = buffer.offer(concurrentlyAccepted)

        buffer.restore(older)

        XCTAssertEqual(buffer.drain().events.map(\.id), older.map(\.id))
    }

    func testRestoreDropOldestPrioritizesMostRecentEvents() {
        let oldest = makeEvent()
        let middle = makeEvent()
        let newest = makeEvent()
        let buffer = makeBuffer(maximumCount: 2, overflowPolicy: .dropOldest)
        _ = buffer.offer(newest)

        buffer.restore([oldest, middle])

        XCTAssertEqual(buffer.drain().events.map(\.id), [middle.id, newest.id])
    }

    func testConsentRevocationAndEraseRemoveBufferedPayloads() {
        let buffer = makeBuffer(consent: .granted)
        _ = buffer.offer(makeEvent(byteCount: 2))

        buffer.updateConsent(.denied)
        XCTAssertEqual(buffer.status().eventCount, 0)
        XCTAssertEqual(buffer.offer(makeEvent()), .collectionDisabled)

        buffer.updateConsent(.granted)
        XCTAssertEqual(buffer.offer(makeEvent()), .accepted)
        buffer.erase()
        XCTAssertEqual(buffer.status().eventCount, 0)
    }

    func testStopRejectsFutureEventsAndIsNotReversedByConsentUpdates() {
        let buffer = makeBuffer()
        buffer.stopAccepting()
        buffer.updateConsent(.granted)
        buffer.restore([makeEvent()])

        XCTAssertEqual(buffer.offer(makeEvent()), .clientStopped)
        XCTAssertEqual(buffer.status().eventCount, 0)
    }

    func testRestoreCannotReintroduceEventsAfterConsentRevocation() {
        let buffer = makeBuffer()
        let event = makeEvent()

        buffer.updateConsent(.denied)
        buffer.restore([event])

        XCTAssertEqual(buffer.status().eventCount, 0)
        buffer.updateConsent(.granted)
        XCTAssertEqual(buffer.status().eventCount, 0)
    }

    func testAdmissionRevisionRejectsCaptureThatCrossesPrivacyBoundary() {
        let buffer = makeBuffer()
        guard case .allowed(let consentRevision) = buffer.beginCapture(category: .custom) else {
            return XCTFail("Expected capture admission")
        }

        buffer.updateConsent(.denied)
        buffer.updateConsent(.granted)

        XCTAssertEqual(
            buffer.offer(makeEvent(), admissionRevision: consentRevision),
            .collectionDisabled
        )

        guard case .allowed(let eraseRevision) = buffer.beginCapture(category: .custom) else {
            return XCTFail("Expected capture admission")
        }
        buffer.erase()
        XCTAssertEqual(
            buffer.offer(makeEvent(), admissionRevision: eraseRevision),
            .collectionDisabled
        )
        XCTAssertEqual(buffer.status().eventCount, 0)
    }

    func testConcurrentProducersRemainWithinCountAndByteBounds() {
        let buffer = makeBuffer(
            maximumCount: 64,
            maximumBytes: 64,
            maximumEventBytes: 1,
            overflowPolicy: .dropNewest
        )

        DispatchQueue.concurrentPerform(iterations: 2_000) { index in
            _ = buffer.offer(
                PendingEvent(
                    id: UUID(),
                    createdAt: Date(timeIntervalSince1970: TimeInterval(index)),
                    category: .custom,
                    payload: Data([0xAB])
                )
            )
        }

        let status = buffer.status()
        XCTAssertEqual(status.eventCount, 64)
        XCTAssertEqual(status.byteCount, 64)
        XCTAssertEqual(buffer.drain().events.count, 64)
    }

    func testCaptureAdmissionPoolAppliesNonblockingPreEncodingBackpressure() {
        let pool = CaptureAdmissionPool(
            limits: TelemetryQueueLimits(
                maximumMemoryEventCount: 10,
                maximumMemoryBytes: 100,
                maximumEventCount: 10,
                maximumDiskBytes: 1_000,
                maximumEventBytes: 50
            )
        )

        XCTAssertTrue(pool.tryAcquire())
        XCTAssertTrue(pool.tryAcquire())
        XCTAssertFalse(pool.tryAcquire())
        pool.release()
        XCTAssertTrue(pool.tryAcquire())
    }

    private func makeBuffer(
        maximumCount: Int = 10,
        maximumBytes: Int = 100,
        maximumEventBytes: Int = 100,
        overflowPolicy: TelemetryQueueOverflowPolicy = .dropNewest,
        enabledCategories: Set<TelemetryCategory> = [.custom],
        consent: TelemetryConsent = .granted
    ) -> IngressBuffer {
        let limits = TelemetryQueueLimits(
            maximumMemoryEventCount: maximumCount,
            maximumMemoryBytes: maximumBytes,
            maximumEventCount: 100,
            maximumDiskBytes: 1_000,
            maximumEventBytes: maximumEventBytes,
            maximumEventAge: 3_600,
            overflowPolicy: overflowPolicy
        )
        return IngressBuffer(
            limits: limits,
            enabledCategories: enabledCategories,
            consent: consent
        )
    }

    private func makeEvent(
        category: TelemetryCategory = .custom,
        createdAt: Date = Date(),
        byteCount: Int = 1
    ) -> PendingEvent {
        PendingEvent(
            id: UUID(),
            createdAt: createdAt,
            category: category,
            payload: Data(repeating: 0xAB, count: byteCount)
        )
    }
}
