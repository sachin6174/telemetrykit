import Foundation
import XCTest

@testable import TelemetryKit

final class TelemetryValueTests: XCTestCase {
    func testEveryValueKindRoundTripsThroughJSON() throws {
        let value = TelemetryValue.object([
            "array": .array([
                .string("hello"),
                .integer(-42),
                .double(3.25),
                .boolean(true),
                .null,
            ]),
            "nested": .object(["answer": .integer(42)]),
        ])

        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(TelemetryValue.self, from: data)

        XCTAssertEqual(decoded, value)
    }

    func testJSONDecodingKeepsBooleansDistinctFromIntegers() throws {
        let data = Data(#"[true,1,1.5,"1",null]"#.utf8)

        XCTAssertEqual(
            try JSONDecoder().decode(TelemetryValue.self, from: data),
            .array([.boolean(true), .integer(1), .double(1.5), .string("1"), .null])
        )
    }

    func testIntegralDoublePreservesItsExplicitValueKindAcrossJSON() throws {
        let value = TelemetryValue.double(1.0)

        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(TelemetryValue.self, from: data), value)
    }

    func testFoundationConversionSupportsPropertyListShapedValues() throws {
        let foundationValue: [String: Any] = [
            "string": NSString(string: "value"),
            "integer": NSNumber(value: 7),
            "double": NSNumber(value: 2.5),
            "boolean": NSNumber(value: true),
            "array": [NSNull(), "nested"],
        ]

        XCTAssertEqual(
            TelemetryValue(foundationValue: foundationValue),
            .object([
                "string": .string("value"),
                "integer": .integer(7),
                "double": .double(2.5),
                "boolean": .boolean(true),
                "array": .array([.null, .string("nested")]),
            ])
        )
    }

    func testFoundationConversionRejectsUnsupportedAndOverlyDeepValues() {
        XCTAssertNil(TelemetryValue(foundationValue: Date()))
        XCTAssertNil(TelemetryValue(foundationValue: "value", depth: 11))
        XCTAssertNil(TelemetryValue(foundationValue: ["valid", Date()]))
    }
}

final class TelemetryPublicModelTests: XCTestCase {
    func testEventRoundTripsWithoutLosingIdentityOrMetadata() throws {
        let event = TelemetryEvent(
            id: UUID(uuidString: "5DDE6D35-D5A8-4B55-96E9-04C80D6E3451")!,
            name: "checkout.completed",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000.25),
            level: .warning,
            category: .custom,
            attributes: ["cart_size": .integer(3)]
        )

