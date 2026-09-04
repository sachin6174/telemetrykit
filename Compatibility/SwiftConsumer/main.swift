import Foundation
import TelemetryKit

// This source is type-checked against the assembled XCFramework. It exercises
// representative public Swift APIs so missing module interfaces or accidental
// access-level changes fail distribution validation before release.
@available(iOS 15.0, *)
func exerciseTelemetryKitSwiftInterface(endpoint: URL) async throws {
    var configuration = TelemetryConfiguration(
        endpoint: endpoint,
        apiKey: "fixture-key",
        consent: .granted
    )
    configuration.enabledCategories = [.custom, .network, .session, .span]
    configuration.queueLimits = TelemetryQueueLimits(
        maximumMemoryEventCount: 32,
        maximumMemoryBytes: 256 * 1_024,
        maximumEventCount: 256,
        maximumDiskBytes: 2 * 1_024 * 1_024,
        maximumEventBytes: 32 * 1_024,
        maximumEventAge: 86_400,
        overflowPolicy: .dropOldest
    )
    configuration.retryPolicy = TelemetryRetryPolicy(
        initialDelay: 0.25,
        maximumDelay: 8,
        maximumAttemptsPerCycle: 3
    )
    configuration.privacy = TelemetryPrivacyConfiguration(
        redactedAttributeKeys: ["authorization", "token"],
        maximumAttributeCount: 32,
        maximumStringLength: 1_024,
        maximumCollectionLength: 32,
        maximumNestingDepth: 6,
        networkURLCollection: .host
    )
    configuration.instrumentation = TelemetryInstrumentationConfiguration(
        sessionTrackingEnabled: true,
        metricKitMetricsEnabled: false,
        metricKitDiagnosticsEnabled: false,
        sessionTimeout: 900
    )
    configuration.storageNamespace = "compatibility-fixture"

    let client = try await TelemetryClient.start(configuration: configuration)
    let event = TelemetryEvent(
        name: "swift.fixture",
        level: .info,
        category: .custom,
        attributes: [
            "string": .string("value"),
            "integer": .integer(42),
            "double": .double(3.5),
            "boolean": .boolean(true),
            "array": .array([.string("one"), .integer(2)]),
            "object": .object(["nested": .string("value")]),
            "null": .null,
        ]
    )
    _ = client.capture(event)
    _ = client.capture(
        "swift.fixture.convenience",
        attributes: ["source": .string("xcframework")],
        category: .custom,
        level: .debug
    )

    let span = client.startSpan("swift.fixture.span")
    _ = span.end(status: .ok)
    let session = client.makeInstrumentedURLSession(configuration: .ephemeral)
    session.invalidateAndCancel()

    _ = try await client.flush(timeout: 1)
    _ = await client.queueStatus()
    try await client.setConsent(.denied)
    try await client.eraseStoredData()
    await client.shutdown(flush: false)
}
