import Foundation
import XCTest

@testable import TelemetryKit

final class DiskEventQueueTests: XCTestCase, @unchecked Sendable {
    func testPersistsFIFOOrderingAcrossReinitialization() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let limits = TelemetryQueueLimits(
            maximumEventCount: 10,
            maximumDiskBytes: 1_024,
            maximumEventBytes: 128,
            maximumEventAge: 3_600,
            overflowPolicy: .dropOldest
        )
        let firstID = UUID()
        let secondID = UUID()
        let baseDate = Date()

        let queue = try DiskEventQueue(directory: directory, limits: limits)
        let firstResult = try await queue.enqueue(
            payload: Data("first".utf8),
            id: firstID,
            createdAt: baseDate
        )
        let secondResult = try await queue.enqueue(
            payload: Data("second".utf8),
            id: secondID,
            createdAt: baseDate.addingTimeInterval(1)
        )
        XCTAssertEqual(firstResult, .accepted)
        XCTAssertEqual(secondResult, .accepted)

        let reopened = try DiskEventQueue(directory: directory, limits: limits)
        let batch = try await reopened.peekBatch(
            maxCount: 10,
            maxBytes: 1_024,
            now: baseDate.addingTimeInterval(2)
        )

        XCTAssertEqual(batch.map(\.id), [firstID, secondID])
        XCTAssertEqual(batch.map(\.sequence), [0, 1])
        XCTAssertEqual(batch.map(\.payload), [Data("first".utf8), Data("second".utf8)])
    }

    func testDropOldestEnforcesCountAndByteLimits() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let limits = TelemetryQueueLimits(
            maximumEventCount: 2,
            maximumDiskBytes: 6,
            maximumEventBytes: 3,
            maximumEventAge: 3_600,
            overflowPolicy: .dropOldest
        )
        let identifiers = [UUID(), UUID(), UUID()]
        let queue = try DiskEventQueue(directory: directory, limits: limits)

        for index in 0..<2 {
            let result = try await queue.enqueue(
                payload: Data(repeating: UInt8(index), count: 3),
                id: identifiers[index],
                createdAt: Date()
            )
            XCTAssertEqual(result, .accepted)
        }
        let overflow = try await queue.enqueue(
            payload: Data(repeating: 2, count: 3),
            id: identifiers[2],
            createdAt: Date()
        )

        XCTAssertEqual(overflow, .acceptedAfterDroppingOldest(1))
        let batch = try await queue.peekBatch(maxCount: 2, maxBytes: 6, now: Date())
        XCTAssertEqual(batch.map(\.id), Array(identifiers.suffix(2)))
        let status = await queue.status()
        XCTAssertEqual(status.eventCount, 2)
        XCTAssertEqual(status.byteCount, 6)
    }

    func testDropNewestAndOversizedPayloadsAreRejectedWithoutMutation() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let limits = TelemetryQueueLimits(
            maximumEventCount: 1,
            maximumDiskBytes: 4,
            maximumEventBytes: 4,
            maximumEventAge: 3_600,
            overflowPolicy: .dropNewest
        )
        let retainedID = UUID()
        let queue = try DiskEventQueue(directory: directory, limits: limits)

        _ = try await queue.enqueue(
            payload: Data(repeating: 1, count: 4),
            id: retainedID,
            createdAt: Date()
        )
        let full = try await queue.enqueue(
            payload: Data([2]),
            id: UUID(),
            createdAt: Date()
        )
        let oversized = try await queue.enqueue(
            payload: Data(repeating: 3, count: 5),
            id: UUID(),
            createdAt: Date()
        )

        XCTAssertEqual(full, .rejectedFull)
        XCTAssertEqual(oversized, .rejectedOversized)
        let batch = try await queue.peekBatch(maxCount: 1, maxBytes: 4, now: Date())
        XCTAssertEqual(batch.map(\.id), [retainedID])
    }

    func testExpiredRecordsAreRemovedBeforePeeking() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let limits = TelemetryQueueLimits(
            maximumEventCount: 10,
            maximumDiskBytes: 1_024,
            maximumEventBytes: 128,
            maximumEventAge: 10,
            overflowPolicy: .dropOldest
        )
        let now = Date()
        let expiredID = UUID()
        let currentID = UUID()
        let queue = try DiskEventQueue(directory: directory, limits: limits)

        _ = try await queue.enqueue(
            payload: Data([1]),
            id: expiredID,
            createdAt: now.addingTimeInterval(-11)
        )
        _ = try await queue.enqueue(
            payload: Data([2]),
            id: currentID,
            createdAt: now
        )

        let batch = try await queue.peekBatch(maxCount: 10, maxBytes: 100, now: now)
        XCTAssertEqual(batch.map(\.id), [currentID])
        let status = await queue.status()
        XCTAssertEqual(status.eventCount, 1)
        XCTAssertEqual(status.byteCount, 1)
    }

    func testCorruptRecordsAreRemovedDuringRecovery() async throws {
        let directory = makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let corruptURL = directory.appendingPathComponent("corrupt.tkevent")
        try Data("not a property list".utf8).write(to: corruptURL)

        let queue = try DiskEventQueue(directory: directory, limits: TelemetryQueueLimits())
        let status = await queue.status()

        XCTAssertEqual(status.eventCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: corruptURL.path))
    }

    private func makeTemporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("TelemetryKitTests-\(UUID().uuidString)", isDirectory: true)
    }
}

