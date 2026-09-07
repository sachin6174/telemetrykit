// Foundation is Apple's basic toolbox. This file needs it for common building
// blocks such as `URL`, `Data`, `Date`, `UUID`, `JSONEncoder`, `JSONDecoder`,
// `FileManager`, `NSLock`, and `TimeInterval`.
import Foundation

#if canImport(FoundationNetworking)
    // On Apple platforms, networking types such as `URLSession` come from
    // Foundation. On platforms such as Linux, they live in the separate
    // FoundationNetworking module. This conditional import lets the same source
    // file compile in either environment.
    import FoundationNetworking
#endif

/// The main doorway into TelemetryKit.
///
/// Think of a `TelemetryClient` as a small, private post office owned by one app:
///
/// 1. The app creates a ``TelemetryConfiguration`` describing where telemetry
///    may be sent and what the user has permitted.
/// 2. The app passes that configuration to ``start(configuration:)``.
/// 3. The app gives events to ``capture(_:attributes:category:level:)``.
/// 4. TelemetryKit checks privacy rules, temporarily holds accepted events, saves
///    them to disk when needed, and sends them in batches in the background.
/// 5. The app can call ``flush(timeout:)`` or ``shutdown(flush:)`` at an
///    important lifecycle boundary.
///
/// Each client is independent. Creating two clients is like creating two post
/// offices: each has its own configuration and queue. They must not point at the
/// same storage directory at the same time.
///
/// `final` means another class cannot inherit from `TelemetryClient`. That keeps
/// the SDK's lifecycle and thread-safety promises under TelemetryKit's control.
///
/// `@unchecked Sendable` tells Swift that this reference may cross concurrency
/// boundaries. The word "unchecked" is an important promise made by this file:
/// the compiler cannot prove all of the safety automatically, so TelemetryKit
/// protects shared mutable state with locks, thread-safe helper objects, and the
/// actor-backed runtime below.
public final class TelemetryClient: @unchecked Sendable {
    // A caller may choose a custom flush timeout, but an accidental gigantic
    // value should not make a task appear to wait forever. This is 24 hours:
    // 24 hours × 60 minutes × 60 seconds.
    private static let maximumFlushTimeout: TimeInterval = 24 * 60 * 60

    // `let` means these references never point to a different object after this
    // client is initialized. The objects may manage their own internal state.

    // The validated settings snapshot used for this client's whole lifetime.
    private let configuration: TelemetryConfiguration

    // The privacy checkpoint. It removes or rejects information that the
    // configured privacy rules do not allow before an event enters the queue.
    private let privacyFilter: TelemetryPrivacyFilter

    // A small, bounded, thread-safe waiting room for newly captured events.
    // `capture` uses it synchronously so callers do not have to wait for disk or
    // network work.
    private let ingress: IngressBuffer

    // A second admission limit covering capture work that is currently being
    // encoded. It prevents many simultaneous callers from using unbounded memory
    // before their events have reached `ingress`.
    private let captureAdmissionPool: CaptureAdmissionPool

    // `capture` taps this continuation after accepting an event. That tap wakes
    // the background runtime and says, "There may be new work to process."
    private let signalContinuation: AsyncStream<Void>.Continuation

    // The actor-backed engine that moves events from memory to disk and network.
    private let runtime: TelemetryRuntime

    // An ownership token for the storage directory. Holding it prevents two live
    // clients from accidentally changing the same disk queue at once.
    private let storageLease: StorageDirectoryLease

    // Consent changes, erasure, and shutdown must not race one another. This gate
    // makes those bigger lifecycle operations take turns.
    private let lifecycleGate = TelemetryOperationGate()

    // Tests can create a client without starting operating-system instrumentation.
    // Normal public startup passes `true`.
    private let instrumentationAllowed: Bool

    // The next four properties are read or changed together. `NSLock` protects
    // them because instrumentation callbacks can arrive on different threads.
    private let instrumentationLock = NSLock()
    private var instrumentation: [TelemetryInstrumentationLifecycle] = []
    private var instrumentationIsStarted = false
    private var isTerminal = false

