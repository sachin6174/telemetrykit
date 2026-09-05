import Foundation
import TelemetryKit
import XCTest

/// These tests use only public APIs and also run against the release binary.
final class PublicRuntimeTests: XCTestCase, @unchecked Sendable {
    func testInstrumentedURLSessionProducesSanitizedRealMetrics() async throws {
        let destination = try makeServer([LoopbackServer.response(200)])
        let ingestion = try makeServer([LoopbackServer.response(202)])
        var config = try configuration(ingestion)
        config.privacy.networkURLCollection = .hostAndPath
        let client = try await makeClient(config)
        let session = client.makeInstrumentedURLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(destination.port)/request?token=private-query"))
        _ = try await session.data(from: url)
        let deadline = Date().addingTimeInterval(3)
        while await client.queueStatus().eventCount == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let report = try await client.flush()
        XCTAssertEqual(report.uploadedEventCount, 1)
        let request = try XCTUnwrap(ingestion.requests().first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.first?["name"] as? String, "network.request")
        XCTAssertEqual(events.first?["category"] as? String, "network")
        let text = String(decoding: request.body, as: UTF8.self)
        XCTAssertFalse(text.contains("private-query"))
        XCTAssertFalse(text.contains("?token="))
    }

    func testRealHTTPUploadUsesWireContractAndRedactsSecrets() async throws {
        let server = try makeServer([LoopbackServer.response(202)])
        let client = try await makeClient(configuration(server))
        XCTAssertEqual(
            client.capture(
                "runtime.upload",
                attributes: [
                    "token": .string("must-not-leave-process"), "count": .integer(42),
                ]), .accepted)
        let report = try await client.flush()
        XCTAssertEqual(report.uploadedEventCount, 1)
        let request = try XCTUnwrap(server.requests().first)
        XCTAssertTrue(request.headers.hasPrefix("POST /events HTTP/1.1"))
        XCTAssertTrue(request.headers.lowercased().contains("authorization: bearer test-only-key"))
        XCTAssertTrue(request.headers.lowercased().contains("content-type: application/json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(json["batchID"] as? String)
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        let attributes = try XCTUnwrap(events[0]["attributes"] as? [String: Any])
        let token = try XCTUnwrap(attributes["token"] as? [String: Any])
        XCTAssertEqual(token["type"] as? String, "string")
        XCTAssertEqual(token["value"] as? String, "[REDACTED]")
        XCTAssertFalse(String(decoding: request.body, as: UTF8.self).contains("must-not-leave-process"))
    }

    func testRealHTTPRetryPreservesEventIdentity() async throws {
        let server = try makeServer([
            LoopbackServer.response(503, headers: "Retry-After: 0\r\n"),
            LoopbackServer.response(202),
        ])
        let client = try await makeClient(configuration(server))
        let event = TelemetryEvent(name: "runtime.retry")
        XCTAssertEqual(client.capture(event), .accepted)
        let report = try await client.flush()
        XCTAssertEqual(report.uploadedEventCount, 1)
        XCTAssertEqual(server.requests().count, 2)
        for request in server.requests() {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            let events = try XCTUnwrap(json["events"] as? [[String: Any]])
            XCTAssertEqual(events.first?["id"] as? String, event.id.uuidString)
        }
    }

    func testHTTPFailureSurvivesShutdownAndRestart() async throws {
        let failing = try makeServer([LoopbackServer.response(503)])
        var config = try configuration(failing)
        config.retryPolicy.maximumAttemptsPerCycle = 1
        let client = try await makeClient(config)
        XCTAssertEqual(client.capture("runtime.offline"), .accepted)
        do { _ = try await client.flush() } catch { /* Queue must survive either outcome. */  }
        let before = await client.queueStatus()
        XCTAssertEqual(before.eventCount, 1)
        await client.shutdown(flush: false)
        let accepting = try makeServer([LoopbackServer.response(202)])
        config.endpoint = accepting.endpoint
        let restarted = try await makeClient(config)
        let report = try await restarted.flush()
        XCTAssertEqual(report.uploadedEventCount, 1)
        XCTAssertEqual(report.remainingEventCount, 0)
        XCTAssertEqual(accepting.requests().count, 1)
    }

    func testRedirectNeverForwardsCredentialsOrPayload() async throws {
        let target = try makeServer([LoopbackServer.response(202)])
        let source = try makeServer([
            LoopbackServer.response(307, headers: "Location: \(target.endpoint.absoluteString)\r\n")
        ])
        let client = try await makeClient(configuration(source))
        XCTAssertEqual(client.capture("runtime.redirect"), .accepted)
        do { _ = try await client.flush() } catch { /* Redirect is intentionally blocked. */  }
        XCTAssertEqual(source.requests().count, 1)
        XCTAssertTrue(target.requests().isEmpty)
    }

    func testConsentRevocationCancelsRealInflightRequestAndPurges() async throws {
        let server = try makeServer([])
        let client = try await makeClient(configuration(server))
        XCTAssertEqual(client.capture("runtime.cancel"), .accepted)
        let flush = Task { try await client.flush(timeout: 5) }
        let deadline = Date().addingTimeInterval(3)
        while server.requests().isEmpty, Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(server.requests().count, 1)
        try await client.setConsent(.denied)
        _ = await flush.result
        XCTAssertEqual(client.capture("after.denial"), .collectionDisabled)
        let status = await client.queueStatus()
        XCTAssertEqual(status.eventCount, 0)
    }

    private func makeServer(_ responses: [String]) throws -> LoopbackServer {
        let server = try LoopbackServer(responses: responses)
        addTeardownBlock { server.stop() }
        return server
    }

    private func configuration(_ server: LoopbackServer) throws -> TelemetryConfiguration {
        var config = TelemetryConfiguration(endpoint: server.endpoint, apiKey: "test-only-key", consent: .granted)
        config.allowsInsecureTransport = true  // Loopback fixture only; production defaults to HTTPS.
        config.flushInterval = 3_600
        config.retryPolicy = TelemetryRetryPolicy(initialDelay: 0.01, maximumDelay: 0.02, maximumAttemptsPerCycle: 2)
        config.storageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TelemetryKitRuntime-\(UUID().uuidString)", isDirectory: true)
        let directory = try XCTUnwrap(config.storageDirectory)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return config
    }

    private func makeClient(_ config: TelemetryConfiguration) async throws -> TelemetryClient {
        let client = try await TelemetryClient.start(configuration: config)
        addTeardownBlock { await client.shutdown(flush: false) }
        return client
    }
}