final class TelemetryPrivacyFilterTests: XCTestCase {
    func testSanitizesNamesRedactsKeysAndBoundsCollections() throws {
        var configuration = TelemetryPrivacyConfiguration(
            redactedAttributeKeys: ["TOKEN"],
            maximumAttributeCount: 3,
            maximumStringLength: 5,
            maximumCollectionLength: 2,
            maximumNestingDepth: 2,
            networkURLCollection: .host
        )
        configuration.redactedAttributeKeys.insert("password")
        let filter = TelemetryPrivacyFilter(configuration: configuration)
        let event = TelemetryEvent(
            name: "  checkout-completed  ",
            attributes: [
                "token": .string("secret-value"),
                "items": .array([.integer(1), .integer(2), .integer(3)]),
                "message": .string("abcdefgh"),
            ]
        )

        let sanitized = try XCTUnwrap(filter.sanitize(event))
        XCTAssertEqual(sanitized.name, "check")
        XCTAssertEqual(sanitized.attributes["token"], .string("[REDACTED]"))
        XCTAssertEqual(sanitized.attributes["messa"], .string("abcde"))
        XCTAssertEqual(sanitized.attributes["items"], .array([.integer(1), .integer(2)]))
    }

    func testDropsNonFiniteNumbersAndValuesBeyondDepthLimit() throws {
        let configuration = TelemetryPrivacyConfiguration(
            redactedAttributeKeys: [],
            maximumAttributeCount: 10,
            maximumStringLength: 100,
            maximumCollectionLength: 10,
            maximumNestingDepth: 1,
            networkURLCollection: .none
        )
        let filter = TelemetryPrivacyFilter(configuration: configuration)
        let event = TelemetryEvent(
            name: "event",
            attributes: [
                "infinite": .double(.infinity),
                "nested": .object(["tooDeep": .array([.string("private")])]),
                "safe": .boolean(true),
            ]
        )

        let sanitized = try XCTUnwrap(filter.sanitize(event))
        XCTAssertNil(sanitized.attributes["infinite"])
        XCTAssertEqual(sanitized.attributes["nested"], .object([:]))
        XCTAssertEqual(sanitized.attributes["safe"], .boolean(true))
    }

    func testURLAttributesNeverContainCredentialsQueryOrFragment() throws {
        var hostConfiguration = TelemetryPrivacyConfiguration()
        hostConfiguration.networkURLCollection = .host
        let hostFilter = TelemetryPrivacyFilter(configuration: hostConfiguration)
        let url = try XCTUnwrap(
            URL(string: "https://user:password@Example.COM:8443/orders/123?token=secret#private")
        )

        XCTAssertEqual(
            hostFilter.sanitizedURLAttributes(url),
            ["network.host": .string("example.com")]
        )

        var pathConfiguration = hostConfiguration
        pathConfiguration.networkURLCollection = .hostAndPath
        let pathFilter = TelemetryPrivacyFilter(configuration: pathConfiguration)
        XCTAssertEqual(
            pathFilter.sanitizedURLAttributes(url),
            [
                "network.host": .string("example.com"),
                "network.path": .string("/orders/123"),
            ]
        )
    }

    func testRejectsAnEmptyEventName() {
        let filter = TelemetryPrivacyFilter(configuration: TelemetryPrivacyConfiguration())
        XCTAssertNil(filter.sanitize(TelemetryEvent(name: " \n ")))
    }
}

final class RetryPolicyAndResponseClassifierTests: XCTestCase {
    func testFullJitterAndRetryAfterUseTheLongerDelay() throws {
        let policy = TelemetryRetryPolicy(
            initialDelay: 2,
            maximumDelay: 10,
            maximumAttemptsPerCycle: 3
        )
        let calculator = RetryDelayCalculator(policy: policy)
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(
            try XCTUnwrap(
                calculator.delay(attempt: 0, randomUnit: 0.5, retryAfter: nil, now: now)
            ),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(
                calculator.delay(
                    attempt: 2,
                    randomUnit: 0.5,
                    retryAfter: now.addingTimeInterval(6),
                    now: now
                )
            ),
            6,
            accuracy: 0.000_001
        )
        XCTAssertNil(calculator.delay(attempt: 3, randomUnit: 0.5, retryAfter: nil, now: now))
    }

    func testHTTPStatusClassificationAndNumericRetryAfter() throws {
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertEqual(ResponseClassifier.classify(statusCode: 204, now: now), .delivered)
        XCTAssertEqual(ResponseClassifier.classify(statusCode: 401, now: now), .authenticationBlocked)
        XCTAssertEqual(ResponseClassifier.classify(statusCode: 413, now: now), .splitBatch)
        XCTAssertEqual(ResponseClassifier.classify(statusCode: 422, now: now), .discard)
        XCTAssertEqual(
            ResponseClassifier.classify(
                statusCode: 429,
                headers: ["retry-after": "120"],
                now: now
            ),
            .retry(retryAfter: now.addingTimeInterval(120))
        )
    }

    func testHTTPDateRetryAfterAndTransportFailures() throws {
        let now = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2015-10-21T07:27:00Z")
        )
        let retryDate = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2015-10-21T07:28:00Z")
        )

        XCTAssertEqual(
            ResponseClassifier.classify(
                statusCode: 503,
                headers: ["Retry-After": "Wed, 21 Oct 2015 07:28:00 GMT"],
                now: now
            ),
            .retry(retryAfter: retryDate)
        )
        XCTAssertEqual(
            ResponseClassifier.classify(error: URLError(.cancelled)),
            .cancelled
        )
        XCTAssertEqual(
            ResponseClassifier.classify(error: URLError(.notConnectedToInternet)),
            .retry
        )
        XCTAssertEqual(
            ResponseClassifier.classify(error: URLError(.badURL)),
            .configurationBlocked
        )
    }
}