        let encoded = try JSONEncoder().encode(event)
        XCTAssertEqual(try JSONDecoder().decode(TelemetryEvent.self, from: encoded), event)
    }

    func testStableEnumRawValuesAndCaseLists() {
        XCTAssertEqual(
            TelemetryCategory.allCases.map(\.rawValue),
            [
                "custom", "network", "session", "span", "metricKitMetric",
                "metricKitDiagnostic", "sdkDiagnostic",
            ]
        )
        XCTAssertEqual(
            TelemetryLevel.allCases.map(\.rawValue),
            ["debug", "info", "warning", "error", "fatal"]
        )
        XCTAssertEqual(TelemetryCaptureResult.queueFull.rawValue, "queueFull")
        XCTAssertEqual(TelemetryConsent.granted.rawValue, "granted")
        XCTAssertEqual(TelemetryQueueOverflowPolicy.dropOldest.rawValue, "dropOldest")
        XCTAssertEqual(TelemetryNetworkURLCollection.hostAndPath.rawValue, "hostAndPath")
    }

    func testQueueAndFlushSnapshotsRoundTripThroughJSON() throws {
        let status = TelemetryQueueStatus(
            eventCount: 12,
            byteCount: 4_096,
            oldestEventDate: Date(timeIntervalSince1970: 100)
        )
        let report = TelemetryFlushReport(
            uploadedEventCount: 8,
            permanentlyDroppedEventCount: 1,
            remainingEventCount: 3
        )

        XCTAssertEqual(
            try JSONDecoder().decode(
                TelemetryQueueStatus.self,
                from: JSONEncoder().encode(status)
            ),
            status
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                TelemetryFlushReport.self,
                from: JSONEncoder().encode(report)
            ),
            report
        )
    }

    func testLocalizedErrorsProvideActionableDescriptions() {
        let expectations: [(TelemetryError, String)] = [
            (.invalidConfiguration("bad endpoint"), "bad endpoint"),
            (.storageUnavailable("read-only"), "read-only"),
            (.encodingFailed, "encode"),
            (.transportFailed("offline"), "offline"),
            (.operationRejected("busy"), "busy"),
            (.flushTimedOut, "timeout"),
            (.clientStopped, "stopped"),
        ]

        for (error, expectedFragment) in expectations {
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains(expectedFragment),
                "Expected \(error.localizedDescription) to contain \(expectedFragment)"
            )
        }
    }

    func testUploadBatchHasStableSchemaAndSDKMetadata() throws {
        let sentAt = Date(timeIntervalSince1970: 1_000)
        let event = TelemetryEvent(
            id: try XCTUnwrap(UUID(uuidString: "07F4A742-E3F8-42B0-A398-D2CE8A31C76D")),
            name: "test",
            timestamp: Date(timeIntervalSince1970: 900),
            level: .warning,
            category: .span,
            attributes: [
                "count": .integer(2),
                "ratio": .double(1),
                "sampled": .boolean(true),
                "missing": .null,
            ]
        )
        let batch = TelemetryUploadBatch(events: [event], sentAt: sentAt)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let encodedBatch = try encoder.encode(batch)

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedBatch) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            ["batchID", "events", "schemaVersion", "sdk", "sentAt"]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["sentAt"] as? String, "1970-01-01T00:16:40Z")
        let sdk = try XCTUnwrap(object["sdk"] as? [String: Any])
        XCTAssertEqual(sdk["name"] as? String, "telemetrykit-swift")
        XCTAssertEqual(sdk["version"] as? String, TelemetrySDKMetadata.version)
        let events = try XCTUnwrap(object["events"] as? [[String: Any]])
        let encodedEvent = try XCTUnwrap(events.first)
        XCTAssertEqual(
            Set(encodedEvent.keys),
            ["attributes", "category", "id", "level", "name", "timestamp"]
        )
        XCTAssertEqual(encodedEvent["name"] as? String, "test")
        XCTAssertEqual(encodedEvent["timestamp"] as? String, "1970-01-01T00:15:00Z")
        XCTAssertEqual(encodedEvent["level"] as? String, "warning")
        XCTAssertEqual(encodedEvent["category"] as? String, "span")
        let attributes = try XCTUnwrap(encodedEvent["attributes"] as? [String: [String: Any]])
        XCTAssertEqual(attributes["count"]?["type"] as? String, "integer")
        XCTAssertEqual(attributes["count"]?["value"] as? Int, 2)
        XCTAssertEqual(attributes["ratio"]?["type"] as? String, "double")
        XCTAssertEqual(attributes["ratio"]?["value"] as? Double, 1)
        XCTAssertEqual(attributes["sampled"]?["type"] as? String, "boolean")
        XCTAssertEqual(attributes["sampled"]?["value"] as? Bool, true)
        XCTAssertEqual(attributes["missing"]?["type"] as? String, "null")
        XCTAssertNil(attributes["missing"]?["value"])

        let eventBytes = try encoder.encode(event).count
        XCTAssertLessThanOrEqual(
            encodedBatch.count - eventBytes,
            TelemetryUploadBatch.maximumEnvelopeOverhead
        )
    }
}

