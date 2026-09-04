import Foundation
import XCTest

@testable import TelemetryKit

final class TelemetryClientIntegrationTests: XCTestCase, @unchecked Sendable {
    func testPendingConsentRejectsCaptureUntilGranted() async throws {
        let transport = ScriptedTransport(steps: [.response(202)])
        let configuration = try makeConfiguration(consent: .pending)
        let client = try await startClient(configuration: configuration, transport: transport)

        XCTAssertEqual(client.capture("before-consent"), .consentRequired)
        let pendingStatus = await client.queueStatus()
        XCTAssertEqual(pendingStatus.eventCount, 0)

        try await client.setConsent(.granted)
        XCTAssertEqual(client.capture("after-consent"), .accepted)
        let report = try await client.flush()

        XCTAssertEqual(report.uploadedEventCount, 1)
        XCTAssertEqual(report.permanentlyDroppedEventCount, 0)
        XCTAssertEqual(report.remainingEventCount, 0)
        let uploadCount = await transport.uploadCount()
        XCTAssertEqual(uploadCount, 1)
        await client.shutdown(flush: false)
    }

    func testNonGrantedStartupPurgesRecoveredRecordsBeforeReturning() async throws {
        for consent in [TelemetryConsent.pending, .denied] {
            let configuration = try makeConfiguration(consent: consent)
            let directory = try XCTUnwrap(configuration.storageDirectory)
            let queue = try DiskEventQueue(
                directory: directory,
                limits: configuration.queueLimits
            )
            let identifier = UUID()
            _ = try await queue.enqueue(
                payload: try encodeEvent(TelemetryEvent(id: identifier, name: "recovered")),
                id: identifier,
                createdAt: Date()
            )

            let client = try await startClient(
                configuration: configuration,
                transport: ScriptedTransport()
            )
            let status = await client.queueStatus()
            XCTAssertEqual(status.eventCount, 0)
            XCTAssertEqual(
                client.capture("after-start"),
                consent == .pending ? .consentRequired : .collectionDisabled
            )
            let queueFiles = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "tkevent" }
            XCTAssertTrue(queueFiles.isEmpty)
            await client.shutdown(flush: false)
        }
    }

    func testCancelledGrantDoesNotOpenCollection() async throws {
        let client = try await startClient(
            configuration: try makeConfiguration(consent: .pending),
            transport: ScriptedTransport()
        )
        let latch = ManualLatch()
        let grant = Task {
            await latch.wait()
            try await client.setConsent(.granted)
        }
        await latch.waitUntilSuspended()
        grant.cancel()
        await latch.open()

        do {
            try await grant.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(client.capture("must-remain-closed"), .consentRequired)
        await client.shutdown(flush: false)
    }

    func testCaptureAppliesPrivacyBeforeTransport() async throws {
        let transport = ScriptedTransport(steps: [.response(200)])
        var configuration = try makeConfiguration(consent: .granted)
        configuration.privacy.maximumStringLength = 8
        let client = try await startClient(configuration: configuration, transport: transport)

        let id = UUID()
        let result = client.capture(
            TelemetryEvent(
                id: id,
                name: "  checkout.completed  ",
                attributes: [
                    "token": .string("top-secret"),
                    "message": .string("abcdefghijklmnop"),
                ]
            )
        )
        XCTAssertEqual(result, .accepted)
        _ = try await client.flush()

        let batch = try decodeSingleBatch(from: await transport.uploadBodies())
        let event = try XCTUnwrap(batch.events.first)
        XCTAssertEqual(event.id, id)
        XCTAssertEqual(event.name, "checkout")
        XCTAssertEqual(event.attributes["token"], .string("[REDACTED]"))
        XCTAssertEqual(event.attributes["message"], .string("abcdefgh"))
        let uploadedBody = await transport.uploadBodies()[0]
        XCTAssertFalse(String(data: uploadedBody, encoding: .utf8)!.contains("top-secret"))
        await client.shutdown(flush: false)
    }

    func testSpanIsEndOnceAndUsesTheBoundedPrivacyPipeline() async throws {
        let transport = ScriptedTransport(steps: [.response(200)])
        var configuration = try makeConfiguration(consent: .granted)
        configuration.privacy.maximumStringLength = 14
        let client = try await startClient(configuration: configuration, transport: transport)

        let span = client.startSpan(
            "  checkout.operation  ",
            attributes: ["token": .string("private-span-token")]
        )
        XCTAssertTrue(span.end(status: .ok, attributes: ["result": .string("completed")]))
        XCTAssertFalse(span.end(status: .error))

        let report = try await client.flush()
        XCTAssertEqual(report.uploadedEventCount, 1)
        let batch = try decodeSingleBatch(from: await transport.uploadBodies())
        let event = try XCTUnwrap(batch.events.first)
        XCTAssertEqual(event.name, "span.finished")
        XCTAssertEqual(event.category, .span)
        XCTAssertEqual(event.attributes["operation"], .string("checkout.opera"))
        XCTAssertEqual(event.attributes["token"], .string("[REDACTED]"))
        XCTAssertEqual(event.attributes["status"], .string("ok"))
        guard case .double(let duration)? = event.attributes["duration_ms"] else {
            return XCTFail("Expected a numeric span duration")
        }
        XCTAssertGreaterThanOrEqual(duration, 0)
        await client.shutdown(flush: false)
    }

    func testCaptureRejectsInvalidDisabledOversizedAndBackpressuredEvents() async throws {
        let transport = ScriptedTransport()
        var configuration = try makeConfiguration(consent: .granted)
        configuration.enabledCategories = [.custom]
        configuration.queueLimits = TelemetryQueueLimits(
            maximumMemoryEventCount: 1,
            maximumMemoryBytes: 4_096,
            maximumEventCount: 10,
            maximumDiskBytes: 4_096,
            maximumEventBytes: 512,
            maximumEventAge: 3_600,
            overflowPolicy: .dropNewest
        )
        configuration.batchByteLimit = 4_096
        configuration.privacy.maximumStringLength = 4_096
        let client = try await startClient(configuration: configuration, transport: transport)

        XCTAssertEqual(client.capture(" \n "), .invalidEvent)
        XCTAssertEqual(client.capture("network", category: .network), .collectionDisabled)
        XCTAssertEqual(
            client.capture(
                "large", attributes: ["payload": .string(String(repeating: "\u{0001}", count: 100))]),
            .eventTooLarge
        )
        XCTAssertEqual(client.capture("first"), .accepted)
        XCTAssertEqual(client.capture("second"), .queueFull)

        let status = await client.queueStatus()
        XCTAssertEqual(status.eventCount, 1)
        XCTAssertLessThanOrEqual(status.byteCount, configuration.queueLimits.maximumMemoryBytes)
        await client.shutdown(flush: false)
    }

    func testConcurrentPublicCaptureRemainsBounded() async throws {
        let transport = ScriptedTransport()
        var configuration = try makeConfiguration(consent: .granted)
        configuration.queueLimits = TelemetryQueueLimits(
            maximumMemoryEventCount: 100,
            maximumMemoryBytes: 100 * 512,
            maximumEventCount: 1_000,
            maximumDiskBytes: 1_024 * 1_024,
            maximumEventBytes: 512,
            maximumEventAge: 3_600,
            overflowPolicy: .dropNewest
        )
        configuration.batchByteLimit = 64 * 1_024
        let client = try await startClient(configuration: configuration, transport: transport)

        DispatchQueue.concurrentPerform(iterations: 2_000) { index in
            _ = client.capture("event", attributes: ["index": .integer(Int64(index))])
        }

        let status = await client.queueStatus()
        XCTAssertEqual(status.eventCount, 100)
        XCTAssertLessThanOrEqual(status.byteCount, configuration.queueLimits.maximumMemoryBytes)
        await client.shutdown(flush: false)
    }

    func testEmptyFlushDoesNotContactTransport() async throws {
        let transport = ScriptedTransport()
        let client = try await startClient(
            configuration: try makeConfiguration(consent: .granted),
            transport: transport
        )

        let report = try await client.flush()

        XCTAssertEqual(
            report,
            TelemetryFlushReport(
                uploadedEventCount: 0,
                permanentlyDroppedEventCount: 0,
                remainingEventCount: 0
            )
        )
        let uploadCount = await transport.uploadCount()
        XCTAssertEqual(uploadCount, 0)
        await client.shutdown(flush: false)
    }

    func testFlushBatchesInFIFOOrder() async throws {
        let transport = ScriptedTransport(
            steps: [.response(200), .response(200), .response(200)]
        )
        var configuration = try makeConfiguration(consent: .granted)
        configuration.batchSize = 2
        let client = try await startClient(configuration: configuration, transport: transport)
        let identifiers = (0..<5).map { _ in UUID() }
        for (index, id) in identifiers.enumerated() {
            XCTAssertEqual(
                client.capture(
                    TelemetryEvent(
                        id: id,
                        name: "event-\(index)",
                        timestamp: Date(timeIntervalSince1970: TimeInterval(index))
                    )
                ),
                .accepted
            )
        }

        let report = try await client.flush()
        let batches = try (await transport.uploadBodies()).map(decodeBatch)

        XCTAssertEqual(report.uploadedEventCount, 5)
        XCTAssertEqual(batches.map { $0.events.count }, [2, 2, 1])
        XCTAssertEqual(batches.flatMap { $0.events.map(\.id) }, identifiers)
        await client.shutdown(flush: false)
    }

    func testPayloadTooLargeResponseSplitsBatchUntilDelivered() async throws {
        let transport = ScriptedTransport(
            steps: [.response(413), .response(200), .response(200)]
        )
        var configuration = try makeConfiguration(consent: .granted)
        configuration.batchSize = 4
        let client = try await startClient(configuration: configuration, transport: transport)
        for index in 0..<4 {
            XCTAssertEqual(client.capture("event-\(index)"), .accepted)
        }

        let report = try await client.flush()
        let batches = try (await transport.uploadBodies()).map(decodeBatch)

        XCTAssertEqual(report.uploadedEventCount, 4)
        XCTAssertEqual(report.permanentlyDroppedEventCount, 0)
        XCTAssertEqual(batches.map { $0.events.count }, [4, 2, 2])
        await client.shutdown(flush: false)
    }

    func testSingleEventRejectedAsTooLargeByServerIsPermanentlyDropped() async throws {
        let transport = ScriptedTransport(steps: [.response(413)])
        let client = try await startClient(
            configuration: try makeConfiguration(consent: .granted),
            transport: transport
        )
        XCTAssertEqual(client.capture("event"), .accepted)

        let report = try await client.flush()

        XCTAssertEqual(report.uploadedEventCount, 0)
        XCTAssertEqual(report.permanentlyDroppedEventCount, 1)
        XCTAssertEqual(report.remainingEventCount, 0)
        await client.shutdown(flush: false)
    }

    func testPermanentClientErrorDropsBatchWithoutRetry() async throws {
        let transport = ScriptedTransport(steps: [.response(422)])
        let client = try await startClient(
            configuration: try makeConfiguration(consent: .granted),
            transport: transport
        )
        XCTAssertEqual(client.capture("event"), .accepted)

        let report = try await client.flush()

        XCTAssertEqual(report.permanentlyDroppedEventCount, 1)
        let uploadCount = await transport.uploadCount()
        XCTAssertEqual(uploadCount, 1)
        await client.shutdown(flush: false)
    }

    func testAuthenticationFailureBlocksDeliveryButGrantingConsentUnblocksIt() async throws {
        let transport = ScriptedTransport(steps: [.response(401), .response(200)])
        let client = try await startClient(
            configuration: try makeConfiguration(consent: .granted),
            transport: transport
        )
        XCTAssertEqual(client.capture("event"), .accepted)

        await assertTransportFailure { try await client.flush() }
        let initialUploadCount = await transport.uploadCount()
        XCTAssertEqual(initialUploadCount, 1)
        let retainedStatus = await client.queueStatus()
        XCTAssertEqual(retainedStatus.eventCount, 1)

        await assertTransportFailure { try await client.flush() }
        let blockedUploadCount = await transport.uploadCount()
        XCTAssertEqual(blockedUploadCount, 1, "Blocked delivery must not hammer the endpoint")

        try await client.setConsent(.granted)
        let report = try await client.flush()
        XCTAssertEqual(report.uploadedEventCount, 1)
        let finalUploadCount = await transport.uploadCount()
        XCTAssertEqual(finalUploadCount, 2)
        await client.shutdown(flush: false)
    }

    func testRetryableResponsesAndTransportFailuresUseInjectedClockAndJitter() async throws {
        let transport = ScriptedTransport(
            steps: [
                .response(429, headers: ["Retry-After": "5"]),
                .urlError(.timedOut),
                .response(200),
            ]
        )
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        let random = SequenceRandomSource(values: [0.5, 0.25])
        var configuration = try makeConfiguration(consent: .granted)
        configuration.retryPolicy = TelemetryRetryPolicy(
            initialDelay: 2,
            maximumDelay: 10,
            maximumAttemptsPerCycle: 3
        )
        let client = try await startClient(
            configuration: configuration,
            transport: transport,
            clock: clock,
            randomSource: random
        )
        XCTAssertEqual(client.capture("event"), .accepted)

        let report = try await client.flush()

        XCTAssertEqual(report.uploadedEventCount, 1)
        XCTAssertEqual(clock.recordedSleeps(), [5, 1])
        let uploadCount = await transport.uploadCount()
        XCTAssertEqual(uploadCount, 3)
        await client.shutdown(flush: false)
    }

    func testRetryExhaustionThrowsAndRetainsQueuedEvent() async throws {
        let transport = ScriptedTransport(
            steps: [.response(503), .response(503), .response(503)]
        )
        let clock = TestClock(now: Date(timeIntervalSince1970: 1_000))
        var configuration = try makeConfiguration(consent: .granted)
        configuration.retryPolicy = TelemetryRetryPolicy(
            initialDelay: 1,
            maximumDelay: 10,
            maximumAttemptsPerCycle: 2
        )
        let client = try await startClient(
            configuration: configuration,
            transport: transport,
            clock: clock,
            randomSource: SequenceRandomSource(values: [0, 0])
        )
        XCTAssertEqual(client.capture("event"), .accepted)

        await assertTransportFailure { try await client.flush() }

        let uploadCount = await transport.uploadCount()
        XCTAssertEqual(uploadCount, 3)
        XCTAssertEqual(clock.recordedSleeps(), [0, 0])
        let status = await client.queueStatus()
        XCTAssertEqual(status.eventCount, 1)
        await client.shutdown(flush: false)
    }

    func testCancellationLeavesQueueIntactAndClientReusable() async throws {
        let transport = ScriptedTransport(
            steps: [.waitForCancellation, .response(200)]
        )
        let client = try await startClient(
            configuration: try makeConfiguration(consent: .granted),
            transport: transport
        )
        XCTAssertEqual(client.capture("event"), .accepted)

        let flushTask = Task { try await client.flush() }
        try await waitForUploadCount(1, transport: transport)
        flushTask.cancel()
        do {
            _ = try await flushTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        }

        let retainedStatus = await client.queueStatus()
        XCTAssertEqual(retainedStatus.eventCount, 1)
        let retryReport = try await client.flush()
        XCTAssertEqual(retryReport.uploadedEventCount, 1)
        await client.shutdown(flush: false)
    }

    func testFlushTimeoutReturnsPromptlyAndLeavesClientReusable() async throws {
        let transport = ScriptedTransport(
            steps: [.waitForCancellation, .response(200)]
        )
        let client = try await startClient(
            configuration: try makeConfiguration(consent: .granted),
            transport: transport
        )
        XCTAssertEqual(client.capture("event"), .accepted)

        do {
            _ = try await client.flush(timeout: 0.02)
            XCTFail("Expected the flush to time out")
        } catch let error as TelemetryError {
            XCTAssertEqual(error, .flushTimedOut)
        }

        let retainedStatus = await client.queueStatus()
        XCTAssertEqual(retainedStatus.eventCount, 1)
        let retryReport = try await client.flush(timeout: 1)
        XCTAssertEqual(retryReport.uploadedEventCount, 1)
        await client.shutdown(flush: false)
    }

    func testFlushWatermarkDoesNotConsumeEventsAcceptedDuringUpload() async throws {
        let transport = GateTransport()
        let client = try await startClient(
            configuration: try makeConfiguration(consent: .granted),
            transport: transport
        )
        let firstID = UUID()
        let secondID = UUID()
        XCTAssertEqual(client.capture(TelemetryEvent(id: firstID, name: "first")), .accepted)

        let flushTask = Task { try await client.flush() }
        await transport.waitUntilUploadStarts()
        XCTAssertEqual(client.capture(TelemetryEvent(id: secondID, name: "second")), .accepted)
        await transport.complete(statusCode: 200)
        let report = try await flushTask.value

        XCTAssertEqual(report.uploadedEventCount, 1)
        let uploadedBatch = try decodeSingleBatch(from: await transport.uploadBodies())
        XCTAssertEqual(uploadedBatch.events.map(\.id), [firstID])
        let status = await client.queueStatus()
        XCTAssertEqual(status.eventCount, 1)

        await client.shutdown(flush: false)
    }

    func testConsentRevocationPurgesMemoryAndDurableQueue() async throws {
        let transport = ScriptedTransport(steps: [.response(401)])
        let client = try await startClient(
            configuration: try makeConfiguration(consent: .granted),
            transport: transport
        )
        XCTAssertEqual(client.capture("persisted"), .accepted)
        await assertTransportFailure { try await client.flush() }
        XCTAssertEqual(client.capture("in-memory"), .accepted)

        try await client.setConsent(.denied)

        let status = await client.queueStatus()
        XCTAssertEqual(status.eventCount, 0)
        XCTAssertEqual(status.byteCount, 0)
        XCTAssertEqual(client.capture("after-revocation"), .collectionDisabled)
        await client.shutdown(flush: false)
    }

    func testConsentRevocationCancelsAnActiveUploadAndPurgesItsRecords() async throws {
        let transport = RevocationAwareTransport()
        let client = try await startClient(
            configuration: try makeConfiguration(consent: .granted),
            transport: transport
        )
        XCTAssertEqual(client.capture("in-flight"), .accepted)

        let flush = Task { try await client.flush() }
        await transport.waitUntilUploadStarts()
        try await client.setConsent(.denied)

        do {
            _ = try await flush.value
            XCTFail("Expected the active upload to be cancelled")
        } catch is CancellationError {
            // Expected.
        }
        let status = await client.queueStatus()
        XCTAssertEqual(status.eventCount, 0)
        XCTAssertEqual(transport.outstandingUploadCount, 0)
        XCTAssertEqual(client.capture("after-revocation"), .collectionDisabled)
        await client.shutdown(flush: false)
    }

    func testEraseStoredDataClearsMemoryAndDiskWithoutChangingConsent() async throws {
        let transport = ScriptedTransport(steps: [.response(401)])
        let client = try await startClient(
            configuration: try makeConfiguration(consent: .granted),
            transport: transport
        )
        XCTAssertEqual(client.capture("persisted"), .accepted)
        await assertTransportFailure { try await client.flush() }
        XCTAssertEqual(client.capture("in-memory"), .accepted)

        try await client.eraseStoredData()

        let status = await client.queueStatus()
        XCTAssertEqual(status.eventCount, 0)
        XCTAssertEqual(client.capture("collection-still-enabled"), .accepted)
        await client.shutdown(flush: false)
    }

    func testShutdownIsIdempotentCancelsTransportAndStopsPublicOperations() async throws {
        let cancellationProbe = CancellationProbe()
        let transport = ScriptedTransport(cancellationProbe: cancellationProbe)
        let client = try await startClient(
            configuration: try makeConfiguration(consent: .granted),
            transport: transport
        )
        XCTAssertEqual(client.capture("event"), .accepted)

        await client.shutdown(flush: false)
        await client.shutdown(flush: false)

        XCTAssertEqual(cancellationProbe.count, 1)
        XCTAssertEqual(client.capture("after-shutdown"), .clientStopped)
        await assertClientStopped { try await client.flush() }
        await assertClientStopped { try await client.setConsent(.granted) }
        await assertClientStopped { try await client.eraseStoredData() }
    }

    func testCorruptPersistedPayloadIsDroppedDuringStartupWithoutContactingTransport() async throws {
        let configuration = try makeConfiguration(consent: .granted)
        let directory = try XCTUnwrap(configuration.storageDirectory)
        let queue = try DiskEventQueue(directory: directory, limits: configuration.queueLimits)
        _ = try await queue.enqueue(
            payload: Data("not-json".utf8),
            id: UUID(),
            createdAt: Date()
        )
        let transport = ScriptedTransport()
        let client = try await startClient(configuration: configuration, transport: transport)
        let startupStatus = await client.queueStatus()
        XCTAssertEqual(startupStatus.eventCount, 0)

        let report = try await client.flush()

        XCTAssertEqual(report.uploadedEventCount, 0)
        XCTAssertEqual(report.permanentlyDroppedEventCount, 0)
        XCTAssertEqual(report.remainingEventCount, 0)
        let uploadCount = await transport.uploadCount()
        XCTAssertEqual(uploadCount, 0)
        await client.shutdown(flush: false)
    }

    func testRecoveredRecordsUseCurrentIdentityPrivacyAndCategoryPolicyBeforeDelivery() async throws {
        var configuration = try makeConfiguration(consent: .granted)
        configuration.enabledCategories = [.custom]
        let directory = try XCTUnwrap(configuration.storageDirectory)
        let queue = try DiskEventQueue(directory: directory, limits: configuration.queueLimits)
        let retainedID = UUID()
        _ = try await queue.enqueue(
            payload: try encodeEvent(
                TelemetryEvent(
                    id: retainedID,
                    name: "retained",
                    attributes: ["token": .string("preexisting-secret")]
                )
            ),
            id: retainedID,
            createdAt: Date()
        )
        let mismatchedEnvelopeID = UUID()
        _ = try await queue.enqueue(
            payload: try encodeEvent(
                TelemetryEvent(id: UUID(), name: "identity-mismatch")
            ),
            id: mismatchedEnvelopeID,
            createdAt: Date()
        )
        let disabledID = UUID()
        _ = try await queue.enqueue(
            payload: try encodeEvent(
                TelemetryEvent(id: disabledID, name: "disabled", category: .network)
            ),
            id: disabledID,
            createdAt: Date()
        )

        let transport = ScriptedTransport(steps: [.response(200)])
        let client = try await startClient(configuration: configuration, transport: transport)
        let reconciledStatus = await client.queueStatus()
        XCTAssertEqual(reconciledStatus.eventCount, 1)

        let recordURL = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ).first(where: { $0.pathExtension == "tkevent" })
        )
        let stored = try PropertyListDecoder().decode(
            StoredEnvelope.self,
            from: Data(contentsOf: recordURL)
        )
        let reconciledEvent = try decodeEvent(stored.payload)
        XCTAssertEqual(reconciledEvent.id, retainedID)
        XCTAssertEqual(reconciledEvent.attributes["token"], .string("[REDACTED]"))
        XCTAssertFalse(String(data: stored.payload, encoding: .utf8)!.contains("preexisting-secret"))

        var changedAfterRecovery = reconciledEvent
        changedAfterRecovery.attributes["token"] = .string("top-secret")
        let changedPayload = try encodeEvent(changedAfterRecovery)
        XCTAssertEqual(changedPayload.count, stored.payload.count)
        let changedEnvelope = StoredEnvelope(
            id: stored.id,
            sequence: stored.sequence,
            createdAt: stored.createdAt,
            payload: changedPayload
        )
        let propertyListEncoder = PropertyListEncoder()
        propertyListEncoder.outputFormat = .binary
        try propertyListEncoder.encode(changedEnvelope).write(to: recordURL, options: .atomic)

        let report = try await client.flush()
        XCTAssertEqual(report.uploadedEventCount, 1)
        let bodies = await transport.uploadBodies()
        let batch = try decodeSingleBatch(from: bodies)
        XCTAssertEqual(batch.events.map(\.id), [retainedID])
        XCTAssertEqual(batch.events.first?.attributes["token"], .string("[REDACTED]"))
        XCTAssertFalse(String(data: try XCTUnwrap(bodies.first), encoding: .utf8)!.contains("top-secret"))
        await client.shutdown(flush: false)
    }

    private func makeConfiguration(consent: TelemetryConsent) throws -> TelemetryConfiguration {
        var configuration = TelemetryConfiguration(
            endpoint: URL(string: "https://ingest.example.test/v1/events")!,
            consent: consent
        )
        configuration.storageDirectory = try makeTemporaryDirectory()
        configuration.flushInterval = 3_600
        return configuration
    }

    private func startClient(
        configuration: TelemetryConfiguration,
        transport: TelemetryTransport,
        clock: TelemetryRuntimeClock = TestClock(),
        randomSource: TelemetryRandomSource = SequenceRandomSource(values: [0])
    ) async throws -> TelemetryClient {
        try await TelemetryClient.start(
            configuration: configuration,
            transport: transport,
            clock: clock,
            randomSource: randomSource,
            startsBackgroundTasks: false,
            startsInstrumentation: false
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "TelemetryClientIntegrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }

    private func decodeSingleBatch(from bodies: [Data]) throws -> TelemetryUploadBatch {
        XCTAssertEqual(bodies.count, 1)
        return try decodeBatch(try XCTUnwrap(bodies.first))
    }

    private func decodeBatch(_ body: Data) throws -> TelemetryUploadBatch {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TelemetryUploadBatch.self, from: body)
    }

    private func encodeEvent(_ event: TelemetryEvent) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(event)
    }

    private func decodeEvent(_ payload: Data) throws -> TelemetryEvent {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TelemetryEvent.self, from: payload)
    }

    private func waitForUploadCount(
        _ expectedCount: Int,
        transport: ScriptedTransport
    ) async throws {
        for _ in 0..<2_000 {
            if await transport.uploadCount() >= expectedCount { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for \(expectedCount) upload(s)")
    }

    private func assertTransportFailure(
        _ operation: @Sendable () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected transport failure", file: file, line: line)
        } catch let error as TelemetryError {
            guard case .transportFailed = error else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func assertClientStopped(
        _ operation: @Sendable () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected clientStopped", file: file, line: line)
        } catch let error as TelemetryError {
            XCTAssertEqual(error, .clientStopped, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }
}

private actor ScriptedTransport: TelemetryTransport {
    enum Step: Sendable {
        case response(Int, headers: [String: String] = [:])
        case urlError(URLError.Code)
        case waitForCancellation
    }

    private var steps: [Step]
    private var bodies: [Data] = []
    nonisolated private let cancellationProbe: CancellationProbe

    init(
        steps: [Step] = [],
        cancellationProbe: CancellationProbe = CancellationProbe()
    ) {
        self.steps = steps
        self.cancellationProbe = cancellationProbe
    }

    func upload(body: Data) async throws -> TelemetryTransportResponse {
        bodies.append(body)
        let step = steps.isEmpty ? .response(200) : steps.removeFirst()
        switch step {
        case .response(let statusCode, let headers):
            return TelemetryTransportResponse(statusCode: statusCode, headers: headers)
        case .urlError(let code):
            throw URLError(code)
        case .waitForCancellation:
            while true {
                try Task.checkCancellation()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }
    }

    nonisolated func cancelAll() {
        cancellationProbe.record()
    }

    nonisolated func resumeUploads() {}
    nonisolated func cancelOutstanding() {}

    func uploadBodies() -> [Data] { bodies }
    func uploadCount() -> Int { bodies.count }
}

private actor GateTransport: TelemetryTransport {
    private var bodies: [Data] = []
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var responseContinuation: CheckedContinuation<TelemetryTransportResponse, Error>?

    func upload(body: Data) async throws -> TelemetryTransportResponse {
        bodies.append(body)
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        return try await withCheckedThrowingContinuation { continuation in
            responseContinuation = continuation
        }
    }

    nonisolated func resumeUploads() {}
    nonisolated func cancelOutstanding() {}
    nonisolated func cancelAll() {}

    func waitUntilUploadStarts() async {
        guard bodies.isEmpty else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func complete(statusCode: Int, headers: [String: String] = [:]) {
        responseContinuation?.resume(
            returning: TelemetryTransportResponse(statusCode: statusCode, headers: headers)
        )
        responseContinuation = nil
    }

    func uploadBodies() -> [Data] { bodies }
}

private final class RevocationAwareTransport: TelemetryTransport, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var acceptsUploads = true
        private var didStart = false
        private var uploadContinuation: CheckedContinuation<TelemetryTransportResponse, Error>?
        private var startWaiters: [CheckedContinuation<Void, Never>] = []

        var outstandingUploadCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return uploadContinuation == nil ? 0 : 1
        }

        func registerUpload(
            _ continuation: CheckedContinuation<TelemetryTransportResponse, Error>
        ) {
            lock.lock()
            guard acceptsUploads, uploadContinuation == nil else {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            uploadContinuation = continuation
            didStart = true
            let waiters = startWaiters
            startWaiters.removeAll()
            lock.unlock()
            for waiter in waiters {
                waiter.resume()
            }
        }

        func waitUntilUploadStarts() async {
            await withCheckedContinuation { continuation in
                lock.lock()
                if didStart {
                    lock.unlock()
                    continuation.resume()
                } else {
                    startWaiters.append(continuation)
                    lock.unlock()
                }
            }
        }

        func suspendAndCancel() {
            lock.lock()
            acceptsUploads = false
            let continuation = uploadContinuation
            uploadContinuation = nil
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }

        func resume() {
            lock.lock()
            acceptsUploads = true
            lock.unlock()
        }
    }

    private let state = State()

    var outstandingUploadCount: Int { state.outstandingUploadCount }

    func upload(body: Data) async throws -> TelemetryTransportResponse {
        try await withCheckedThrowingContinuation { continuation in
            state.registerUpload(continuation)
        }
    }

    func waitUntilUploadStarts() async {
        await state.waitUntilUploadStarts()
    }

    func resumeUploads() {
        state.resume()
    }

    func cancelOutstanding() {
        state.suspendAndCancel()
    }

    func cancelAll() {
        state.suspendAndCancel()
    }
}

private final class TestClock: TelemetryRuntimeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var currentDate: Date
    private var sleeps: [TimeInterval] = []

    init(now: Date = Date(timeIntervalSince1970: 1_000)) {
        currentDate = now
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return currentDate
    }

    func sleep(for delay: TimeInterval) async throws {
        try Task.checkCancellation()
        recordSleep(delay)
    }

    func recordedSleeps() -> [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return sleeps
    }

    private func recordSleep(_ delay: TimeInterval) {
        lock.lock()
        sleeps.append(delay)
        currentDate = currentDate.addingTimeInterval(delay)
        lock.unlock()
    }
}

private actor SequenceRandomSource: TelemetryRandomSource {
    private var values: [Double]

    init(values: [Double]) {
        self.values = values
    }

    func nextUnit() async -> Double {
        values.isEmpty ? 0 : values.removeFirst()
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationCount = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellationCount
    }

    func record() {
        lock.lock()
        cancellationCount += 1
        lock.unlock()
    }
}

private actor ManualLatch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private var isSuspended = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            isSuspended = true
            self.continuation = continuation
        }
    }

    func waitUntilSuspended() async {
        while !isSuspended {
            await Task.yield()
        }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