    /// Assembles a client from pieces that startup has already prepared.
    ///
    /// This initializer is `private`, so an app cannot bypass validation by
    /// writing `TelemetryClient(...)`. Apps must use ``start(configuration:)``.
    /// Keeping slow and throwable preparation in `start` also means this
    /// initializer only connects already-created parts.
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

    /// A final safety net for a client that is released without explicit shutdown.
    ///
    /// `deinit` runs when Swift destroys the last strong reference to this client.
    /// Synchronous admission is closed immediately. Actor shutdown and lease
    /// release are asynchronous, so a child `Task` finishes those pieces.
    ///
    /// Applications should still call ``shutdown(flush:)`` themselves when they
    /// own a clear lifecycle boundary. A destructor cannot promise that there is
    /// enough process lifetime left to upload pending events.
    deinit {
        // Permanently prevent instrumentation from being started again.
        markTerminal()
        // Stop session or MetricKit listeners so they produce no more events.
        stopConfiguredInstrumentation()
        // Reject any new synchronous `capture` call immediately.
        ingress.stopAccepting()
        // Close the wake-up stream because no more wake-up messages will arrive.
        signalContinuation.finish()

        // Copy these properties into local constants so the asynchronous task
        // does not capture `self` while `self` is being destroyed.
        let runtime = runtime
        let storageLease = storageLease
        Task {
            // Ask the actor-backed worker to stop its background work.
            await runtime.shutdown()
            // Let a future client safely use this storage directory.
            storageLease.release()
        }
    }

    /// Creates and starts a fully working telemetry client.
    ///
    /// This is the public entry point most Swift applications call. It performs
    /// startup asynchronously because opening and cleaning storage may require
    /// disk work. It can throw when configuration or storage setup is unsafe.
    ///
    /// A tiny usage example:
    ///
    /// ```swift
    /// let client = try await TelemetryClient.start(configuration: configuration)
    /// ```
    ///
    /// Reading the declaration from left to right:
    ///
    /// - `public`: an app importing TelemetryKit may call it.
    /// - `static`: it creates a client; no existing client is needed first.
    /// - `async`: the caller uses `await` while startup work completes.
    /// - `throws`: the caller uses `try` and handles a possible error.
    /// - `-> TelemetryClient`: success returns the ready-to-use client.
    ///
    /// Starting a client while consent is `.pending` or `.denied` does not save
    /// new events for later. Startup clears old queued data in that namespace and
    /// capture remains closed until the app explicitly grants consent.
    public static func start(
        configuration: TelemetryConfiguration
    ) async throws -> TelemetryClient {
        // Fail before creating resources if settings are contradictory or unsafe.
        // The internal startup below validates again because tests can call that
        // lower-level overload directly with substitute dependencies.
        try configuration.validate()

        // Build the real HTTP sender used by production clients. It knows the
        // endpoint, authentication, headers, and transport rules in configuration.
        let transport = HTTPTransport(configuration: configuration)
        do {
            // Delegate the detailed assembly to the internal overload. Keeping
            // replaceable clock, randomness, and transport arguments there makes
            // startup behavior deterministic and testable without real servers.
            return try await start(
                configuration: configuration,
                transport: transport,
                clock: SystemTelemetryClock(),
                randomSource: SystemTelemetryRandomSource(),
                startsBackgroundTasks: true,
                startsInstrumentation: true
            )
        } catch {
            // Startup may fail after the transport has created URL-session work.
            // Cancel it so a failed start leaves no networking alive in the
            // background, then give the original error back to the application.
            transport.cancelAll()
            throw error
        }
    }

