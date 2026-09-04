import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A privacy-first, independently configured telemetry pipeline.
public final class TelemetryClient: @unchecked Sendable {
    private static let maximumFlushTimeout: TimeInterval = 24 * 60 * 60
    private let configuration: TelemetryConfiguration
    private let privacyFilter: TelemetryPrivacyFilter
    private let ingress: IngressBuffer
    private let captureAdmissionPool: CaptureAdmissionPool
    private let signalContinuation: AsyncStream<Void>.Continuation
    private let runtime: TelemetryRuntime
    private let storageLease: StorageDirectoryLease
    private let lifecycleGate = TelemetryOperationGate()
    private let instrumentationAllowed: Bool
    private let instrumentationLock = NSLock()
    private var instrumentation: [TelemetryInstrumentationLifecycle] = []
    private var instrumentationIsStarted = false
    private var isTerminal = false

    private init(
        configuration: TelemetryConfiguration,
        privacyFilter: TelemetryPrivacyFilter,
        ingress: IngressBuffer,
        signalContinuation: AsyncStream<Void>.Continuation,
        runtime: TelemetryRuntime,
        storageLease: StorageDirectoryLease,
        instrumentationAllowed: Bool
    ) {
        self.configuration = configuration
        self.privacyFilter = privacyFilter
        self.ingress = ingress
        self.captureAdmissionPool = CaptureAdmissionPool(limits: configuration.queueLimits)
        self.signalContinuation = signalContinuation
        self.runtime = runtime
        self.storageLease = storageLease
        self.instrumentationAllowed = instrumentationAllowed
    }

    deinit {
        markTerminal()
        stopConfiguredInstrumentation()
        ingress.stopAccepting()
        signalContinuation.finish()
        let runtime = runtime
        let storageLease = storageLease
        Task {
            await runtime.shutdown()
            storageLease.release()
        }
    }

    /// Creates storage, starts the actor pipeline, and registers explicitly
    /// enabled instrumentation. No event is accepted while consent is pending.
    public static func start(
        configuration: TelemetryConfiguration
    ) async throws -> TelemetryClient {
        try configuration.validate()
        let transport = HTTPTransport(configuration: configuration)
        do {
            return try await start(
                configuration: configuration,
                transport: transport,
                clock: SystemTelemetryClock(),
                randomSource: SystemTelemetryRandomSource(),
                startsBackgroundTasks: true,
                startsInstrumentation: true
            )
        } catch {
            transport.cancelAll()
            throw error
        }
    }

    internal static func start(
        configuration: TelemetryConfiguration,
        transport: TelemetryTransport,
        clock: TelemetryRuntimeClock,
        randomSource: TelemetryRandomSource,
        startsBackgroundTasks: Bool,
        startsInstrumentation: Bool
    ) async throws -> TelemetryClient {
        try configuration.validate()

        let storageDirectory = try configuration.resolvedStorageDirectory()
        let storageLease = try StorageDirectoryLease.acquire(for: storageDirectory)
        let effectiveCategories = configuration.effectiveEnabledCategories
        let privacyFilter = TelemetryPrivacyFilter(
            configuration: configuration.privacy,
            maximumOutputBytes: configuration.queueLimits.maximumEventBytes
        )
        let queue = try DiskEventQueue(
            directory: storageDirectory,
            limits: configuration.queueLimits
        )
        if configuration.consent != .granted {
            try await queue.removeAll()
        } else {
            try await queue.reconcilePayloads { envelope in
                Self.reconciledPayload(
                    envelope.payload,
                    expectedIdentifier: envelope.id,
                    privacyFilter: privacyFilter,
                    enabledCategories: effectiveCategories
                )
            }
        }
        let ingress = IngressBuffer(
            limits: configuration.queueLimits,
            enabledCategories: effectiveCategories,
            consent: configuration.consent
        )
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let runtime = TelemetryRuntime(
            configuration: configuration,
            ingress: ingress,
            queue: queue,
            transport: transport,
            clock: clock,
            randomSource: randomSource
        )
        let client = TelemetryClient(
            configuration: configuration,
            privacyFilter: privacyFilter,
            ingress: ingress,
            signalContinuation: signal.continuation,
            runtime: runtime,
            storageLease: storageLease,
            instrumentationAllowed: startsInstrumentation
        )

        if startsBackgroundTasks {
            await runtime.start(signalStream: signal.stream)
        }
        if startsInstrumentation, configuration.consent == .granted {
            client.startConfiguredInstrumentation()
        }
        return client
    }

