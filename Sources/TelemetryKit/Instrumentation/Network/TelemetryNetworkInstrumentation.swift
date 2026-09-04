import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Creates URL sessions whose task metrics are recorded as privacy-filtered
/// TelemetryKit events. This API performs no method swizzling.
public enum TelemetryNetworkInstrumentation {
    public static func makeSession(
        configuration: URLSessionConfiguration = .default,
        client: TelemetryClient,
        delegateQueue: OperationQueue? = nil
    ) -> URLSession {
        let delegate = TelemetryURLSessionDelegate(client: client)
        return URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: delegateQueue
        )
    }
}

/// A URL session delegate that converts Apple's task metrics into bounded,
/// body-free telemetry events.
///
/// If an application already owns a complex URLSession delegate, instantiate a
/// ``TelemetryNetworkMetricsRecorder`` and forward `didFinishCollecting` to it.
public final class TelemetryURLSessionDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    private let recorder: TelemetryNetworkMetricsRecorder

    public init(client: TelemetryClient) {
        recorder = TelemetryNetworkMetricsRecorder(client: client)
        super.init()
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        recorder.record(session: session, task: task, metrics: metrics)
    }
}

/// Manual bridge for applications that already provide their own session delegate.
public final class TelemetryNetworkMetricsRecorder: @unchecked Sendable {
    private struct TaskIdentity: Hashable {
        let scope: ObjectIdentifier
        let taskIdentifier: Int
    }

    private weak var client: TelemetryClient?
    private let lock = NSLock()
    private var recordedTaskIdentities: Set<TaskIdentity> = []
    private var recordedTaskIdentityOrder: [TaskIdentity] = []
    private let maximumRememberedTaskIdentities = 1_024

    public init(client: TelemetryClient) {
        self.client = client
    }

    /// Records metrics with a session-scoped task identity. Prefer this method
    /// when one recorder is shared by delegates for more than one session.
    public func record(
        session: URLSession,
        task: URLSessionTask,
        metrics: URLSessionTaskMetrics
    ) {
        record(
            task: task,
            metrics: metrics,
            identity: TaskIdentity(
                scope: ObjectIdentifier(session),
                taskIdentifier: task.taskIdentifier
            )
        )
    }

    /// Records metrics using the task object's identity as its deduplication
    /// scope. This remains convenient for a recorder owned by one delegate.
    public func record(task: URLSessionTask, metrics: URLSessionTaskMetrics) {
        record(
            task: task,
            metrics: metrics,
            identity: TaskIdentity(
                scope: ObjectIdentifier(task),
                taskIdentifier: task.taskIdentifier
            )
        )
    }

    private func record(
        task: URLSessionTask,
        metrics: URLSessionTaskMetrics,
        identity: TaskIdentity
    ) {
        guard let client else { return }
        guard
            task.currentRequest?.value(
                forHTTPHeaderField: HTTPTransport.internalRequestHeader
            ) != "1"
        else {
            return
        }

        lock.lock()
        let inserted = recordedTaskIdentities.insert(identity).inserted
        if inserted {
            recordedTaskIdentityOrder.append(identity)
            if recordedTaskIdentityOrder.count > maximumRememberedTaskIdentities {
                let expired = recordedTaskIdentityOrder.removeFirst()
                recordedTaskIdentities.remove(expired)
            }
        }
        lock.unlock()
        guard inserted else { return }

        var attributes: [String: TelemetryValue] = [
            "duration_ms": .double(metrics.taskInterval.duration * 1_000),
            "redirect_count": .integer(Int64(metrics.redirectCount)),
        ]

        if let method = task.currentRequest?.httpMethod {
            attributes["method"] = .string(method)
        }
        if let response = task.response as? HTTPURLResponse {
            attributes["status_code"] = .integer(Int64(response.statusCode))
        }

        let transaction = metrics.transactionMetrics.last
        Self.addDuration(
            named: "dns_ms",
            start: transaction?.domainLookupStartDate,
            end: transaction?.domainLookupEndDate,
            to: &attributes
        )
        Self.addDuration(
            named: "connect_ms",
            start: transaction?.connectStartDate,
            end: transaction?.connectEndDate,
            to: &attributes
        )
        Self.addDuration(
            named: "tls_ms",
            start: transaction?.secureConnectionStartDate,
            end: transaction?.secureConnectionEndDate,
            to: &attributes
        )
        Self.addDuration(
            named: "request_ms",
            start: transaction?.requestStartDate,
            end: transaction?.requestEndDate,
            to: &attributes
        )
        Self.addDuration(
            named: "response_ms",
            start: transaction?.responseStartDate,
            end: transaction?.responseEndDate,
            to: &attributes
        )

        if let transaction {
            if let protocolName = transaction.networkProtocolName {
                attributes["network_protocol"] = .string(protocolName)
            }
            attributes["connection_reused"] = .boolean(transaction.isReusedConnection)
            attributes["proxy_connection"] = .boolean(transaction.isProxyConnection)
            attributes["fetch_type"] = .integer(Int64(transaction.resourceFetchType.rawValue))
            attributes["request_header_bytes"] = .integer(
                Int64(transaction.countOfRequestHeaderBytesSent)
            )
            attributes["request_body_bytes"] = .integer(
                Int64(transaction.countOfRequestBodyBytesSent)
            )
            attributes["response_header_bytes"] = .integer(
                Int64(transaction.countOfResponseHeaderBytesReceived)
            )
            attributes["response_body_bytes"] = .integer(
                Int64(transaction.countOfResponseBodyBytesReceived)
            )
            #if !os(Linux) && !os(Windows)
                if #available(iOS 13.0, macOS 10.15, *) {
                    attributes["cellular"] = .boolean(transaction.isCellular)
                    attributes["expensive"] = .boolean(transaction.isExpensive)
                    attributes["constrained"] = .boolean(transaction.isConstrained)
                }
            #endif
        }

        for (key, value) in client.sanitizedNetworkURLAttributes(
            task.currentRequest?.url
        ) {
            attributes[key] = value
        }

        _ = client.capture(
            "network.request",
            attributes: attributes,
            category: .network,
            level: Self.level(for: task)
        )
    }

    private static func addDuration(
        named name: String,
        start: Date?,
        end: Date?,
        to attributes: inout [String: TelemetryValue]
    ) {
        guard let start, let end else { return }
        attributes[name] = .double(max(0, end.timeIntervalSince(start) * 1_000))
    }

    private static func level(for task: URLSessionTask) -> TelemetryLevel {
        if task.error != nil { return .error }
        guard let statusCode = (task.response as? HTTPURLResponse)?.statusCode else {
            return .info
        }
        if statusCode >= 500 { return .error }
        if statusCode >= 400 { return .warning }
        return .info
    }
}