final class TelemetryConfigurationTests: XCTestCase {
    func testDefaultsArePrivateBoundedAndOptIn() throws {
        let configuration = makeConfiguration()

        XCTAssertEqual(configuration.consent, .pending)
        XCTAssertEqual(configuration.enabledCategories, [.custom, .network, .session, .span])
        XCTAssertEqual(configuration.queueLimits.maximumMemoryEventCount, 500)
        XCTAssertEqual(configuration.queueLimits.maximumMemoryBytes, 1 * 1_024 * 1_024)
        XCTAssertEqual(configuration.queueLimits.maximumEventCount, 10_000)
        XCTAssertEqual(configuration.queueLimits.maximumDiskBytes, 20 * 1_024 * 1_024)
        XCTAssertEqual(configuration.queueLimits.maximumEventBytes, 64 * 1_024)
        XCTAssertEqual(configuration.queueLimits.overflowPolicy, .dropOldest)
        XCTAssertEqual(configuration.privacy.networkURLCollection, .host)
        XCTAssertFalse(configuration.instrumentation.sessionTrackingEnabled)
        XCTAssertFalse(configuration.instrumentation.metricKitMetricsEnabled)
        XCTAssertFalse(configuration.instrumentation.metricKitDiagnosticsEnabled)
        XCTAssertFalse(configuration.allowsInsecureTransport)
        XCTAssertNil(configuration.storageDirectory)
        XCTAssertNoThrow(try configuration.validate())
    }

    func testHTTPRequiresExplicitDevelopmentOverride() throws {
        var configuration = TelemetryConfiguration(
            endpoint: try XCTUnwrap(URL(string: "http://127.0.0.1:8080/events"))
        )

        assertInvalid(configuration)
        configuration.allowsInsecureTransport = true
        XCTAssertNoThrow(try configuration.validate())
    }

    func testEndpointRejectsUnsupportedSchemesAndSensitiveComponents() throws {
        for endpoint in [
            "ftp://example.com/events",
            "https://user@example.com/events",
            "https://user:secret@example.com/events",
            "https://example.com/events?token=secret",
            "https://example.com/events#fragment",
        ] {
            assertInvalid(
                TelemetryConfiguration(endpoint: try XCTUnwrap(URL(string: endpoint))),
                message: endpoint
            )
        }
    }

    func testEndpointRequiresAHostAndStorageDirectoryRequiresAFileURL() throws {
        assertInvalid(
            TelemetryConfiguration(endpoint: try XCTUnwrap(URL(string: "https:///events")))
        )
        assertInvalid {
            $0.storageDirectory = URL(string: "https://example.com/queue")
        }
    }

    func testBatchAndTimingValuesMustBePositive() {
        assertInvalid { $0.batchSize = 0 }
        assertInvalid { $0.batchByteLimit = 0 }
        assertInvalid { $0.flushInterval = 0 }
        assertInvalid { $0.requestTimeout = 0 }
        assertInvalid { $0.flushTimeout = 0 }
        assertInvalid { $0.shutdownFlushTimeout = 0 }
    }

    func testQueueLimitsMustBePositiveAndInternallyConsistent() {
        assertInvalid { $0.queueLimits.maximumMemoryEventCount = 0 }
        assertInvalid { $0.queueLimits.maximumMemoryBytes = 0 }
        assertInvalid { $0.queueLimits.maximumEventCount = 0 }
        assertInvalid { $0.queueLimits.maximumDiskBytes = 0 }
        assertInvalid { $0.queueLimits.maximumEventBytes = 0 }
        assertInvalid { $0.queueLimits.maximumEventAge = 0 }
        assertInvalid { $0.queueLimits.maximumEventBytes = $0.queueLimits.maximumDiskBytes + 1 }
        assertInvalid { $0.queueLimits.maximumEventBytes = $0.queueLimits.maximumMemoryBytes + 1 }
    }

    func testBatchByteLimitMustFitAnEventWithoutExceedingDiskCapacity() {
        assertInvalid {
            $0.batchByteLimit =
                $0.queueLimits.maximumEventBytes
                + TelemetryUploadBatch.maximumEnvelopeOverhead - 1
        }
        assertInvalid { $0.batchByteLimit = $0.queueLimits.maximumDiskBytes + 1 }

        var configuration = makeConfiguration()
        configuration.batchByteLimit =
            configuration.queueLimits.maximumEventBytes
            + TelemetryUploadBatch.maximumEnvelopeOverhead
        XCTAssertNoThrow(try configuration.validate())
    }

