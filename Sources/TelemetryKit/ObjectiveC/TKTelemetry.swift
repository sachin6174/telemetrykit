#if canImport(ObjectiveC)
    import CoreFoundation
    import Foundation

    /// Objective-C representation of the consent gate applied by TelemetryKit.
    @objc(TKTelemetryConsent)
    public enum TKTelemetryConsent: Int {
        case pending
        case granted
        case denied

        fileprivate var swiftValue: TelemetryConsent {
            switch self {
            case .pending:
                return .pending
            case .granted:
                return .granted
            case .denied:
                return .denied
            }
        }
    }

    /// Objective-C event collection channels.
    @objc(TKTelemetryCategory)
    public enum TKTelemetryCategory: Int {
        case custom
        case network
        case session
        case span
        case metricKitMetric
        case metricKitDiagnostic
        case sdkDiagnostic

        fileprivate var swiftValue: TelemetryCategory {
            switch self {
            case .custom: return .custom
            case .network: return .network
            case .session: return .session
            case .span: return .span
            case .metricKitMetric: return .metricKitMetric
            case .metricKitDiagnostic: return .metricKitDiagnostic
            case .sdkDiagnostic: return .sdkDiagnostic
            }
        }
    }

    /// Objective-C event severity.
    @objc(TKTelemetryLevel)
    public enum TKTelemetryLevel: Int {
        case debug
        case info
        case warning
        case error
        case fatal

        fileprivate var swiftValue: TelemetryLevel {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .warning: return .warning
            case .error: return .error
            case .fatal: return .fatal
            }
        }
    }

    /// Objective-C queue overflow behavior.
    @objc(TKTelemetryQueueOverflowPolicy)
    public enum TKTelemetryQueueOverflowPolicy: Int {
        case dropNewest
        case dropOldest

        fileprivate var swiftValue: TelemetryQueueOverflowPolicy {
            self == .dropNewest ? .dropNewest : .dropOldest
        }
    }

    /// Objective-C network URL privacy levels.
    @objc(TKTelemetryNetworkURLCollection)
    public enum TKTelemetryNetworkURLCollection: Int {
        case none
        case host
        case hostAndPath

        fileprivate var swiftValue: TelemetryNetworkURLCollection {
            switch self {
            case .none: return .none
            case .host: return .host
            case .hostAndPath: return .hostAndPath
            }
        }
    }

    /// Objective-C span completion states.
    @objc(TKTelemetrySpanStatus)
    public enum TKTelemetrySpanStatus: Int {
        case ok
        case cancelled
        case error

        fileprivate var swiftValue: TelemetrySpanStatus {
            switch self {
            case .ok: return .ok
            case .cancelled: return .cancelled
            case .error: return .error
            }
        }
    }

    /// Stable error codes produced by the Objective-C compatibility layer.
    @objc(TKTelemetryErrorCode)
    public enum TKTelemetryErrorCode: Int {
        case invalidAttributes = 1
        case collectionDisabled
        case consentRequired
        case invalidEvent
        case eventTooLarge
        case queueFull
        case clientStopped
        case operationFailed
    }

    /// A mutable Objective-C configuration. Starting a client snapshots every value.
    @objc(TKTelemetryConfiguration)
    public final class TKTelemetryConfiguration: NSObject {
        @objc public let endpoint: URL
        @objc public let apiKey: String?
        @objc public let consent: TKTelemetryConsent

        @objc public var customEventsEnabled: Bool
        @objc public var networkEventsEnabled: Bool
        @objc public var sessionEventsEnabled: Bool
        @objc public var spanEventsEnabled: Bool
        @objc public var metricKitMetricsEnabled: Bool
        @objc public var metricKitDiagnosticsEnabled: Bool
        @objc public var sdkDiagnosticsEnabled: Bool
        @objc public var sessionTrackingEnabled: Bool
        @objc public var sessionTimeout: TimeInterval

        @objc public var maximumMemoryEventCount: Int
        @objc public var maximumMemoryBytes: Int
        @objc public var maximumEventCount: Int
        @objc public var maximumDiskBytes: Int
        @objc public var maximumEventBytes: Int
        @objc public var maximumEventAge: TimeInterval
        @objc public var queueOverflowPolicy: TKTelemetryQueueOverflowPolicy

        @objc public var retryInitialDelay: TimeInterval
        @objc public var retryMaximumDelay: TimeInterval
        @objc public var retryMaximumAttemptsPerCycle: Int

        @objc public var redactedAttributeKeys: [String]
        @objc public var maximumAttributeCount: Int
        @objc public var maximumStringLength: Int
        @objc public var maximumCollectionLength: Int
        @objc public var maximumNestingDepth: Int
        @objc public var networkURLCollection: TKTelemetryNetworkURLCollection

        @objc public var batchSize: Int
        @objc public var batchByteLimit: Int
        @objc public var flushInterval: TimeInterval
        @objc public var requestTimeout: TimeInterval
        @objc public var flushTimeout: TimeInterval
        @objc public var shutdownFlushTimeout: TimeInterval
        @objc public var allowsInsecureTransport: Bool
        @objc public var additionalHeaders: [String: String]
        @objc public var storageDirectory: URL?
        @objc public var storageNamespace: String

        /// Creates a configuration with an explicit initial consent decision.
        @objc(initWithEndpoint:apiKey:consent:)
        public init(endpoint: URL, apiKey: String?, consent: TKTelemetryConsent) {
            let defaults = TelemetryConfiguration(
                endpoint: endpoint,
                apiKey: apiKey,
                consent: consent.swiftValue
            )
            self.endpoint = endpoint
            self.apiKey = apiKey
            self.consent = consent
            self.customEventsEnabled = defaults.enabledCategories.contains(.custom)
            self.networkEventsEnabled = defaults.enabledCategories.contains(.network)
            self.sessionEventsEnabled = defaults.enabledCategories.contains(.session)
            self.spanEventsEnabled = defaults.enabledCategories.contains(.span)
            self.metricKitMetricsEnabled = defaults.instrumentation.metricKitMetricsEnabled
            self.metricKitDiagnosticsEnabled = defaults.instrumentation.metricKitDiagnosticsEnabled
            self.sdkDiagnosticsEnabled = defaults.enabledCategories.contains(.sdkDiagnostic)
            self.sessionTrackingEnabled = defaults.instrumentation.sessionTrackingEnabled
            self.sessionTimeout = defaults.instrumentation.sessionTimeout
            self.maximumMemoryEventCount = defaults.queueLimits.maximumMemoryEventCount
            self.maximumMemoryBytes = defaults.queueLimits.maximumMemoryBytes
            self.maximumEventCount = defaults.queueLimits.maximumEventCount
            self.maximumDiskBytes = defaults.queueLimits.maximumDiskBytes
            self.maximumEventBytes = defaults.queueLimits.maximumEventBytes
            self.maximumEventAge = defaults.queueLimits.maximumEventAge
            self.queueOverflowPolicy = .dropOldest
            self.retryInitialDelay = defaults.retryPolicy.initialDelay
            self.retryMaximumDelay = defaults.retryPolicy.maximumDelay
            self.retryMaximumAttemptsPerCycle = defaults.retryPolicy.maximumAttemptsPerCycle
            self.redactedAttributeKeys = defaults.privacy.redactedAttributeKeys.sorted()
            self.maximumAttributeCount = defaults.privacy.maximumAttributeCount
            self.maximumStringLength = defaults.privacy.maximumStringLength
            self.maximumCollectionLength = defaults.privacy.maximumCollectionLength
            self.maximumNestingDepth = defaults.privacy.maximumNestingDepth
            self.networkURLCollection = .host
            self.batchSize = defaults.batchSize
            self.batchByteLimit = defaults.batchByteLimit
            self.flushInterval = defaults.flushInterval
            self.requestTimeout = defaults.requestTimeout
            self.flushTimeout = defaults.flushTimeout
            self.shutdownFlushTimeout = defaults.shutdownFlushTimeout
            self.allowsInsecureTransport = defaults.allowsInsecureTransport
            self.additionalHeaders = defaults.additionalHeaders
            self.storageDirectory = defaults.storageDirectory
            self.storageNamespace = defaults.storageNamespace
            super.init()
        }

        /// Creates a configuration whose collection remains disabled until consent is granted.
        @objc(initWithEndpoint:apiKey:)
        public convenience init(endpoint: URL, apiKey: String?) {
            self.init(endpoint: endpoint, apiKey: apiKey, consent: .pending)
        }

        fileprivate var swiftValue: TelemetryConfiguration {
            var configuration = TelemetryConfiguration(
                endpoint: endpoint,
                apiKey: apiKey,
                consent: consent.swiftValue
            )
            configuration.enabledCategories = []
            if customEventsEnabled { configuration.enabledCategories.insert(.custom) }
            if networkEventsEnabled { configuration.enabledCategories.insert(.network) }
            if sessionEventsEnabled { configuration.enabledCategories.insert(.session) }
            if spanEventsEnabled { configuration.enabledCategories.insert(.span) }
            if metricKitMetricsEnabled { configuration.enabledCategories.insert(.metricKitMetric) }
            if metricKitDiagnosticsEnabled {
                configuration.enabledCategories.insert(.metricKitDiagnostic)
            }
            if sdkDiagnosticsEnabled { configuration.enabledCategories.insert(.sdkDiagnostic) }
            configuration.queueLimits = TelemetryQueueLimits(
                maximumMemoryEventCount: maximumMemoryEventCount,
                maximumMemoryBytes: maximumMemoryBytes,
                maximumEventCount: maximumEventCount,
                maximumDiskBytes: maximumDiskBytes,
                maximumEventBytes: maximumEventBytes,
                maximumEventAge: maximumEventAge,
                overflowPolicy: queueOverflowPolicy.swiftValue
            )
            configuration.retryPolicy = TelemetryRetryPolicy(
                initialDelay: retryInitialDelay,
                maximumDelay: retryMaximumDelay,
                maximumAttemptsPerCycle: retryMaximumAttemptsPerCycle
            )
            configuration.privacy = TelemetryPrivacyConfiguration(
                redactedAttributeKeys: Set(redactedAttributeKeys),
                maximumAttributeCount: maximumAttributeCount,
                maximumStringLength: maximumStringLength,
                maximumCollectionLength: maximumCollectionLength,
                maximumNestingDepth: maximumNestingDepth,
                networkURLCollection: networkURLCollection.swiftValue
            )
            configuration.instrumentation = TelemetryInstrumentationConfiguration(
                sessionTrackingEnabled: sessionTrackingEnabled,
                metricKitMetricsEnabled: metricKitMetricsEnabled,
                metricKitDiagnosticsEnabled: metricKitDiagnosticsEnabled,
                sessionTimeout: sessionTimeout
            )
            configuration.batchSize = batchSize
            configuration.batchByteLimit = batchByteLimit
            configuration.flushInterval = flushInterval
            configuration.requestTimeout = requestTimeout
            configuration.flushTimeout = flushTimeout
            configuration.shutdownFlushTimeout = shutdownFlushTimeout
            configuration.allowsInsecureTransport = allowsInsecureTransport
            configuration.additionalHeaders = additionalHeaders
            configuration.storageDirectory = storageDirectory
            configuration.storageNamespace = storageNamespace
            return configuration
        }
    }

    /// Objective-C queue snapshot without exposing stored payloads.
    @objc(TKTelemetryQueueStatus)
    public final class TKTelemetryQueueStatus: NSObject, @unchecked Sendable {
        @objc public let eventCount: Int
        @objc public let byteCount: Int
        @objc public let oldestEventDate: Date?

        fileprivate init(_ value: TelemetryQueueStatus) {
            eventCount = value.eventCount
            byteCount = value.byteCount
            oldestEventDate = value.oldestEventDate
            super.init()
        }
    }

    /// Objective-C result of an explicit bounded flush.
    @objc(TKTelemetryFlushReport)
    public final class TKTelemetryFlushReport: NSObject, @unchecked Sendable {
        @objc public let uploadedEventCount: Int
        @objc public let permanentlyDroppedEventCount: Int
        @objc public let remainingEventCount: Int

        fileprivate init(_ value: TelemetryFlushReport) {
            uploadedEventCount = value.uploadedEventCount
            permanentlyDroppedEventCount = value.permanentlyDroppedEventCount
            remainingEventCount = value.remainingEventCount
            super.init()
        }
    }

    /// Objective-C wrapper around an end-once signposted span.
    @objc(TKTelemetrySpan)
    public final class TKTelemetrySpan: NSObject, @unchecked Sendable {
        private let span: TelemetrySpan

        @objc public var identifier: String { span.id.uuidString.lowercased() }
        @objc public var operation: String { span.operation }

        fileprivate init(_ span: TelemetrySpan) {
            self.span = span
            super.init()
        }

        /// Ends this span. Completion receives `NO` when it had already ended.
        @objc(endWithStatus:attributes:completion:)
        public func end(
            status: TKTelemetrySpanStatus,
            attributes: NSDictionary,
            completion: @escaping @Sendable (Bool, NSError?) -> Void
        ) {
            do {
                let converted = try FoundationAttributeConverter.convert(attributes)
                let ended = span.end(status: status.swiftValue, attributes: converted)
                TKTelemetryClient.completeOnMain { completion(ended, nil) }
            } catch {
                let bridged = TKTelemetryClient.bridge(error)
                TKTelemetryClient.completeOnMain { completion(false, bridged) }
            }
        }
    }

    /// Objective-C compatibility facade for ``TelemetryClient``.
    ///
    /// Completion blocks for this type are always invoked asynchronously on the
    /// main thread. The wrapped Swift client remains responsible for serializing
    /// its mutable state and bounding queued telemetry.
    @objc(TKTelemetryClient)
    public final class TKTelemetryClient: NSObject, @unchecked Sendable {
        private static let errorDomain = "dev.telemetrykit.objective-c"

        private let client: TelemetryClient

        private init(client: TelemetryClient) {
            self.client = client
            super.init()
        }

        /// Starts an independent client.
        @objc(startWithConfiguration:completion:)
        public static func start(
            with configuration: TKTelemetryConfiguration,
            completion: @escaping @Sendable (TKTelemetryClient?, NSError?) -> Void
        ) {
            // Snapshot the mutable Foundation inputs before crossing the concurrency boundary.
            let swiftConfiguration = configuration.swiftValue

            Task { @MainActor in
                do {
                    let client = try await TelemetryClient.start(configuration: swiftConfiguration)
                    completion(TKTelemetryClient(client: client), nil)
                } catch {
                    completion(nil, bridge(error))
                }
            }
        }

        /// Captures one custom event after strictly converting Foundation values.
        ///
        /// Supported values are NSString, NSNumber, NSNull, NSArray, and
        /// NSDictionary with NSString keys. The completion indicates local queue
        /// admission only; a nil error does not mean the event reached the server.
        @objc(captureEventNamed:attributes:completion:)
        public func captureEvent(
            named name: String,
            attributes: NSDictionary,
            completion: @escaping @Sendable (NSError?) -> Void
        ) {
            captureEvent(
                named: name,
                attributes: attributes,
                category: .custom,
                level: .info,
                completion: completion
            )
        }

        /// Captures an event with an explicit category and severity.
        @objc(captureEventNamed:attributes:category:level:completion:)
        public func captureEvent(
            named name: String,
            attributes: NSDictionary,
            category: TKTelemetryCategory,
            level: TKTelemetryLevel,
            completion: @escaping @Sendable (NSError?) -> Void
        ) {
            let completionError: NSError?

            do {
                let converted = try FoundationAttributeConverter.convert(attributes)
                let result = client.capture(
                    name,
                    attributes: converted,
                    category: category.swiftValue,
                    level: level.swiftValue
                )
                completionError = Self.error(for: result)
            } catch {
                completionError = Self.bridge(error)
            }

            Self.completeOnMain {
                completion(completionError)
            }
        }

        /// Attempts to upload all currently queued events.
        @objc(flushWithCompletion:)
        public func flush(completion: @escaping @Sendable (NSError?) -> Void) {
            let client = client
            Task { @MainActor in
                do {
                    try await client.flush()
                    completion(nil)
                } catch {
                    completion(Self.bridge(error))
                }
            }
        }

        /// Attempts a bounded upload and returns counts for the completed watermark.
        @objc(flushWithReportCompletion:)
        public func flushWithReport(
            completion: @escaping @Sendable (TKTelemetryFlushReport?, NSError?) -> Void
        ) {
            let client = client
            Task { @MainActor in
                do {
                    let report = try await client.flush()
                    completion(TKTelemetryFlushReport(report), nil)
                } catch {
                    completion(nil, Self.bridge(error))
                }
            }
        }

        /// Changes the runtime collection consent.
        @objc(setConsent:completion:)
        public func setConsent(
            _ consent: TKTelemetryConsent,
            completion: @escaping @Sendable (NSError?) -> Void
        ) {
            let client = client
            let swiftConsent = consent.swiftValue
            Task { @MainActor in
                do {
                    try await client.setConsent(swiftConsent)
                    completion(nil)
                } catch {
                    completion(Self.bridge(error))
                }
            }
        }

        /// Removes both in-memory and persisted telemetry owned by this client.
        @objc(eraseStoredDataWithCompletion:)
        public func eraseStoredData(completion: @escaping @Sendable (NSError?) -> Void) {
            let client = client
            Task { @MainActor in
                do {
                    try await client.eraseStoredData()
                    completion(nil)
                } catch {
                    completion(Self.bridge(error))
                }
            }
        }

        /// Reads aggregate queue state without exposing event contents.
        @objc(queueStatusWithCompletion:)
        public func queueStatus(
            completion: @escaping @Sendable (TKTelemetryQueueStatus) -> Void
        ) {
            let client = client
            Task { @MainActor in
                completion(TKTelemetryQueueStatus(await client.queueStatus()))
            }
        }

        /// Creates an explicitly instrumented URL session without swizzling globals.
        @objc(makeInstrumentedURLSessionWithConfiguration:)
        public func makeInstrumentedURLSession(
            configuration: URLSessionConfiguration
        ) -> URLSession {
            client.makeInstrumentedURLSession(configuration: configuration)
        }

        /// Starts a signposted span after converting its initial attributes.
        @objc(startSpanNamed:attributes:completion:)
        public func startSpan(
            named operation: String,
            attributes: NSDictionary,
            completion: @escaping @Sendable (TKTelemetrySpan?, NSError?) -> Void
        ) {
            do {
                let converted = try FoundationAttributeConverter.convert(attributes)
                let span = TKTelemetrySpan(client.startSpan(operation, attributes: converted))
                Self.completeOnMain { completion(span, nil) }
            } catch {
                let bridged = Self.bridge(error)
                Self.completeOnMain { completion(nil, bridged) }
            }
        }

        /// Flushes pending work, stops the client, and then invokes completion.
        @objc(shutdownWithCompletion:)
        public func shutdown(completion: @escaping @Sendable () -> Void) {
            let client = client
            Task { @MainActor in
                await client.shutdown(flush: true)
                completion()
            }
        }

        fileprivate static func completeOnMain(_ body: @escaping @Sendable () -> Void) {
            DispatchQueue.main.async(execute: body)
        }

        fileprivate static func bridge(_ error: Error) -> NSError {
            if let bridgeError = error as? FoundationAttributeConversionError {
                return NSError(
                    domain: errorDomain,
                    code: TKTelemetryErrorCode.invalidAttributes.rawValue,
                    userInfo: [NSLocalizedDescriptionKey: bridgeError.localizedDescription]
                )
            }

            let underlyingError = error as NSError
            return NSError(
                domain: errorDomain,
                code: TKTelemetryErrorCode.operationFailed.rawValue,
                userInfo: [
                    NSLocalizedDescriptionKey: underlyingError.localizedDescription,
                    NSUnderlyingErrorKey: underlyingError,
                ]
            )
        }

        private static func error(for result: TelemetryCaptureResult) -> NSError? {
            let code: TKTelemetryErrorCode
            let description: String

            switch result {
            case .accepted:
                return nil
            case .collectionDisabled:
                code = .collectionDisabled
                description = "Telemetry collection is disabled."
            case .consentRequired:
                code = .consentRequired
                description = "Telemetry consent has not been granted."
            case .invalidEvent:
                code = .invalidEvent
                description = "The telemetry event is invalid."
            case .eventTooLarge:
                code = .eventTooLarge
                description = "The telemetry event exceeds the configured size limit."
            case .queueFull:
                code = .queueFull
                description = "The bounded telemetry queue cannot accept another event."
            case .clientStopped:
                code = .clientStopped
                description = "The TelemetryKit client has stopped."
            }

            return NSError(
                domain: errorDomain,
                code: code.rawValue,
                userInfo: [NSLocalizedDescriptionKey: description]
            )
        }
    }

    private enum FoundationAttributeConversionError: LocalizedError {
        case unsupportedValue(path: String, type: String)
        case nonStringKey(path: String)
        case nestingTooDeep(path: String)
        case tooManyValues
        case nonFiniteNumber(path: String)
        case integerOutOfRange(path: String)
        case stringTooLong(path: String)
        case stringBudgetExceeded

        var errorDescription: String? {
            switch self {
            case .unsupportedValue(let path, let type):
                return "Unsupported Objective-C attribute value at \(path): \(type)."
            case .nonStringKey(let path):
                return "Objective-C attribute dictionaries require NSString keys at \(path)."
            case .nestingTooDeep(let path):
                return "Objective-C attributes exceed the maximum bridge depth at \(path)."
            case .tooManyValues:
                return "Objective-C attributes exceed the bridge's bounded value count."
            case .nonFiniteNumber(let path):
                return "Objective-C attributes contain a non-finite number at \(path)."
            case .integerOutOfRange(let path):
                return "Objective-C attributes contain an integer outside Int64 at \(path)."
            case .stringTooLong(let path):
                return "Objective-C attributes contain an oversized string or key at \(path)."
            case .stringBudgetExceeded:
                return "Objective-C attributes exceed the bridge's aggregate string budget."
            }
        }
    }

    private enum FoundationAttributeConverter {
        // The SDK applies its configurable privacy limits after conversion. This
        // additional ceiling prevents hostile cyclic or enormous Foundation graphs
        // from causing unbounded bridge work before those limits can be applied.
        private static let maximumDepth = 10
        private static let maximumValueCount = 1_024
        private static let maximumStringByteCount = 64 * 1_024
        private static let maximumAggregateStringBytes = 256 * 1_024

        static func convert(_ attributes: NSDictionary) throws -> [String: TelemetryValue] {
            var remainingValueCount = maximumValueCount
            var remainingStringBytes = maximumAggregateStringBytes
            return try convertDictionary(
                attributes,
                path: "$",
                depth: 0,
                remainingValueCount: &remainingValueCount,
                remainingStringBytes: &remainingStringBytes
            )
        }

        private static func convert(
            _ value: Any,
            path: String,
            depth: Int,
            remainingValueCount: inout Int,
            remainingStringBytes: inout Int
        ) throws -> TelemetryValue {
            guard depth <= maximumDepth else {
                throw FoundationAttributeConversionError.nestingTooDeep(path: path)
            }
            guard remainingValueCount > 0 else {
                throw FoundationAttributeConversionError.tooManyValues
            }
            remainingValueCount -= 1

            if value is NSNull {
                return .null
            }
            if let string = value as? String {
                guard string.utf8.count <= maximumStringByteCount else {
                    throw FoundationAttributeConversionError.stringTooLong(path: path)
                }
                try consumeStringBytes(string.utf8.count, remaining: &remainingStringBytes)
                return .string(string)
            }
            if let number = value as? NSNumber {
                return try convertNumber(number, path: path)
            }
            if let array = value as? NSArray {
                var converted: [TelemetryValue] = []
                converted.reserveCapacity(min(array.count, maximumValueCount))
                for (index, item) in array.enumerated() {
                    converted.append(
                        try convert(
                            item,
                            path: "\(path)[\(index)]",
                            depth: depth + 1,
                            remainingValueCount: &remainingValueCount,
                            remainingStringBytes: &remainingStringBytes
                        )
                    )
                }
                return .array(converted)
            }
            if let dictionary = value as? NSDictionary {
                return .object(
                    try convertDictionary(
                        dictionary,
                        path: path,
                        depth: depth + 1,
                        remainingValueCount: &remainingValueCount,
                        remainingStringBytes: &remainingStringBytes
                    )
                )
            }

            throw FoundationAttributeConversionError.unsupportedValue(
                path: path,
                type: String(describing: type(of: value))
            )
        }

        private static func convertDictionary(
            _ dictionary: NSDictionary,
            path: String,
            depth: Int,
            remainingValueCount: inout Int,
            remainingStringBytes: inout Int
        ) throws -> [String: TelemetryValue] {
            guard depth <= maximumDepth else {
                throw FoundationAttributeConversionError.nestingTooDeep(path: path)
            }
            guard dictionary.count <= remainingValueCount else {
                throw FoundationAttributeConversionError.tooManyValues
            }

            var converted: [String: TelemetryValue] = [:]
            converted.reserveCapacity(min(dictionary.count, maximumValueCount))
            for (rawKey, rawValue) in dictionary {
                guard let key = rawKey as? String else {
                    throw FoundationAttributeConversionError.nonStringKey(path: path)
                }
                guard key.utf8.count <= maximumStringByteCount else {
                    throw FoundationAttributeConversionError.stringTooLong(path: path)
                }
                try consumeStringBytes(key.utf8.count, remaining: &remainingStringBytes)
                converted[key] = try convert(
                    rawValue,
                    path: "\(path).\(key)",
                    depth: depth,
                    remainingValueCount: &remainingValueCount,
                    remainingStringBytes: &remainingStringBytes
                )
            }
            return converted
        }

        private static func consumeStringBytes(_ count: Int, remaining: inout Int) throws {
            guard count <= remaining else {
                throw FoundationAttributeConversionError.stringBudgetExceeded
            }
            remaining -= count
        }

        private static func convertNumber(
            _ number: NSNumber,
            path: String
        ) throws -> TelemetryValue {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }

            let encoding = String(cString: number.objCType)
            switch encoding.first {
            case "c", "s", "i", "l", "q":
                return .integer(number.int64Value)
            case "C", "S", "I", "L", "Q":
                let value = number.uint64Value
                guard value <= UInt64(Int64.max) else {
                    throw FoundationAttributeConversionError.integerOutOfRange(path: path)
                }
                return .integer(Int64(value))
            default:
                let value = number.doubleValue
                guard value.isFinite else {
                    throw FoundationAttributeConversionError.nonFiniteNumber(path: path)
                }
                return .double(value)
            }
        }
    }
#endif
