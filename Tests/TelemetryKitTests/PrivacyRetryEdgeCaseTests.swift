import Foundation
import XCTest

@testable import TelemetryKit

final class TelemetryPrivacyEdgeCaseTests: XCTestCase {
    func testAttributeSelectionIsDeterministicWhenOverLimit() throws {
        let configuration = TelemetryPrivacyConfiguration(
            redactedAttributeKeys: [],
            maximumAttributeCount: 2,
            maximumStringLength: 100,
            maximumCollectionLength: 10,
            maximumNestingDepth: 3,
            networkURLCollection: .host
        )
        let filter = TelemetryPrivacyFilter(configuration: configuration)
        let attributes: [String: TelemetryValue] = [
            "Zulu": .integer(3),
            "alpha": .integer(1),
            "Bravo": .integer(2),
        ]

        for _ in 0..<20 {
            let sanitized = try XCTUnwrap(
                filter.sanitize(TelemetryEvent(name: "event", attributes: attributes))
            )
            XCTAssertEqual(sanitized.attributes, ["alpha": .integer(1), "Bravo": .integer(2)])
        }
    }

    func testRedactionMatchesTrimmedKeysCaseInsensitivelyBeforeTruncation() throws {
        let configuration = TelemetryPrivacyConfiguration(
            redactedAttributeKeys: ["authorization"],
            maximumAttributeCount: 10,
            maximumStringLength: 4,
            maximumCollectionLength: 10,
            maximumNestingDepth: 3,
            networkURLCollection: .none
        )
        let filter = TelemetryPrivacyFilter(configuration: configuration)
        let event = TelemetryEvent(
            name: "event-name",
            attributes: ["  AuThOrIzAtIoN  ": .string("Bearer private-token")]
        )

        let sanitized = try XCTUnwrap(filter.sanitize(event))
        XCTAssertEqual(sanitized.name, "even")
        XCTAssertEqual(sanitized.attributes, ["AuTh": .string("[REDACTED]")])
        XCTAssertFalse(String(describing: sanitized).contains("private-token"))
    }

    func testSanitizationPreservesEventIdentityAndNonPayloadMetadata() throws {
        let id = UUID()
        let timestamp = Date(timeIntervalSince1970: 123)
        let event = TelemetryEvent(
            id: id,
            name: " event ",
            timestamp: timestamp,
            level: .fatal,
            category: .sdkDiagnostic,
            attributes: ["key": .string("value")]
        )

        let sanitized = try XCTUnwrap(
            TelemetryPrivacyFilter(configuration: TelemetryPrivacyConfiguration()).sanitize(event)
        )
        XCTAssertEqual(sanitized.id, id)
        XCTAssertEqual(sanitized.timestamp, timestamp)
        XCTAssertEqual(sanitized.level, .fatal)
        XCTAssertEqual(sanitized.category, .sdkDiagnostic)
        XCTAssertEqual(sanitized.name, "event")
    }

    func testCollectionLimitBoundsWorkBeforeDiscardingUnsafeElements() throws {
        let configuration = TelemetryPrivacyConfiguration(
            redactedAttributeKeys: [],
            maximumAttributeCount: 10,
            maximumStringLength: 100,
            maximumCollectionLength: 2,
            maximumNestingDepth: 3,
            networkURLCollection: .none
        )
        let filter = TelemetryPrivacyFilter(configuration: configuration)
        let event = TelemetryEvent(
            name: "event",
            attributes: [
                "values": .array([.double(.nan), .integer(1), .integer(2)])
            ]
        )

        let sanitized = try XCTUnwrap(filter.sanitize(event))
        XCTAssertEqual(sanitized.attributes["values"], .array([.integer(1)]))
    }

