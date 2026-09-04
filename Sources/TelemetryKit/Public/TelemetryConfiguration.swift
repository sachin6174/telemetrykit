import Foundation

/// Runtime consent applied before any event reaches persistent storage.
public enum TelemetryConsent: String, Codable, Sendable, Hashable {
    case pending
    case granted
    case denied
}

/// What to do when the bounded offline queue has reached a configured limit.
public enum TelemetryQueueOverflowPolicy: String, Codable, Sendable, Hashable {
    case dropNewest
    case dropOldest
}

/// The amount of URL information captured by network instrumentation.
public enum TelemetryNetworkURLCollection: String, Codable, Sendable, Hashable {
    /// Record no URL components.
    case none
    /// Record only the lowercased host.
    case host
    /// Record the host and path. Query strings and fragments are always removed.
    case hostAndPath
}

/// Limits that keep offline storage and per-upload memory bounded.
public struct TelemetryQueueLimits: Sendable, Equatable {
    public var maximumMemoryEventCount: Int
    public var maximumMemoryBytes: Int
    public var maximumEventCount: Int
    public var maximumDiskBytes: Int
    public var maximumEventBytes: Int
    public var maximumEventAge: TimeInterval
    public var overflowPolicy: TelemetryQueueOverflowPolicy

    public init(
        maximumMemoryEventCount: Int = 500,
        maximumMemoryBytes: Int = 1 * 1_024 * 1_024,
        maximumEventCount: Int = 10_000,
        maximumDiskBytes: Int = 20 * 1_024 * 1_024,
        maximumEventBytes: Int = 64 * 1_024,
        maximumEventAge: TimeInterval = 7 * 24 * 60 * 60,
        overflowPolicy: TelemetryQueueOverflowPolicy = .dropOldest
    ) {
        self.maximumMemoryEventCount = maximumMemoryEventCount
        self.maximumMemoryBytes = maximumMemoryBytes
        self.maximumEventCount = maximumEventCount
        self.maximumDiskBytes = maximumDiskBytes
        self.maximumEventBytes = maximumEventBytes
        self.maximumEventAge = maximumEventAge
        self.overflowPolicy = overflowPolicy
    }
}

/// Exponential retry settings. TelemetryKit applies full jitter for every delay.
public struct TelemetryRetryPolicy: Sendable, Equatable {
    public var initialDelay: TimeInterval
    public var maximumDelay: TimeInterval
    public var maximumAttemptsPerCycle: Int

    public init(
        initialDelay: TimeInterval = 1,
        maximumDelay: TimeInterval = 60,
        maximumAttemptsPerCycle: Int = 8
    ) {
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.maximumAttemptsPerCycle = maximumAttemptsPerCycle
    }

    /// Returns a full-jitter delay in `0 ... min(maximumDelay, initialDelay * 2^attempt)`.
    public func delay(attempt: Int, randomUnit: Double) -> TimeInterval {
        guard initialDelay.isFinite, maximumDelay.isFinite else { return 0 }
        let safeAttempt = max(0, min(attempt, 62))
        let exponent = pow(2, Double(safeAttempt))
        let ceiling = max(0, min(maximumDelay, max(0, initialDelay) * exponent))
        let unit = randomUnit.isFinite ? min(1, max(0, randomUnit)) : 0
        return max(0, ceiling * unit)
    }
}

/// Hard privacy limits applied before serialization and persistence.
public struct TelemetryPrivacyConfiguration: Sendable, Equatable {
    public var redactedAttributeKeys: Set<String>
    public var maximumAttributeCount: Int
    public var maximumStringLength: Int
    public var maximumCollectionLength: Int
    public var maximumNestingDepth: Int
    public var networkURLCollection: TelemetryNetworkURLCollection

    public init(
        redactedAttributeKeys: Set<String> = [
            "authorization", "cookie", "email", "password", "set-cookie", "token",
        ],
        maximumAttributeCount: Int = 64,
        maximumStringLength: Int = 2_048,
        maximumCollectionLength: Int = 64,
        maximumNestingDepth: Int = 8,
        networkURLCollection: TelemetryNetworkURLCollection = .host
    ) {
        self.redactedAttributeKeys = redactedAttributeKeys
        self.maximumAttributeCount = maximumAttributeCount
        self.maximumStringLength = maximumStringLength
        self.maximumCollectionLength = maximumCollectionLength
        self.maximumNestingDepth = maximumNestingDepth
        self.networkURLCollection = networkURLCollection
    }
}

/// Controls optional automatic instrumentation. Every option is off by default.
public struct TelemetryInstrumentationConfiguration: Sendable, Equatable {
    public var sessionTrackingEnabled: Bool
    public var metricKitMetricsEnabled: Bool
    public var metricKitDiagnosticsEnabled: Bool
    public var sessionTimeout: TimeInterval