    /// The testable assembly path behind the public ``start(configuration:)``.
    ///
    /// `internal` means code inside this Swift package (especially tests using
    /// `@testable import`) can supply a fake transport, clock, or random source.
    /// Production applications do not call this overload.
    internal static func start(
        configuration: TelemetryConfiguration,
        transport: TelemetryTransport,
        clock: TelemetryRuntimeClock,
        randomSource: TelemetryRandomSource,
        startsBackgroundTasks: Bool,
        startsInstrumentation: Bool
    ) async throws -> TelemetryClient {
        // Never trust that another caller already validated the configuration.
        try configuration.validate()

        // Decide exactly which folder owns this client's persistent queue.
        let storageDirectory = try configuration.resolvedStorageDirectory()

        // Exclusively claim that folder. If another live client or process owns
        // it, acquisition throws instead of risking corrupt or mixed telemetry.
        let storageLease = try StorageDirectoryLease.acquire(for: storageDirectory)

        // Automatic instrumentation may require categories in addition to the
        // categories explicitly selected for manual capture.
        let effectiveCategories = configuration.effectiveEnabledCategories

        // Prepare the privacy filter once and cap its output to the maximum size
        // that the queue will permit for one encoded event.
        let privacyFilter = TelemetryPrivacyFilter(
            configuration: configuration.privacy,
            maximumOutputBytes: configuration.queueLimits.maximumEventBytes
        )

        // Open (or create) the bounded on-disk queue.
        let queue = try DiskEventQueue(
            directory: storageDirectory,
            limits: configuration.queueLimits
        )

        // Privacy rule: data must not wait around while permission is absent.
        if configuration.consent != .granted {
            // A failure to delete is an error. Startup must not pretend that old
            // telemetry disappeared if the disk operation did not succeed.
            try await queue.removeAll()
        } else {
            // Rules may have changed since an event was saved by an older client.
            // Re-read every stored payload and keep only data that is still valid,
            // belongs to the expected envelope, uses an enabled category, and
            // survives today's privacy filter.
            try await queue.reconcilePayloads { envelope in
                Self.reconciledPayload(
                    envelope.payload,
                    expectedIdentifier: envelope.id,
                    privacyFilter: privacyFilter,
                    enabledCategories: effectiveCategories
                )
            }
        }

        // Create the synchronous memory entrance with the same category, consent,
        // and capacity decisions used by the rest of the pipeline.
        let ingress = IngressBuffer(
            limits: configuration.queueLimits,
            enabledCategories: effectiveCategories,
            consent: configuration.consent
        )

        // This stream carries no event data—only a wake-up signal. Keeping newest
        // one means ten rapid captures can collapse into one pending "wake up"
        // message; the runtime drains all available work after it wakes.
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))

        // Assemble the asynchronous engine with its real or test-provided parts.
        let runtime = TelemetryRuntime(
            configuration: configuration,
            ingress: ingress,
            queue: queue,
            transport: transport,
            clock: clock,
            randomSource: randomSource
        )

        // Now that every dependency exists, connect them into the public client.
        let client = TelemetryClient(
            configuration: configuration,
            privacyFilter: privacyFilter,
            ingress: ingress,
            signalContinuation: signal.continuation,
            runtime: runtime,
            storageLease: storageLease,
            instrumentationAllowed: startsInstrumentation
        )

        // Most real clients start their worker immediately. Tests may turn this
        // off so they can inspect a precise intermediate state.
        if startsBackgroundTasks {
            await runtime.start(signalStream: signal.stream)
        }

        // Automatic observers must start only when both the caller requested them
        // and consent already permits collection.
        if startsInstrumentation, configuration.consent == .granted {
            client.startConfiguredInstrumentation()
        }

        // Every required startup step succeeded. Ownership now transfers to the
        // returned client and the application can begin using it.
        return client
    }

    /// Re-checks one event that was previously stored on disk.
    ///
    /// The outer disk record (the "envelope") has an identifier, and the JSON
    /// event inside it has an identifier too. Both must match. Returning `nil`
    /// tells the disk queue to remove this payload; returning `Data` replaces it
    /// with the freshly sanitized and consistently encoded version.
    private static func reconciledPayload(
        _ payload: Data,
        expectedIdentifier: UUID,
        privacyFilter: TelemetryPrivacyFilter,
        enabledCategories: Set<TelemetryCategory>
    ) -> Data? {
        // Stored dates were written in the standard ISO-8601 text format, so the
        // decoder must use the matching rule while rebuilding `TelemetryEvent`.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // `guard` means every listed safety check must pass. `try?` converts a
        // decoding error into `nil`; malformed stored bytes are discarded rather
        // than crashing startup. The repeated `let event` first decodes the event
        // and later replaces it with the sanitized copy returned by the filter.
        guard let event = try? decoder.decode(TelemetryEvent.self, from: payload),
            event.id == expectedIdentifier,
            enabledCategories.contains(event.category),
            let event = privacyFilter.sanitize(event)
        else {
            // Any malformed, mismatched, disabled, or privacy-invalid payload is
            // unsafe to keep.
            return nil
        }

        // Re-encode the cleaned event using the same stable wire representation.
        // Sorted keys are useful for predictable output and reproducible tests;
        // JSON object key order does not change the event's meaning.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]

        // Encoding is expected to succeed because `TelemetryEvent` is Encodable.
        // If it unexpectedly fails, `try?` returns `nil`, which fails closed and
        // causes this stored payload to be removed.
        return try? encoder.encode(event)
    }

    /// Checks and accepts one already-created ``TelemetryEvent``.
    ///
    /// This method is synchronous: it gives the caller an immediate local answer
    /// and does not wait for a disk write or internet request. Picture handing a
    /// letter to the post-office front desk. ``TelemetryCaptureResult/accepted``
    /// means the clerk accepted the letter into the waiting area; it does **not**
    /// mean the remote recipient has received it.
    ///
    /// `@discardableResult` means callers may ignore the returned result without a
    /// compiler warning. Careful applications should inspect it when drops matter.
    @discardableResult
    public func capture(_ event: TelemetryEvent) -> TelemetryCaptureResult {
        // The ingress gate checks consent, category availability, queue state, and
        // whether this client has stopped. If allowed, it returns a revision—a
        // small version number proving which admission state approved this work.
        let admissionRevision: UInt64
        switch ingress.beginCapture(category: event.category) {
        case .allowed(let revision):
            admissionRevision = revision
        case .rejected(let rejection):
            // Examples include consentRequired, collectionDisabled, queueFull, or
            // clientStopped. No privacy filtering or JSON work is needed after a
            // rejection, so return immediately.
            return rejection
        }

        // Reserve one bounded in-progress capture slot. `guard ... else` exits
        // early if all slots are busy instead of allowing memory use to grow with
        // an unlimited number of simultaneous encoders.
        guard captureAdmissionPool.tryAcquire() else { return .queueFull }

        // `defer` runs whenever this function exits—successfully or early—so the
        // reserved slot is never accidentally leaked.
        defer { captureAdmissionPool.release() }

        // Apply privacy and validity rules before serialization. `sanitize` may
        // return a cleaned copy or `nil` when the whole event must be rejected.
        guard let event = privacyFilter.sanitize(event) else {
            return .invalidEvent
        }

        // Turn the strongly typed Swift value into JSON bytes for storage and
        // delivery. The server contract uses ISO-8601 dates and stable key order.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let payload = try? encoder.encode(event) else {
            // A caller receives a safe result value instead of an encoding crash.
            return .invalidEvent
        }

        // Check the size *after* encoding because the queue and network store the
        // JSON bytes, not Swift's in-memory representation.
        guard payload.count <= configuration.queueLimits.maximumEventBytes else {
            return .eventTooLarge
        }

        // Bundle the bytes with the small amount of metadata the internal queue
        // needs. `createdAt` records admission time for expiry and queue behavior;
        // the event itself also carries its own event timestamp.
        let pending = PendingEvent(
            id: event.id,
            createdAt: Date(),
            category: event.category,
            payload: payload
        )

        // Offer the prepared event using the revision captured before encoding.
        // If consent or lifecycle state changed during that time, ingress can see
        // the stale revision and reject the event instead of slipping it through.
        let result = ingress.offer(pending, admissionRevision: admissionRevision)
        if result == .accepted {
            // Wake the asynchronous runtime. `yield` only signals that work exists;
            // the actual event bytes remain in the bounded ingress buffer.
            signalContinuation.yield(())
        }

        // Give the caller the exact immediate admission decision.
        return result
    }

    /// A shorter way to create and capture the most common kind of event.
    ///
    /// Instead of building a ``TelemetryEvent`` manually, an app can provide its
    /// name and optional typed attributes. Defaults make a simple call such as
    /// `client.capture("screen.opened")` a custom, informational event.
    @discardableResult
    public func capture(
        _ name: String,
        attributes: [String: TelemetryValue] = [:],
        category: TelemetryCategory = .custom,
        level: TelemetryLevel = .info
    ) -> TelemetryCaptureResult {
        // Construct the full event, then send it through the exact same privacy,
        // capacity, encoding, and admission path above. There is intentionally no
        // "easy path" that bypasses safety checks.
        capture(
            TelemetryEvent(
                name: name,
                level: level,
                category: category,
                attributes: attributes
            )
        )
    }

    /// Asks the runtime to deliver work accepted before this call began.
    ///
    /// A "watermark" is like drawing a line in a queue: flush waits for the items
    /// in front of that line. Events captured concurrently after the line may stay
    /// queued for a later delivery cycle.
    ///
    /// Cancelling the calling task cancels this wait cooperatively. It does not
    /// pretend queued events were delivered, delete them, or make the client
    /// unusable. The method throws for invalid timeouts and delivery/runtime errors.
    @discardableResult
    public func flush(timeout: TimeInterval? = nil) async throws -> TelemetryFlushReport {
        // `??` means "use the value on the left when it exists; otherwise use the
        // configured default on the right."
        let timeout = timeout ?? configuration.flushTimeout

        // Reject NaN, infinity, zero/negative time, and values beyond the explicit
        // 24-hour safety ceiling before converting seconds to an integer duration.
        guard timeout.isFinite, timeout > 0, timeout <= Self.maximumFlushTimeout else {
            throw TelemetryError.invalidConfiguration(
                "The flush timeout must be finite, positive, and no longer than 24 hours."
            )
        }

        // Swift task clocks use nanoseconds here. One second has one billion
        // nanoseconds. Rounding produces the nearest whole nanosecond.
        let nanoseconds = UInt64((timeout * 1_000_000_000).rounded())

        // The coordinator owns the timeout/cancellation race and asks the runtime
        // for a final report containing uploaded, dropped, and remaining counts.
        return try await FlushOperationCoordinator().run(
            runtime: runtime,
            timeoutNanoseconds: nanoseconds
        )
    }

    /// Changes whether this client is currently permitted to collect telemetry.
    ///
    /// Ordering is deliberately different in each direction:
    ///
    /// - When granting consent, the asynchronous runtime becomes ready first;
    ///   only then does the synchronous capture entrance open.
    /// - When revoking consent, the synchronous entrance closes first; only then
    ///   does the runtime cancel delivery and purge memory and disk.
    ///
    /// This ordering prevents an event from sneaking through during the transition.
    public func setConsent(_ consent: TelemetryConsent) async throws {
        // Wait for exclusive lifecycle access so consent, erase, and shutdown do
        // not interleave their sensitive steps.
        try await lifecycleGate.acquire()
        do {
            // Respect cancellation before changing any state.
            try Task.checkCancellation()
            if consent == .granted {
                // Prepare actor-owned state first. If this throws, synchronous
                // capture has not been opened yet.
                try await runtime.setConsent(consent)
                // Now open the fast capture entrance.
                ingress.updateConsent(consent)
                // Begin explicitly enabled automatic signals only after permission.
                startConfiguredInstrumentation()
                // Wake the runtime in case permitted work is ready.
                signalContinuation.yield(())
            } else {
                // Close admission immediately before any awaited operation gives
                // another task a chance to run.
                ingress.updateConsent(consent)
                // Stop automatic event producers before purging their data.
                stopConfiguredInstrumentation()
                // The runtime cancels active delivery and removes queued data. A
                // thrown error tells the app not to assume disk deletion succeeded.
                try await runtime.setConsent(consent)
            }
            // Always let the next lifecycle operation proceed after success.
            await lifecycleGate.release()
        } catch {
            // Also release the gate after cancellation or failure, then preserve
            // the exact original error for the caller.
            await lifecycleGate.release()
            throw error
        }
    }

    /// Deletes queued telemetry without changing the configured consent state.
    ///
    /// Use this for a deliberate local "erase diagnostics" action. It cannot
    /// recall an event that a server has already accepted.
    public func eraseStoredData() async throws {
        try await lifecycleGate.acquire()
        do {
            try Task.checkCancellation()
            // Clear the synchronous waiting room first so its events cannot be
            // moved to disk while the disk purge is happening.
            ingress.erase()
            // Clear actor-owned memory and persistent queue contents.
            try await runtime.eraseStoredData()
            // Wake the worker so it observes the new empty state promptly.
            signalContinuation.yield(())
            await lifecycleGate.release()
        } catch {
            await lifecycleGate.release()
            throw error
        }
    }

    /// Returns queue totals without exposing private event contents.
    ///
    /// Because other tasks may capture or upload at the same time, this is a
    /// moment-in-time photograph rather than a permanent promise.
    public func queueStatus() async -> TelemetryQueueStatus {
        await runtime.status()
    }

    /// Permanently stops this client instance and optionally tries one last flush.
    ///
    /// Shutdown is terminal: this object never accepts events again. Create a new
    /// client if collection must restart. The final flush is best effort and does
    /// not throw; call ``flush(timeout:)`` first when its exact result matters.
    public func shutdown(flush: Bool = true) async {
        // Close all event-producing entrances synchronously before awaiting work.
        markTerminal()
        stopConfiguredInstrumentation()
        ingress.stopAccepting()
        signalContinuation.finish()

        // Only one task should perform shutdown. If another task already owns or
        // completed the terminal transition, there is nothing more to do here.
        guard await lifecycleGate.acquireForShutdown() else { return }
        if flush {
            // `try?` deliberately turns a timeout or delivery failure into nil:
            // shutdown promises not to throw and the flush is documented as best
            // effort. Callers needing the report should flush explicitly first.
            _ = try? await self.flush(timeout: configuration.shutdownFlushTimeout)
        }
        // Stop worker tasks and cancel any remaining transport work.
        await runtime.shutdown()
        // Release exclusive ownership of the queue directory last, after nothing
        // in this client can still write to it.
        storageLease.release()
        await lifecycleGate.release()
    }

    /// Creates a `URLSession` that records network timing and size metrics.
    ///
    /// TelemetryKit observes only requests made through the returned session. It
    /// does not secretly replace methods ("swizzle") or inspect unrelated sessions.
    public func makeInstrumentedURLSession(
        configuration: URLSessionConfiguration = .default,
        delegateQueue: OperationQueue? = nil
    ) -> URLSession {
        // The instrumentation helper owns the delegate wiring. Passing `self`
        // gives it the safe capture and URL-sanitization paths it needs.
        TelemetryNetworkInstrumentation.makeSession(
            configuration: configuration,
            client: self,
            delegateQueue: delegateQueue
        )
    }

    /// Starts a timer-like span for one named piece of application work.
    ///
    /// A span might measure `catalog.decode` or `database.migration`. "End-once"
    /// means calling `end` repeatedly records only the first ending.
    public func startSpan(
        _ operation: String,
        attributes: [String: TelemetryValue] = [:]
    ) -> TelemetrySpan {
        // Clean the name and starting attributes before the span stores them.
        let sanitized = privacyFilter.sanitizeSpan(
            operation: operation,
            attributes: attributes
        )
        return TelemetrySpan(
            operation: sanitized.operation,
            attributes: sanitized.attributes,
            // The span keeps only a weak client relationship internally so it can
            // submit its final event without owning this client forever.
            client: self
        )
    }

    // Internal adapters use these narrow helpers instead of receiving the whole
    // privacy filter. That keeps one authoritative privacy policy on the client.
    internal func sanitizedNetworkURLAttributes(_ url: URL?) -> [String: TelemetryValue] {
        privacyFilter.sanitizedURLAttributes(url)
    }

    internal func sanitizedSpanEndAttributes(
        _ attributes: [String: TelemetryValue]
    ) -> [String: TelemetryValue] {
        privacyFilter.sanitizeSpan(operation: "", attributes: attributes).attributes
    }

    /// Starts every automatic instrumentation adapter enabled in configuration.
    /// Calling this repeatedly is safe; the lock-protected checks allow one start.
    private func startConfiguredInstrumentation() {
        // Tests or special internal startup paths may prohibit instrumentation.
        guard instrumentationAllowed else { return }

        // Build adapters in a local array first. This avoids publishing a partially
        // constructed list to other threads.
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
            // MetricKit exists only on supported Apple SDKs. Conditional
            // compilation keeps TelemetryKit buildable where the module is absent.
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

        // From this line until `unlock`, only one thread may read or mutate the
        // instrumentation lifecycle state.
        instrumentationLock.lock()
        guard !isTerminal, !instrumentationIsStarted else {
            // A failed guard must unlock manually before returning.
            instrumentationLock.unlock()
            return
        }
        instrumentationIsStarted = true
        instrumentation = lifecycles
        // Start while holding the lock so a concurrent stop cannot remove an
        // adapter between publishing and starting it.
        for lifecycle in lifecycles {
            lifecycle.start()
        }
        instrumentationLock.unlock()
    }

    /// Stops and forgets all currently running automatic instrumentation.
    private func stopConfiguredInstrumentation() {
        instrumentationLock.lock()
        guard instrumentationIsStarted else {
            instrumentationLock.unlock()
            return
        }
        instrumentationIsStarted = false
        // Copy the adapters before clearing the stored collection so each copied
        // adapter can still receive exactly one stop call.
        let lifecycles = instrumentation
        instrumentation.removeAll()
        for lifecycle in lifecycles {
            lifecycle.stop()
        }
        instrumentationLock.unlock()
    }

    /// Records the irreversible fact that this client is shutting down.
    private func markTerminal() {
        instrumentationLock.lock()
        isTerminal = true
        instrumentationLock.unlock()
    }
}