    func testDepthLimitDropsNestedCollectionsButRetainsScalarSiblings() throws {
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
                "object": .object([
                    "scalar": .string("safe"),
                    "nested": .array([.string("too deep")]),
                ])
            ]
        )

        let sanitized = try XCTUnwrap(filter.sanitize(event))
        XCTAssertEqual(
            sanitized.attributes["object"],
            .object(["scalar": .string("safe")])
        )
    }

    func testInvalidPrivacyLimitsFailClosed() {
        var configuration = TelemetryPrivacyConfiguration()
        configuration.maximumStringLength = 0
        let filter = TelemetryPrivacyFilter(configuration: configuration)

        XCTAssertNil(filter.sanitize(TelemetryEvent(name: "would-have-been-valid")))
        XCTAssertEqual(
            filter.sanitizedURLAttributes(URL(string: "https://example.com/path")),
            [:]
        )
    }

    func testURLCollectionHandlesNoneNilHostAndRootPath() throws {
        var configuration = TelemetryPrivacyConfiguration()
        configuration.networkURLCollection = .none
        var filter = TelemetryPrivacyFilter(configuration: configuration)
        XCTAssertEqual(
            filter.sanitizedURLAttributes(URL(string: "https://example.com/private?q=secret")),
            [:]
        )

        configuration.networkURLCollection = .hostAndPath
        filter = TelemetryPrivacyFilter(configuration: configuration)
        XCTAssertEqual(filter.sanitizedURLAttributes(nil), [:])
        XCTAssertEqual(filter.sanitizedURLAttributes(URL(string: "file:///private/file")), [:])
        XCTAssertEqual(
            filter.sanitizedURLAttributes(
                try XCTUnwrap(URL(string: "https://EXAMPLE.com/?token=secret#fragment"))
            ),
            ["network.host": .string("example.com")]
        )
    }

    func testGlobalNodeAndStringBudgetsBoundADeepWideGraph() throws {
        let configuration = TelemetryPrivacyConfiguration(
            redactedAttributeKeys: [],
            maximumAttributeCount: 1_024,
            maximumStringLength: 1_024,
            maximumCollectionLength: 1_024,
            maximumNestingDepth: 8,
            networkURLCollection: .none
        )
        let filter = TelemetryPrivacyFilter(
            configuration: configuration,
            maximumOutputBytes: 256
        )
        let values = (0..<1_000).map { _ in TelemetryValue.string("abcdefgh") }

        let sanitized = try XCTUnwrap(
            filter.sanitize(
                TelemetryEvent(name: "event", attributes: ["values": .array(values)])
            )
        )
        guard case .array(let retained)? = sanitized.attributes["values"] else {
            return XCTFail("Expected a retained, bounded array")
        }
        XCTAssertLessThanOrEqual(retained.count, 30)
    }

    func testOversizedAttributeKeyIsDroppedBeforeNormalization() throws {
        var configuration = TelemetryPrivacyConfiguration()
        configuration.maximumStringLength = 8
        let filter = TelemetryPrivacyFilter(
            configuration: configuration,
            maximumOutputBytes: 64
        )
        let oversizedKey = String(repeating: "A", count: 10_000)

        let sanitized = try XCTUnwrap(
            filter.sanitize(
                TelemetryEvent(name: "event", attributes: [oversizedKey: .string("secret")])
            )
        )
        XCTAssertTrue(sanitized.attributes.isEmpty)
    }

    func testSpanInputIsSanitizedBeforeTheSpanRetainsIt() {
        let configuration = TelemetryPrivacyConfiguration(
            redactedAttributeKeys: ["token"],
            maximumAttributeCount: 2,
            maximumStringLength: 5,
            maximumCollectionLength: 2,
            maximumNestingDepth: 2,
            networkURLCollection: .none
        )
        let filter = TelemetryPrivacyFilter(configuration: configuration)

        let sanitized = filter.sanitizeSpan(
            operation: "  operation-name  ",
            attributes: [
                "token": .string("private"),
                "message": .string("abcdefgh"),
                "z-extra": .string("discarded"),
            ]
        )

        XCTAssertEqual(sanitized.operation, "opera")
        XCTAssertEqual(sanitized.attributes["token"], .string("[REDACTED]"))
        XCTAssertEqual(sanitized.attributes["messa"], .string("abcde"))
        XCTAssertNil(sanitized.attributes["z-ext"])
    }
}

