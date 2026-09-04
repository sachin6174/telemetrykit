import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

internal struct TelemetryTransportResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
}

internal protocol TelemetryTransport: Sendable {
    func upload(body: Data) async throws -> TelemetryTransportResponse
    func resumeUploads()
    func cancelOutstanding()
    func cancelAll()
}

internal final class HTTPTransport: TelemetryTransport, @unchecked Sendable {
    static let internalRequestHeader = "X-TelemetryKit-Internal"

    private let endpoint: URL
    private let apiKey: String?
    private let additionalHeaders: [String: String]
    private let delegate: BoundedResponseDelegate
    private let session: URLSession

    init(configuration: TelemetryConfiguration) {
        endpoint = configuration.endpoint
        apiKey = configuration.apiKey
        additionalHeaders = configuration.additionalHeaders

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.requestTimeout
        sessionConfiguration.timeoutIntervalForResource = min(
            configuration.requestTimeout * 2,
            24 * 60 * 60
        )
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = BoundedResponseDelegate(
            acceptsNewUploads: configuration.consent == .granted
        )
        self.delegate = delegate
        session = URLSession(
            configuration: sessionConfiguration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        delegate.cancelAll()
        session.invalidateAndCancel()
    }

    func upload(body: Data) async throws -> TelemetryTransportResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: Self.internalRequestHeader)
        request.setValue(
            "TelemetryKit/\(TelemetrySDKMetadata.current.version)",
            forHTTPHeaderField: "User-Agent"
        )

        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        for (name, value) in additionalHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let task = session.uploadTask(with: request, from: body)
        return try await delegate.perform(task)
    }

    func cancelAll() {
        delegate.cancelAll()
        session.invalidateAndCancel()
    }

    func cancelOutstanding() {
        delegate.cancelOutstanding()
    }

    func resumeUploads() {
        delegate.resumeUploads()
    }
}

/// Receives response bodies incrementally and discards every chunk. Unlike
/// `URLSession.data(for:)`, a hostile ingestion endpoint cannot make response
/// memory grow with an arbitrarily large body.
internal final class BoundedResponseDelegate: NSObject, URLSessionDataDelegate,
    @unchecked Sendable
{
    private struct PendingUpload {
        let task: URLSessionUploadTask
        let continuation: CheckedContinuation<TelemetryTransportResponse, Error>
        var response: HTTPURLResponse?
    }

    private let lock = NSLock()
    private var pending: [Int: PendingUpload] = [:]
    private var acceptsNewUploads: Bool
    private var isInvalidated = false

    internal init(acceptsNewUploads: Bool) {
        self.acceptsNewUploads = acceptsNewUploads
        super.init()
    }

    func perform(_ task: URLSessionUploadTask) async throws -> TelemetryTransportResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if Task.isCancelled || !acceptsNewUploads || isInvalidated {
                    lock.unlock()
                    task.cancel()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                pending[task.taskIdentifier] = PendingUpload(
                    task: task,
                    continuation: continuation,
                    response: nil
                )
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func cancelOutstanding() {
        lock.lock()
        acceptsNewUploads = false
        let tasks = pending.values.map(\.task)
        lock.unlock()
        for task in tasks {
            task.cancel()
        }
    }

    func resumeUploads() {
        lock.lock()
        if !isInvalidated {
            acceptsNewUploads = true
        }
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        acceptsNewUploads = false
        isInvalidated = true
        let tasks = pending.values.map(\.task)
        lock.unlock()
        for task in tasks {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        lock.lock()
        if var upload = pending[dataTask.taskIdentifier] {
            upload.response = response as? HTTPURLResponse
            pending[dataTask.taskIdentifier] = upload
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Never forward a telemetry body or credentials to a redirect target.
        // The original 3xx response is classified by the delivery pipeline.
        lock.lock()
        if var upload = pending[task.taskIdentifier] {
            upload.response = response
            pending[task.taskIdentifier] = upload
        }
        lock.unlock()
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        // Intentionally discard response bytes as they arrive.
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let upload = pending.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        guard let upload else { return }

        if let error {
            upload.continuation.resume(throwing: error)
            return
        }
        guard let response = upload.response ?? task.response as? HTTPURLResponse else {
            upload.continuation.resume(
                throwing: TelemetryError.transportFailed(
                    "The server returned a non-HTTP response."
                )
            )
            return
        }
        upload.continuation.resume(
            returning: TelemetryTransportResponse(
                statusCode: response.statusCode,
                headers: Self.retryAfterHeader(from: response)
            )
        )
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lock.lock()
        acceptsNewUploads = false
        isInvalidated = true
        let uploads = Array(pending.values)
        pending.removeAll()
        lock.unlock()
        let failure = error ?? URLError(.cancelled)
        for upload in uploads {
            upload.continuation.resume(throwing: failure)
        }
    }

    private static func retryAfterHeader(from response: HTTPURLResponse) -> [String: String] {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else {
            return [:]
        }
        return ["Retry-After": String(value.prefix(512))]
    }
}
