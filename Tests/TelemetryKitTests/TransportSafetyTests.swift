import Foundation
import XCTest

@testable import TelemetryKit

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

final class TransportSafetyTests: XCTestCase, @unchecked Sendable {
    func testResponseDelegateRejectsNewUploadWhileCollectionIsSuspended() async throws {
        let delegate = BoundedResponseDelegate(acceptsNewUploads: true)
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        let request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.test/events")))
        let task = session.uploadTask(with: request, from: Data("payload".utf8))
        delegate.cancelOutstanding()

        do {
            _ = try await delegate.perform(task)
            XCTFail("Expected a suspended transport to reject the upload")
        } catch is CancellationError {
            // Expected. The task is never resumed onto the network.
        }

        session.invalidateAndCancel()
    }

    func testResponseDelegateRefusesHTTPRedirects() throws {
        let delegate = BoundedResponseDelegate(acceptsNewUploads: true)
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        let originalURL = try XCTUnwrap(URL(string: "https://ingest.example.test/events"))
        let redirectedURL = try XCTUnwrap(URL(string: "https://other.example.test/collect"))
        let task = session.dataTask(with: originalURL)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: originalURL,
                statusCode: 307,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": redirectedURL.absoluteString]
            )
        )
        let selectedRequest = RequestProbe(initialValue: URLRequest(url: redirectedURL))

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: redirectedURL)
        ) { request in
            selectedRequest.record(request)
        }

        XCTAssertNil(selectedRequest.value)
        session.invalidateAndCancel()
    }

    func testInvalidatedResponseDelegateRejectsFutureUploads() async throws {
        let delegate = BoundedResponseDelegate(acceptsNewUploads: true)
        let session = URLSession(
            configuration: .ephemeral,
            delegate: delegate,
            delegateQueue: nil
        )
        delegate.urlSession(session, didBecomeInvalidWithError: nil)

        let task = session.uploadTask(
            with: URLRequest(url: try XCTUnwrap(URL(string: "https://example.test/events"))),
            from: Data("payload".utf8)
        )
        do {
            _ = try await delegate.perform(task)
            XCTFail("Expected an invalidated transport to reject the upload")
        } catch is CancellationError {
            // Expected.
        }
        session.invalidateAndCancel()
    }
}

private final class RequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: URLRequest?

    init(initialValue: URLRequest?) {
        storedValue = initialValue
    }

    var value: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func record(_ request: URLRequest?) {
        lock.lock()
        storedValue = request
        lock.unlock()
    }
}