// This helper belongs to configuration conceptually, but it is kept in this file
// because only client startup needs to turn storage settings into a concrete path.
extension TelemetryConfiguration {
    /// Returns the exact directory used by this client's persistent event queue.
    fileprivate func resolvedStorageDirectory() throws -> URL {
        if let storageDirectory {
            // Normalize `.` / `..` components and follow symbolic links so the
            // safety check examines the real destination rather than its spelling.
            let resolved = storageDirectory.standardizedFileURL.resolvingSymlinksInPath()
            // Never allow the queue to own the filesystem root. Cleanup code for a
            // queue must always operate inside a narrow, dedicated directory.
            guard resolved.path != "/" else {
                throw TelemetryError.invalidConfiguration(
                    "The storage directory cannot resolve to the filesystem root."
                )
            }
            return resolved
        }

        // No custom directory was supplied, so ask Foundation for this user's
        // standard Application Support folder.
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

        // Separate queues by endpoint and the app-provided namespace. The endpoint
        // becomes a stable non-secret folder key rather than a URL-shaped path.
        let endpointKey = Self.stableEndpointKey(endpoint.absoluteString)
        return
            applicationSupport
            .appendingPathComponent("TelemetryKit", isDirectory: true)
            .appendingPathComponent(endpointKey, isDirectory: true)
            .appendingPathComponent(storageNamespace, isDirectory: true)
    }

    /// Produces the same short hexadecimal folder key for the same endpoint text.
    ///
    /// This is the 64-bit FNV-1a algorithm. It is a stable naming hash, not
    /// encryption and not a password-security function. Its job is simply to keep
    /// URLs out of folder names while deterministically separating endpoints.
    private static func stableEndpointKey(_ value: String) -> String {
        // FNV-1a's defined 64-bit starting value (the "offset basis").
        var hash: UInt64 = 14_695_981_039_346_656_037
        // Hash UTF-8 bytes so the result is stable for the endpoint's text.
        for byte in value.utf8 {
            // Mix this byte into the current value with exclusive OR.
            hash ^= UInt64(byte)
            // Multiply with overflow intentionally wrapping at 64 bits. `&*` is
            // Swift's explicit wrapping-multiplication operator.
            hash &*= 1_099_511_628_211
        }
        // Use base 16 (hexadecimal) to create a compact filesystem-safe string.
        return String(hash, radix: 16)
    }
}