final class RetryPolicyEdgeCaseTests: XCTestCase {
    func testPublicDelayUsesExponentialCeilingAndClampsInputs() {
        let policy = TelemetryRetryPolicy(
            initialDelay: 2,
            maximumDelay: 10,
            maximumAttemptsPerCycle: 8
        )

        XCTAssertEqual(policy.delay(attempt: -1, randomUnit: 0.5), 1, accuracy: 0.000_001)
        XCTAssertEqual(policy.delay(attempt: 0, randomUnit: -10), 0, accuracy: 0.000_001)
        XCTAssertEqual(policy.delay(attempt: 1, randomUnit: 1.5), 4, accuracy: 0.000_001)
        XCTAssertEqual(policy.delay(attempt: 2, randomUnit: 1), 8, accuracy: 0.000_001)
        XCTAssertEqual(policy.delay(attempt: 3, randomUnit: 1), 10, accuracy: 0.000_001)
        XCTAssertEqual(policy.delay(attempt: 100, randomUnit: 1), 10, accuracy: 0.000_001)
    }

    func testCalculatorRejectsInvalidAttemptsAndDefendsAgainstNonFiniteJitter() {
        let calculator = RetryDelayCalculator(
            policy: TelemetryRetryPolicy(
                initialDelay: 2,
                maximumDelay: 10,
                maximumAttemptsPerCycle: 2
            )
        )
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertNil(calculator.delay(attempt: -1, randomUnit: 0.5, retryAfter: nil, now: now))
        XCTAssertNil(calculator.delay(attempt: 2, randomUnit: 0.5, retryAfter: nil, now: now))
        XCTAssertEqual(
            calculator.delay(attempt: 0, randomUnit: .nan, retryAfter: nil, now: now),
            0
        )
        XCTAssertEqual(
            calculator.delay(attempt: 0, randomUnit: .infinity, retryAfter: nil, now: now),
            0
        )
    }

    func testCalculatorIgnoresPastGuidanceAndCapsFarFutureGuidance() throws {
        let calculator = RetryDelayCalculator(
            policy: TelemetryRetryPolicy(
                initialDelay: 2,
                maximumDelay: 10,
                maximumAttemptsPerCycle: 3
            )
        )
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(
            try XCTUnwrap(
                calculator.delay(
                    attempt: 0,
                    randomUnit: 0.5,
                    retryAfter: now.addingTimeInterval(-1),
                    now: now
                )
            ),
            1,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(
                calculator.delay(
                    attempt: 0,
                    randomUnit: 0,
                    retryAfter: now.addingTimeInterval(7 * 24 * 60 * 60),
                    now: now
                )
            ),
            24 * 60 * 60,
            accuracy: 0.000_001
        )
    }

    func testHTTPClassificationCoversEveryBehaviorBoundary() {
        let now = Date(timeIntervalSince1970: 1_000)
        for status in [200, 201, 204, 299] {
            XCTAssertEqual(ResponseClassifier.classify(statusCode: status, now: now), .delivered)
        }
        for status in [401, 403] {
            XCTAssertEqual(
                ResponseClassifier.classify(statusCode: status, now: now),
                .authenticationBlocked
            )
        }
        for status in [408, 425, 429, 500, 503, 599] {
            XCTAssertEqual(
                ResponseClassifier.classify(statusCode: status, now: now),
                .retry(retryAfter: nil)
            )
        }
        XCTAssertEqual(ResponseClassifier.classify(statusCode: 413, now: now), .splitBatch)
        for status in [199, 300, 400, 404, 422, 600] {
            XCTAssertEqual(ResponseClassifier.classify(statusCode: status, now: now), .discard)
        }
    }

    func testMalformedRetryAfterValuesAreIgnored() {
        let now = Date(timeIntervalSince1970: 1_000)
        for value in ["", "-1", "NaN", "not-a-date"] {
            XCTAssertEqual(
                ResponseClassifier.classify(
                    statusCode: 429,
                    headers: ["Retry-After": value],
                    now: now
                ),
                .retry(retryAfter: nil)
            )
        }
    }

    func testNSErrorTransportClassificationUsesURLDomainOnly() {
        XCTAssertEqual(
            ResponseClassifier.classify(
                error: NSError(domain: NSURLErrorDomain, code: URLError.cancelled.rawValue)
            ),
            .cancelled
        )
        XCTAssertEqual(
            ResponseClassifier.classify(
                error: NSError(domain: NSURLErrorDomain, code: URLError.unsupportedURL.rawValue)
            ),
            .configurationBlocked
        )
        XCTAssertEqual(
            ResponseClassifier.classify(
                error: NSError(domain: "example.test", code: URLError.cancelled.rawValue)
            ),
            .retry
        )
    }
}
