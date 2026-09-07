import Foundation
import TelemetryKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Owns the one live TelemetryKit client used by the showcase application.
/// UI code asks this object to perform a feature and receives a readable result.
@MainActor
final class TelemetryDemoService {
    static let shared = TelemetryDemoService()

    private(set) var client: TelemetryClient?
    private(set) var consent: TelemetryConsent = .pending

    var isRunning: Bool { client != nil }

    private init() {}

    /// Starts with pending consent on purpose. This proves that startup and
    /// permission are separate decisions and that capture fails closed.
    func start() async throws -> String {
        guard client == nil else { return "Client is already running." }

        let configuration = makeCompleteConfiguration(consent: .pending)
        client = try await TelemetryClient.start(configuration: configuration)
        consent = .pending
        return "Client started with pending consent. Captures are blocked until Grant is tapped."
    }

    func setConsent(_ newValue: TelemetryConsent) async throws -> String {
        guard let client else { throw DemoError.clientNotRunning }
        try await client.setConsent(newValue)
        consent = newValue
        return "Consent is now \(newValue.rawValue)."
    }

    /// Uses every TelemetryValue case in one deliberately non-sensitive event.
    func captureEveryValueType() throws -> String {
        let client = try requireClient()
        let event = TelemetryEvent(
            id: UUID(),
            name: "demo.all_value_types",
            timestamp: Date(),
            level: .info,
            category: .custom,
            attributes: [
                "string": .string("hello telemetry"),
                "integer": .integer(42),
                "double": .double(3.14159),
                "boolean": .boolean(true),
                "array": .array([.string("red"), .string("green"), .integer(3)]),
                "object": .object([
                    "screen": .string("feature_dashboard"),
                    "visible": .boolean(true),
                ]),
                "nothing": .null,
                // The configured privacy filter removes this value because the
                // key is in `redactedAttributeKeys`.
                "demo_secret": .string("this value must never leave the client"),
            ]
        )
        return describe(client.capture(event), eventName: event.name)
    }

    /// Exercises every public severity and category. Automatic-only categories
    /// are included here as synthetic teaching events; real MetricKit and session
    /// events are also produced by their adapters when iOS supplies the signals.
    func captureEveryLevelAndCategory() throws -> String {
        let client = try requireClient()
        var lines: [String] = []

        for (index, level) in TelemetryLevel.allCases.enumerated() {
            let result = client.capture(
                "demo.level.\(level.rawValue)",
                attributes: ["example_index": .integer(Int64(index))],
                category: .custom,
                level: level
            )
            lines.append("level \(level.rawValue): \(result.rawValue)")
        }

        for category in TelemetryCategory.allCases {
            let result = client.capture(
                "demo.category.\(category.rawValue)",
                attributes: ["source": .string("full_feature_demo")],
                category: category,
                level: .info
            )
            lines.append("category \(category.rawValue): \(result.rawValue)")
        }
        return lines.joined(separator: "\n")
    }

    /// Shows the successful, cancelled, and error span outcomes, and proves that
    /// ending the same span twice is ignored.
    func exerciseAllSpanOutcomes() async throws -> String {
        let client = try requireClient()

        let successful = client.startSpan(
            "demo.span.success",
            attributes: ["work_kind": .string("simulated")]
        )
        try await Task.sleep(nanoseconds: 30_000_000)
        let firstEnd = successful.end(status: .ok, attributes: ["items": .integer(3)])
        let secondEnd = successful.end(status: .error)

        let cancelled = client.startSpan("demo.span.cancelled")
        cancelled.end(status: .cancelled, attributes: ["reason": .string("demonstration")])

        let failed = client.startSpan("demo.span.error")
        failed.end(status: .error, attributes: ["error.type": .string("DemoFailure")])

        return "Span outcomes captured. First end=\(firstEnd); repeated end=\(secondEnd) (expected false)."
    }

    /// Uses the convenience method directly on TelemetryClient.
    func performClientInstrumentedRequest() async throws -> String {
        let client = try requireClient()
        let session = client.makeInstrumentedURLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        return try await performRequest(using: session, label: "client-created session")
    }