    private static func reconciledPayload(
        _ payload: Data,
        expectedIdentifier: UUID,
        privacyFilter: TelemetryPrivacyFilter,
        enabledCategories: Set<TelemetryCategory>
    ) -> Data? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let event = try? decoder.decode(TelemetryEvent.self, from: payload),
            event.id == expectedIdentifier,
            enabledCategories.contains(event.category),
            let event = privacyFilter.sanitize(event)
        else {
            return nil
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(event)
    }

    /// Validates and admits one typed event without blocking on disk or network.
    @discardableResult
    public func capture(_ event: TelemetryEvent) -> TelemetryCaptureResult {
        let admissionRevision: UInt64
        switch ingress.beginCapture(category: event.category) {
        case .allowed(let revision):
            admissionRevision = revision
        case .rejected(let rejection):
            return rejection
        }
        guard captureAdmissionPool.tryAcquire() else { return .queueFull }
        defer { captureAdmissionPool.release() }

        guard let event = privacyFilter.sanitize(event) else {
            return .invalidEvent
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let payload = try? encoder.encode(event) else {
            return .invalidEvent
        }
        guard payload.count <= configuration.queueLimits.maximumEventBytes else {
            return .eventTooLarge
        }

        let pending = PendingEvent(
            id: event.id,
            createdAt: Date(),
            category: event.category,
            payload: payload
        )
        let result = ingress.offer(pending, admissionRevision: admissionRevision)
        if result == .accepted {
            signalContinuation.yield(())
        }
        return result
    }

    /// Convenience overload for the most common event shape.
    @discardableResult
    public func capture(
        _ name: String,
        attributes: [String: TelemetryValue] = [:],
        category: TelemetryCategory = .custom,
        level: TelemetryLevel = .info
    ) -> TelemetryCaptureResult {
        capture(
            TelemetryEvent(
                name: name,
                level: level,
                category: category,
                attributes: attributes
            )
        )
    }

    /// Attempts delivery of the events accepted before this call's watermark.
    /// Cancelling the caller leaves queued events intact and the client usable.
    @discardableResult
    public func flush(timeout: TimeInterval? = nil) async throws -> TelemetryFlushReport {
        let timeout = timeout ?? configuration.flushTimeout
        guard timeout.isFinite, timeout > 0, timeout <= Self.maximumFlushTimeout else {
            throw TelemetryError.invalidConfiguration(
                "The flush timeout must be finite, positive, and no longer than 24 hours."
            )
        }

        let nanoseconds = UInt64((timeout * 1_000_000_000).rounded())
        return try await FlushOperationCoordinator().run(
            runtime: runtime,
            timeoutNanoseconds: nanoseconds
        )
    }

    /// Updates consent. Revocation closes the synchronous gate before purging
    /// queued data; granting consent opens it only after actor state is ready.
    public func setConsent(_ consent: TelemetryConsent) async throws {
        try await lifecycleGate.acquire()
        do {
            try Task.checkCancellation()
            if consent == .granted {
                try await runtime.setConsent(consent)
                ingress.updateConsent(consent)
                startConfiguredInstrumentation()
                signalContinuation.yield(())
            } else {
                ingress.updateConsent(consent)
                stopConfiguredInstrumentation()
                try await runtime.setConsent(consent)
            }
            await lifecycleGate.release()
        } catch {
            await lifecycleGate.release()
            throw error
        }
    }

    /// Deletes all in-memory and persisted telemetry for this client.
    public func eraseStoredData() async throws {
        try await lifecycleGate.acquire()
        do {
            try Task.checkCancellation()
            ingress.erase()
            try await runtime.eraseStoredData()
            signalContinuation.yield(())
            await lifecycleGate.release()
        } catch {
            await lifecycleGate.release()
            throw error
        }
    }

    /// Returns a count-and-byte snapshot without exposing event contents.
    public func queueStatus() async -> TelemetryQueueStatus {
        await runtime.status()
    }

    /// Permanently stops this client instance.
    public func shutdown(flush: Bool = true) async {
        markTerminal()
        stopConfiguredInstrumentation()
        ingress.stopAccepting()
        signalContinuation.finish()

        guard await lifecycleGate.acquireForShutdown() else { return }
        if flush {
            _ = try? await self.flush(timeout: configuration.shutdownFlushTimeout)
        }
        await runtime.shutdown()
        storageLease.release()
        await lifecycleGate.release()
    }

    /// Makes a session that records task metrics without global swizzling.
    public func makeInstrumentedURLSession(
        configuration: URLSessionConfiguration = .default,
        delegateQueue: OperationQueue? = nil
    ) -> URLSession {
        TelemetryNetworkInstrumentation.makeSession(
            configuration: configuration,
            client: self,
            delegateQueue: delegateQueue
        )
    }

    /// Starts an end-once signposted performance span.
    public func startSpan(
        _ operation: String,
        attributes: [String: TelemetryValue] = [:]
    ) -> TelemetrySpan {
        let sanitized = privacyFilter.sanitizeSpan(
            operation: operation,
            attributes: attributes
        )
        return TelemetrySpan(
            operation: sanitized.operation,
            attributes: sanitized.attributes,
            client: self
        )
    }

    internal func sanitizedNetworkURLAttributes(_ url: URL?) -> [String: TelemetryValue] {
        privacyFilter.sanitizedURLAttributes(url)
    }

    internal func sanitizedSpanEndAttributes(
        _ attributes: [String: TelemetryValue]
    ) -> [String: TelemetryValue] {
        privacyFilter.sanitizeSpan(operation: "", attributes: attributes).attributes
    }

    private func startConfiguredInstrumentation() {
        guard instrumentationAllowed else { return }
        var lifecycles: [TelemetryInstrumentationLifecycle] = []
        if configuration.instrumentation.sessionTrackingEnabled {
            lifecycles.append(
                TelemetrySessionTracker(
                    client: self,
                    timeout: configuration.instrumentation.sessionTimeout
                )
            )
        }
        #if canImport(MetricKit)
            if configuration.instrumentation.metricKitMetricsEnabled
                || configuration.instrumentation.metricKitDiagnosticsEnabled
            {
                lifecycles.append(
                    TelemetryMetricKitSubscriber(
                        client: self,
                        metricsEnabled: configuration.instrumentation.metricKitMetricsEnabled,
                        diagnosticsEnabled: configuration.instrumentation.metricKitDiagnosticsEnabled,
                        maximumPayloadBytes: max(
                            1,
                            configuration.queueLimits.maximumEventBytes / 4
                        )
                    )
                )
            }
        #endif

        instrumentationLock.lock()
        guard !isTerminal, !instrumentationIsStarted else {
            instrumentationLock.unlock()
            return
        }
        instrumentationIsStarted = true
        instrumentation = lifecycles
        for lifecycle in lifecycles {
            lifecycle.start()
        }
        instrumentationLock.unlock()
    }

    private func stopConfiguredInstrumentation() {
        instrumentationLock.lock()
        guard instrumentationIsStarted else {
            instrumentationLock.unlock()
            return
        }
        instrumentationIsStarted = false
        let lifecycles = instrumentation
        instrumentation.removeAll()
        for lifecycle in lifecycles {
            lifecycle.stop()
        }
        instrumentationLock.unlock()
    }

    private func markTerminal() {
        instrumentationLock.lock()
        isTerminal = true
        instrumentationLock.unlock()
    }
}

extension TelemetryConfiguration {
    fileprivate func resolvedStorageDirectory() throws -> URL {
        if let storageDirectory {
            let resolved = storageDirectory.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path != "/" else {
                throw TelemetryError.invalidConfiguration(
                    "The storage directory cannot resolve to the filesystem root."
                )
            }
            return resolved
        }

        guard
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
        else {
            throw TelemetryError.storageUnavailable(
                "The application support directory could not be resolved."
            )
        }

        let endpointKey = Self.stableEndpointKey(endpoint.absoluteString)
        return
            applicationSupport
            .appendingPathComponent("TelemetryKit", isDirectory: true)
            .appendingPathComponent(endpointKey, isDirectory: true)
            .appendingPathComponent(storageNamespace, isDirectory: true)
    }

    private static func stableEndpointKey(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