    public init(
        sessionTrackingEnabled: Bool = false,
        metricKitMetricsEnabled: Bool = false,
        metricKitDiagnosticsEnabled: Bool = false,
        sessionTimeout: TimeInterval = 30 * 60
    ) {
        self.sessionTrackingEnabled = sessionTrackingEnabled
        self.metricKitMetricsEnabled = metricKitMetricsEnabled
        self.metricKitDiagnosticsEnabled = metricKitDiagnosticsEnabled
        self.sessionTimeout = sessionTimeout
    }
}

/// Complete configuration for one independent TelemetryKit client.
public struct TelemetryConfiguration: Sendable {
    public var endpoint: URL
    public var apiKey: String?
    public var consent: TelemetryConsent
    public var enabledCategories: Set<TelemetryCategory>
    public var queueLimits: TelemetryQueueLimits
    public var retryPolicy: TelemetryRetryPolicy
    public var privacy: TelemetryPrivacyConfiguration
    public var instrumentation: TelemetryInstrumentationConfiguration
    public var batchSize: Int
    public var batchByteLimit: Int
    public var flushInterval: TimeInterval
    public var requestTimeout: TimeInterval
    public var flushTimeout: TimeInterval
    public var shutdownFlushTimeout: TimeInterval
    public var allowsInsecureTransport: Bool
    public var additionalHeaders: [String: String]
    public var storageDirectory: URL?
    public var storageNamespace: String

    public init(
        endpoint: URL,
        apiKey: String? = nil,
        consent: TelemetryConsent = .pending
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.consent = consent
        self.enabledCategories = [.custom, .network, .session, .span]
        self.queueLimits = TelemetryQueueLimits()
        self.retryPolicy = TelemetryRetryPolicy()
        self.privacy = TelemetryPrivacyConfiguration()
        self.instrumentation = TelemetryInstrumentationConfiguration()
        self.batchSize = 50
        self.batchByteLimit = 512 * 1_024
        self.flushInterval = 30
        self.requestTimeout = 15
        self.flushTimeout = 30
        self.shutdownFlushTimeout = 5
        self.allowsInsecureTransport = false
        self.additionalHeaders = [:]
        self.storageDirectory = nil
        self.storageNamespace = "default"
    }
}

extension TelemetryConfiguration {
    internal var effectiveEnabledCategories: Set<TelemetryCategory> {
        var categories = enabledCategories
        if instrumentation.sessionTrackingEnabled {
            categories.insert(.session)
        }
        if instrumentation.metricKitMetricsEnabled {
            categories.insert(.metricKitMetric)
        }
        if instrumentation.metricKitDiagnosticsEnabled {
            categories.insert(.metricKitDiagnostic)
        }
        return categories
    }