    func testRetryAndPrivacyLimitsAreValidated() {
        assertInvalid { $0.retryPolicy.initialDelay = -1 }
        assertInvalid {
            $0.retryPolicy.initialDelay = 2
            $0.retryPolicy.maximumDelay = 1
        }
        assertInvalid { $0.retryPolicy.maximumAttemptsPerCycle = 0 }
        assertInvalid { $0.privacy.maximumAttributeCount = 0 }
        assertInvalid { $0.privacy.maximumStringLength = 0 }
        assertInvalid { $0.privacy.maximumCollectionLength = 0 }
        assertInvalid { $0.privacy.maximumNestingDepth = 0 }
        assertInvalid { $0.privacy.maximumAttributeCount = 1_025 }
        assertInvalid { $0.privacy.maximumStringLength = 64 * 1_024 + 1 }
        assertInvalid { $0.privacy.maximumCollectionLength = 1_025 }
        assertInvalid { $0.privacy.maximumNestingDepth = 17 }
        assertInvalid {
            $0.privacy.redactedAttributeKeys = Set(
                (0...128).map { "key-\($0)" }
            )
        }
    }

    func testNonFiniteTimingValuesAndInvalidSessionTimeoutAreRejected() {
        assertInvalid { $0.flushInterval = .infinity }
        assertInvalid { $0.requestTimeout = .nan }
        assertInvalid { $0.flushTimeout = .nan }
        assertInvalid { $0.shutdownFlushTimeout = .infinity }
        assertInvalid { $0.flushTimeout = 24 * 60 * 60 + 1 }
        assertInvalid { $0.requestTimeout = 24 * 60 * 60 + 1 }
        assertInvalid { $0.queueLimits.maximumEventAge = .infinity }
        assertInvalid {
            $0.retryPolicy.initialDelay = .infinity
            $0.retryPolicy.maximumDelay = .infinity
        }
        assertInvalid { $0.instrumentation.sessionTimeout = 0 }
        assertInvalid { $0.instrumentation.sessionTimeout = .infinity }
    }

    func testReservedHeadersAreRejectedCaseInsensitively() {
        for header in [
            "Accept", "Authorization", "Content-Type", "cookie", "CONTENT-LENGTH", "Host",
            "User-Agent", "X-TelemetryKit-Internal",
        ] {
            assertInvalid {
                $0.additionalHeaders = [header: "value"]
            }
        }
        var configuration = makeConfiguration()
        configuration.additionalHeaders = ["X-Tenant-ID": "tenant"]
        XCTAssertNoThrow(try configuration.validate())
    }

    func testHeaderInjectionAndOversizedConfigurationValuesAreRejected() {
        assertInvalid { $0.additionalHeaders = ["X-Bad\r\nInjected": "value"] }
        assertInvalid { $0.additionalHeaders = ["X-Value": "safe\r\nInjected: true"] }
        assertInvalid { $0.additionalHeaders = ["X-Null": "bad\0value"] }
        assertInvalid { $0.additionalHeaders = ["X-Control": "bad\u{1F}value"] }
        assertInvalid { $0.additionalHeaders = ["not valid": "value"] }
        assertInvalid { $0.apiKey = "secret\nInjected: true" }
        assertInvalid { $0.apiKey = "secret\u{7F}" }
        assertInvalid { $0.apiKey = String(repeating: "x", count: 4_097) }
    }

    func testStorageNamespaceMustBeShortAndURLSafe() {
        assertInvalid { $0.storageNamespace = "" }
        assertInvalid { $0.storageNamespace = "contains a space" }
        assertInvalid { $0.storageNamespace = String(repeating: "x", count: 65) }

        var configuration = makeConfiguration()
        configuration.storageNamespace = "production.v2-us_east"
        XCTAssertNoThrow(try configuration.validate())
    }

    private func makeConfiguration() -> TelemetryConfiguration {
        TelemetryConfiguration(endpoint: URL(string: "https://example.com/v1/events")!)
    }

    private func assertInvalid(
        _ configuration: TelemetryConfiguration,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try configuration.validate(), message, file: file, line: line) { error in
            guard let telemetryError = error as? TelemetryError else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
            guard case .invalidConfiguration = telemetryError else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        }
    }

    private func assertInvalid(
        _ mutation: (inout TelemetryConfiguration) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var configuration = makeConfiguration()
        mutation(&configuration)
        assertInvalid(configuration, file: file, line: line)
    }
}
