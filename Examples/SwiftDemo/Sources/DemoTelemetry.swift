import Foundation
import TelemetryKit

@MainActor
final class DemoTelemetry {
    static let shared = DemoTelemetry()

    private var client: TelemetryClient?

    var isCollectionEnabled: Bool {
        client != nil
    }

    private init() {}

    func setCollectionEnabled(_ enabled: Bool) async throws {
        if enabled {
            guard client == nil else { return }

            // This method is called only after the sample's user-facing switch is on.
            // A production app should use its reviewed, persisted consent decision.
            let configuration = makeConfiguration()
            client = try await TelemetryClient.start(configuration: configuration)
            _ = client?.capture(
                "demo.collection_enabled",
                attributes: [:],
                category: .custom,
                level: .info
            )
        } else if let runningClient = client {
            client = nil
            do {
                try await runningClient.setConsent(.denied)
                await runningClient.shutdown(flush: false)
            } catch {
                await runningClient.shutdown(flush: false)
                throw error
            }
        }
    }

    func captureButtonTap() -> TelemetryCaptureResult {
        guard let client else { return .clientStopped }

        return client.capture(
            "demo.button_tapped",
            attributes: [
                "screen": .string("home"),
                "control": .string("capture"),
            ],
            category: .custom,
            level: .info
        )
    }

    func performInstrumentedRequest() async throws -> Int {
        guard let client else { throw DemoTelemetryError.collectionDisabled }

        let span = client.startSpan("demo.example_request")
        let session = client.makeInstrumentedURLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (_, response) = try await session.data(
                from: URL(string: "https://example.com")!
            )
            guard let response = response as? HTTPURLResponse else {
                throw DemoTelemetryError.unexpectedResponse
            }
            span.end(
                status: .ok,
                attributes: ["http.status_code": .integer(Int64(response.statusCode))]
            )
            return response.statusCode
        } catch {
            span.end(
                status: .error,
                attributes: [
                    "error.type": .string(String(describing: type(of: error)))
                ]
            )
            throw error
        }
    }

    func flush() async throws {
        guard let client else { throw DemoTelemetryError.collectionDisabled }
        try await client.flush()
    }

    func flushIfRunning() async {
        guard let client else { return }
        _ = try? await client.flush()
    }

    private func makeConfiguration() -> TelemetryConfiguration {
        var configuration = TelemetryConfiguration(
            endpoint: URL(string: "https://telemetry.example.invalid/v1/events")!,
            apiKey: "replace-with-a-scoped-development-key",
            consent: .granted
        )
        configuration.enabledCategories = [.custom, .network, .span]
        configuration.privacy.networkURLCollection = .host
        configuration.instrumentation.sessionTrackingEnabled = false
        configuration.instrumentation.metricKitMetricsEnabled = false
        configuration.instrumentation.metricKitDiagnosticsEnabled = false
        return configuration
    }
}

enum DemoTelemetryError: LocalizedError {
    case collectionDisabled
    case unexpectedResponse

    var errorDescription: String? {
        switch self {
        case .collectionDisabled:
            return "Enable telemetry collection first."
        case .unexpectedResponse:
            return "The example request did not return an HTTP response."
        }
    }
}