    /// Uses the public TelemetryNetworkInstrumentation factory explicitly.
    func performFactoryInstrumentedRequest() async throws -> String {
        let client = try requireClient()
        let session = TelemetryNetworkInstrumentation.makeSession(
            configuration: .ephemeral,
            client: client,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        return try await performRequest(using: session, label: "factory-created session")
    }

    /// Demonstrates the integration required when an app already owns its own
    /// URLSession delegate: forward Apple's metrics callback into the recorder.
    func performForwardedMetricsRequest() async throws -> String {
        let client = try requireClient()
        let delegate = ForwardingMetricsDelegate(client: client)
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        defer {
            session.finishTasksAndInvalidate()
            withExtendedLifetime(delegate) {}
        }
        return try await performRequest(using: session, label: "app-delegate forwarding session")
    }

    func queueStatus() async throws -> String {
        let client = try requireClient()
        let status = await client.queueStatus()
        let oldest = status.oldestEventDate?.formatted() ?? "none"
        return "Queue: \(status.eventCount) events, \(status.byteCount) payload bytes, oldest: \(oldest)."
    }

    func flush() async throws -> String {
        let client = try requireClient()
        let report = try await client.flush(timeout: 4)
        return "Flush report — uploaded: \(report.uploadedEventCount), permanently dropped: \(report.permanentlyDroppedEventCount), remaining: \(report.remainingEventCount)."
    }

    func demonstrateInvalidFlushTimeout() async throws -> String {
        let client = try requireClient()
        do {
            _ = try await client.flush(timeout: 0)
            return "Unexpectedly accepted an invalid timeout."
        } catch {
            return "Expected timeout validation error: \(error.localizedDescription)"
        }
    }

    func eraseStoredData() async throws -> String {
        let client = try requireClient()
        try await client.eraseStoredData()
        let status = await client.queueStatus()
        return "Local telemetry erased. Queue now contains \(status.eventCount) events."
    }

    func shutdown() async -> String {
        guard let runningClient = client else { return "Client is already stopped." }
        client = nil
        consent = .pending
        await runningClient.shutdown(flush: false)
        let result = runningClient.capture("demo.capture_after_shutdown")
        return "Client shut down. A capture on the stopped instance returned \(result.rawValue)."
    }

    func flushAtBackgroundBoundary() async {
        guard let client else { return }
        _ = try? await client.flush(timeout: 2)
    }

    /// Every configurable subsystem is set explicitly so this file doubles as a
    /// copyable reference. Values are intentionally small and demo-friendly.
    private func makeCompleteConfiguration(consent: TelemetryConsent) -> TelemetryConfiguration {
        var configuration = TelemetryConfiguration(
            // `.invalid` is reserved and cannot reach a real server. Replace it
            // with a controlled development receiver to observe successful flushes.
            endpoint: URL(string: "https://telemetry.example.invalid/v1/events")!,
            apiKey: "replace-with-a-scoped-development-ingest-key",
            consent: consent
        )

        configuration.enabledCategories = Set(TelemetryCategory.allCases)
        configuration.queueLimits = TelemetryQueueLimits(
            maximumMemoryEventCount: 250,
            maximumMemoryBytes: 512 * 1_024,
            maximumEventCount: 5_000,
            maximumDiskBytes: 10 * 1_024 * 1_024,
            maximumEventBytes: 32 * 1_024,
            maximumEventAge: 3 * 24 * 60 * 60,
            overflowPolicy: .dropOldest
        )
        configuration.retryPolicy = TelemetryRetryPolicy(
            initialDelay: 0.25,
            maximumDelay: 4,
            maximumAttemptsPerCycle: 2
        )
        configuration.privacy = TelemetryPrivacyConfiguration(
            redactedAttributeKeys: [
                "authorization", "cookie", "email", "password", "token", "demo_secret",
            ],
            maximumAttributeCount: 64,
            maximumStringLength: 1_024,
            maximumCollectionLength: 32,
            maximumNestingDepth: 6,
            networkURLCollection: .hostAndPath
        )
        configuration.instrumentation = TelemetryInstrumentationConfiguration(
            sessionTrackingEnabled: true,
            metricKitMetricsEnabled: true,
            metricKitDiagnosticsEnabled: true,
            sessionTimeout: 10 * 60
        )
        configuration.batchSize = 25
        configuration.batchByteLimit = 128 * 1_024
        configuration.flushInterval = 15
        configuration.requestTimeout = 5
        configuration.flushTimeout = 4
        configuration.shutdownFlushTimeout = 2
        configuration.allowsInsecureTransport = false
        configuration.additionalHeaders = ["X-Demo-App": "TelemetryKitFullFeatureDemo"]
        configuration.storageDirectory = nil
        configuration.storageNamespace = "full-feature-demo"
        return configuration
    }

    private func requireClient() throws -> TelemetryClient {
        guard let client else { throw DemoError.clientNotRunning }
        return client
    }

    private func performRequest(using session: URLSession, label: String) async throws -> String {
        let url = URL(string: "https://example.com/telemetrykit-demo?secret=never-record-this")!
        let (_, response) = try await session.data(from: url)
        guard let response = response as? HTTPURLResponse else {
            throw DemoError.unexpectedResponse
        }
        return "\(label) completed with HTTP \(response.statusCode). Query text is never recorded."
    }

    private func describe(_ result: TelemetryCaptureResult, eventName: String) -> String {
        "\(eventName): \(result.rawValue)"
    }
}

/// An example of an application-owned delegate that forwards metrics rather than
/// asking TelemetryKit to replace the app's existing delegate architecture.
private final class ForwardingMetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let recorder: TelemetryNetworkMetricsRecorder

    init(client: TelemetryClient) {
        recorder = TelemetryNetworkMetricsRecorder(client: client)
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        recorder.record(session: session, task: task, metrics: metrics)
    }
}

enum DemoError: LocalizedError {
    case clientNotRunning
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .clientNotRunning:
            return "Start the TelemetryKit client first."
        case .unexpectedResponse:
            return "The example request did not return an HTTP response."
        }
    }
}