    internal func validate() throws {
        let maximumOperationalInterval: TimeInterval = 24 * 60 * 60
        guard let scheme = endpoint.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw TelemetryError.invalidConfiguration("The endpoint must use HTTP or HTTPS.")
        }
        guard let host = endpoint.host, !host.isEmpty else {
            throw TelemetryError.invalidConfiguration("The endpoint must include a host.")
        }
        guard scheme == "https" || allowsInsecureTransport else {
            throw TelemetryError.invalidConfiguration(
                "Plain HTTP requires allowsInsecureTransport for local development."
            )
        }
        guard endpoint.user == nil,
            endpoint.password == nil,
            endpoint.query == nil,
            endpoint.fragment == nil
        else {
            throw TelemetryError.invalidConfiguration(
                "Credentials, query strings, and fragments are not allowed in the endpoint URL."
            )
        }
        guard endpoint.absoluteString.utf8.count <= 4_096 else {
            throw TelemetryError.invalidConfiguration("The endpoint URL is too long.")
        }
        if let apiKey {
            guard apiKey.utf8.count <= 4_096,
                Self.isValidHeaderValue(apiKey)
            else {
                throw TelemetryError.invalidConfiguration("The API key is not a valid header value.")
            }
        }
        guard batchSize > 0,
            batchSize <= 1_000,
            batchByteLimit > 0,
            batchByteLimit <= 16 * 1_024 * 1_024,
            flushInterval.isFinite,
            flushInterval > 0,
            flushInterval <= maximumOperationalInterval,
            requestTimeout.isFinite,
            requestTimeout > 0,
            requestTimeout <= maximumOperationalInterval,
            flushTimeout.isFinite,
            flushTimeout > 0,
            flushTimeout <= maximumOperationalInterval,
            shutdownFlushTimeout.isFinite,
            shutdownFlushTimeout > 0,
            shutdownFlushTimeout <= maximumOperationalInterval
        else {
            throw TelemetryError.invalidConfiguration("Batch and timing values must be positive.")
        }
        guard queueLimits.maximumEventCount > 0,
            queueLimits.maximumEventCount <= 100_000,
            queueLimits.maximumMemoryEventCount > 0,
            queueLimits.maximumMemoryEventCount <= 10_000,
            queueLimits.maximumMemoryBytes > 0,
            queueLimits.maximumMemoryBytes <= 256 * 1_024 * 1_024,
            queueLimits.maximumDiskBytes > 0,
            queueLimits.maximumDiskBytes <= 1_024 * 1_024 * 1_024,
            queueLimits.maximumEventBytes > 0,
            queueLimits.maximumEventBytes <= 16 * 1_024 * 1_024,
            queueLimits.maximumEventAge.isFinite,
            queueLimits.maximumEventAge > 0,
            queueLimits.maximumEventAge <= 365 * 24 * 60 * 60,
            queueLimits.maximumEventBytes <= queueLimits.maximumDiskBytes,
            queueLimits.maximumEventBytes <= queueLimits.maximumMemoryBytes
        else {
            throw TelemetryError.invalidConfiguration("Queue limits are inconsistent.")
        }
        guard batchByteLimit <= queueLimits.maximumDiskBytes else {
            throw TelemetryError.invalidConfiguration(
                "The batch byte limit exceeds the disk queue limit.")
        }
        let minimumBatchBytes = queueLimits.maximumEventBytes.addingReportingOverflow(
            TelemetryUploadBatch.maximumEnvelopeOverhead
        )
        guard !minimumBatchBytes.overflow, batchByteLimit >= minimumBatchBytes.partialValue else {
            throw TelemetryError.invalidConfiguration(
                "The batch byte limit must fit one maximum-sized event and its envelope."
            )
        }
        guard retryPolicy.initialDelay.isFinite,
            retryPolicy.maximumDelay.isFinite,
            retryPolicy.initialDelay >= 0,
            retryPolicy.maximumDelay >= retryPolicy.initialDelay,
            retryPolicy.maximumDelay <= maximumOperationalInterval,
            retryPolicy.maximumAttemptsPerCycle > 0,
            retryPolicy.maximumAttemptsPerCycle <= 32
        else {
            throw TelemetryError.invalidConfiguration("Retry settings are inconsistent.")
        }
        guard privacy.maximumAttributeCount > 0,
            privacy.maximumAttributeCount <= 1_024,
            privacy.maximumStringLength > 0,
            privacy.maximumStringLength <= 64 * 1_024,
            privacy.maximumCollectionLength > 0,
            privacy.maximumCollectionLength <= 1_024,
            privacy.maximumNestingDepth > 0,
            privacy.maximumNestingDepth <= 16,
            privacy.redactedAttributeKeys.count <= 128,
            privacy.redactedAttributeKeys.allSatisfy({
                !$0.isEmpty && $0.utf8.count <= 256
            })
        else {
            throw TelemetryError.invalidConfiguration("Privacy limits must be positive.")
        }
        guard instrumentation.sessionTimeout.isFinite,
            instrumentation.sessionTimeout > 0,
            instrumentation.sessionTimeout <= maximumOperationalInterval
        else {
            throw TelemetryError.invalidConfiguration("The session timeout must be finite and positive.")
        }
        guard
            storageNamespace.utf8.count <= 64,
            storageNamespace.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"#,
                options: .regularExpression
            ) != nil
        else {
            throw TelemetryError.invalidConfiguration(
                "The storage namespace must be 1–64 URL-safe characters."
            )
        }
        if let storageDirectory {
            guard storageDirectory.isFileURL,
                storageDirectory.standardizedFileURL.path != "/"
            else {
                throw TelemetryError.invalidConfiguration(
                    "The storage directory must be a dedicated, non-root file URL."
                )
            }
        }
        let forbiddenHeaders = Set([
            "accept", "authorization", "content-length", "content-type", "cookie", "host",
            "user-agent", HTTPTransport.internalRequestHeader.lowercased(),
        ])
        guard additionalHeaders.count <= 32,
            additionalHeaders.allSatisfy({ name, value in
                name.utf8.count <= 128
                    && name.range(
                        of: #"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"#,
                        options: .regularExpression
                    ) != nil
                    && !forbiddenHeaders.contains(name.lowercased())
                    && value.utf8.count <= 4_096
                    && Self.isValidHeaderValue(value)
            })
        else {
            throw TelemetryError.invalidConfiguration(
                "Additional HTTP headers contain a reserved, malformed, or oversized value."
            )
        }
    }

    private static func isValidHeaderValue(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            scalar.value == 0x09 || (scalar.value >= 0x20 && scalar.value != 0x7F)
        }
    }
}
