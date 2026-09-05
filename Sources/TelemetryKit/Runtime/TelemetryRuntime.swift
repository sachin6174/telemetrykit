import Foundation

internal actor TelemetryRuntime {
    private struct DeliveryStatistics: Sendable {
        var uploaded = 0
        var permanentlyDropped = 0
    }

    private let configuration: TelemetryConfiguration
    private let ingress: IngressBuffer
    private let queue: DiskEventQueue
    private let transport: TelemetryTransport
    private let clock: TelemetryRuntimeClock
    private let randomSource: TelemetryRandomSource
    private let diagnostics: TelemetryDiagnostics
    private let privacyFilter: TelemetryPrivacyFilter
    private let enabledCategories: Set<TelemetryCategory>

    private var signalTask: Task<Void, Never>?
    private var intervalTask: Task<Void, Never>?
    private var signalStream: AsyncStream<Void>?
    private var backgroundWorkersEnabled = false
    private var isStopped = false
    private var isShuttingDown = false
    private var deliveryOwner = false
    private var deliveryWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var deliveryWaiterOrder: [UUID] = []
    private var persistenceOwner = false
    private var persistenceWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var persistenceWaiterOrder: [UUID] = []
    private var deliveryBlockedReason: String?
    private var purgeRequired = false
    private var dataRevision: UInt64 = 0
    private var consent: TelemetryConsent

    private let maximumCoordinationWaiters = 64

    internal init(
        configuration: TelemetryConfiguration,
        ingress: IngressBuffer,
        queue: DiskEventQueue,
        transport: TelemetryTransport,
        clock: TelemetryRuntimeClock = SystemTelemetryClock(),
        randomSource: TelemetryRandomSource = SystemTelemetryRandomSource(),
        diagnostics: TelemetryDiagnostics = TelemetryDiagnostics()
    ) {
        self.configuration = configuration
        self.ingress = ingress
        self.queue = queue
        self.transport = transport
        self.clock = clock
        self.randomSource = randomSource
        self.diagnostics = diagnostics
        self.privacyFilter = TelemetryPrivacyFilter(
            configuration: configuration.privacy,
            maximumOutputBytes: configuration.queueLimits.maximumEventBytes
        )
        self.enabledCategories = configuration.effectiveEnabledCategories
        self.consent = configuration.consent
    }

    internal func start(signalStream: AsyncStream<Void>) {
        guard !isStopped else { return }
        self.signalStream = signalStream
        backgroundWorkersEnabled = true
        startBackgroundWorkersIfNeeded()
    }

    private func startBackgroundWorkersIfNeeded() {
        guard backgroundWorkersEnabled,
            !isStopped,
            consent == .granted,
            !purgeRequired,
            signalTask == nil,
            let signalStream
        else {
            return
        }

        signalTask = Task { [weak self] in
            for await _ in signalStream {
                guard !Task.isCancelled else { break }
                guard let self else { break }
                await self.processSignal()
            }
        }

        let flushInterval = configuration.flushInterval
        intervalTask = Task { [weak self, clock] in
            while !Task.isCancelled {
                do {
                    try await clock.sleep(for: flushInterval)
                } catch {
                    break
                }
                guard !Task.isCancelled else { break }
                guard let self else { break }
                await self.processInterval()
            }
        }
    }

    internal func flush() async throws -> TelemetryFlushReport {
        guard !isStopped, !isShuttingDown else { throw TelemetryError.clientStopped }
        guard !purgeRequired else {
            throw TelemetryError.storageUnavailable(
                "A previously requested queue purge has not completed."
            )
        }
        try Task.checkCancellation()
        try await persistIngress()
        guard let watermark = await queue.latestSequence() else {
            let status = await aggregateQueueStatus()
            return TelemetryFlushReport(
                uploadedEventCount: 0,
                permanentlyDroppedEventCount: 0,
                remainingEventCount: status.eventCount
            )
        }

        try await acquireDelivery()
        defer { releaseDelivery() }
        try Task.checkCancellation()

        let statistics = try await deliver(upTo: watermark, explicit: true)
        let status = await aggregateQueueStatus()
        return TelemetryFlushReport(
            uploadedEventCount: statistics.uploaded,
            permanentlyDroppedEventCount: statistics.permanentlyDropped,
            remainingEventCount: status.eventCount
        )
    }

    internal func setConsent(_ consent: TelemetryConsent) async throws {
        guard !isStopped, !isShuttingDown else { throw TelemetryError.clientStopped }
        if consent == .granted {
            try Task.checkCancellation()
            if purgeRequired {
                try await performRequiredPurge()
            }
            try Task.checkCancellation()
            self.consent = .granted
            transport.resumeUploads()
            deliveryBlockedReason = nil
            startBackgroundWorkersIfNeeded()
            return
        }

        dataRevision &+= 1
        purgeRequired = true
        self.consent = consent
        signalTask?.cancel()
        intervalTask?.cancel()
        signalTask = nil
        intervalTask = nil
        transport.cancelOutstanding()
        try await performRequiredPurge()
    }

    internal func eraseStoredData() async throws {
        guard !isStopped, !isShuttingDown else { throw TelemetryError.clientStopped }
        dataRevision &+= 1
        transport.cancelOutstanding()
        purgeRequired = true
        try await performRequiredPurge()
        if consent == .granted {
            transport.resumeUploads()
        }
    }

    internal func status() async -> TelemetryQueueStatus {
        var acquiredPersistence = false
        do {
            try await acquirePersistence()
            acquiredPersistence = true
        } catch {
            // A status snapshot is nonthrowing and may be approximate under extreme contention.
        }
        defer {
            if acquiredPersistence {
                releasePersistence()
            }
        }
        return await aggregateQueueStatus()
    }

    internal func shutdown() async {
        guard !isStopped, !isShuttingDown else { return }
        isShuttingDown = true
        try? await persistIngress()
        isStopped = true
        dataRevision &+= 1
        signalTask?.cancel()
        intervalTask?.cancel()
        signalTask = nil
        intervalTask = nil
        signalStream = nil
        backgroundWorkersEnabled = false
        transport.cancelAll()

        cancelQueuedCoordinators()
        do {
            try await acquirePersistence()
            releasePersistence()
        } catch {
            // Shutdown is best effort and remains nonthrowing.
        }
        do {
            try await acquireDelivery()
            releaseDelivery()
        } catch {
            // Shutdown is best effort and remains nonthrowing.
        }
    }

    private func cancelQueuedCoordinators() {
        for continuation in deliveryWaiters.values {
            continuation.resume(throwing: TelemetryError.clientStopped)
        }
        deliveryWaiters.removeAll()
        deliveryWaiterOrder.removeAll()
        for continuation in persistenceWaiters.values {
            continuation.resume(throwing: TelemetryError.clientStopped)
        }
        persistenceWaiters.removeAll()
        persistenceWaiterOrder.removeAll()
    }

    private func processSignal() async {
        guard !isStopped else { return }
        do {
            try await persistIngress()
            let status = await queue.status()
            if status.eventCount >= configuration.batchSize
                || status.byteCount >= configuration.batchByteLimit
            {
                try await runAutomaticDelivery()
            }
        } catch {
            diagnostics.deliveryPaused(reasonCode: 1)
        }
    }

    private func processInterval() async {
        guard !isStopped else { return }
        do {
            try await persistIngress()
            try await runAutomaticDelivery()
        } catch {
            diagnostics.deliveryPaused(reasonCode: 2)
        }
    }

    private func runAutomaticDelivery() async throws {
        guard !purgeRequired,
            consent == .granted,
            deliveryBlockedReason == nil
        else {
            return
        }
        guard let watermark = await queue.latestSequence() else { return }

        try await acquireDelivery()
        defer { releaseDelivery() }
        _ = try await deliver(upTo: watermark, explicit: false)
    }

    private func persistIngress() async throws {
        guard !purgeRequired else { return }
        try await acquirePersistence()
        defer { releasePersistence() }

        let persistenceRevision = dataRevision
        let snapshot = ingress.drain()
        guard !snapshot.events.isEmpty else { return }

        guard consent == .granted else {
            return
        }

        for index in snapshot.events.indices {
            guard !isStopped else {
                ingress.restore(Array(snapshot.events[index...]))
                return
            }
            guard persistenceRevision == dataRevision else { return }
            guard consent == .granted else { return }
            guard persistenceRevision == dataRevision else { return }
            let event = snapshot.events[index]
            do {
                let result = try await queue.enqueue(
                    payload: event.payload,
                    id: event.id,
                    createdAt: event.createdAt
                )
                switch result {
                case .accepted:
                    break
                case .acceptedAfterDroppingOldest(let count):
                    for _ in 0..<count {
                        diagnostics.queueDroppedEvent(reasonCode: 1)
                    }
                case .rejectedFull:
                    diagnostics.queueDroppedEvent(reasonCode: 2)
                case .rejectedOversized:
                    diagnostics.queueDroppedEvent(reasonCode: 3)
                }
                guard persistenceRevision == dataRevision else { return }
            } catch {
                if persistenceRevision == dataRevision {
                    ingress.restore(Array(snapshot.events[index...]))
                }
                throw TelemetryError.storageUnavailable(error.localizedDescription)
            }
        }
    }

    private func deliver(
        upTo watermark: UInt64,
        explicit: Bool
    ) async throws -> DeliveryStatistics {
        var statistics = DeliveryStatistics()
        var preferredBatchCount = configuration.batchSize
        let deliveryRevision = dataRevision

        while !isStopped {
            try Task.checkCancellation()
            guard !purgeRequired else { break }
            guard deliveryRevision == dataRevision else { break }
            guard consent == .granted else { break }
            if let deliveryBlockedReason {
                if explicit {
                    throw TelemetryError.transportFailed(deliveryBlockedReason)
                }
                break
            }

            var envelopes = try await peekQueuedEvents(
                maxCount: preferredBatchCount,
                maxBytes: configuration.batchByteLimit,
                now: clock.now()
            )
            envelopes = envelopes.filter { $0.sequence <= watermark }
            guard !envelopes.isEmpty else { break }

            let decoded = decode(envelopes)
            if !decoded.invalidIdentifiers.isEmpty {
                try await removeQueuedEvents(ids: decoded.invalidIdentifiers)
                statistics.permanentlyDropped += decoded.invalidIdentifiers.count
                continue
            }
            guard !decoded.events.isEmpty else { break }

            var selectedEnvelopes = envelopes
            var selectedEvents = decoded.events
            var body = try encodeBatch(selectedEvents)
            while body.count > configuration.batchByteLimit, selectedEvents.count > 1 {
                selectedEvents.removeLast()
                selectedEnvelopes.removeLast()
                body = try encodeBatch(selectedEvents)
            }
            if body.count > configuration.batchByteLimit {
                try await removeQueuedEvents(ids: [selectedEnvelopes[0].id])
                statistics.permanentlyDropped += 1
                diagnostics.queueDroppedEvent(reasonCode: 4)
                continue
            }

            var retryAttempt = 0
            var shouldSelectAnotherBatch = false
            while !shouldSelectAnotherBatch {
                try Task.checkCancellation()
                guard deliveryRevision == dataRevision else {
                    return statistics
                }
                guard consent == .granted else {
                    return statistics
                }
                guard deliveryRevision == dataRevision else {
                    return statistics
                }

                let signpost = diagnostics.uploadBegan(eventCount: selectedEvents.count)
                let response: TelemetryTransportResponse
                do {
                    response = try await transport.upload(body: body)
                    diagnostics.uploadEnded(signpost, statusCode: response.statusCode)
                } catch is CancellationError {
                    diagnostics.uploadEnded(signpost, statusCode: nil)
                    throw CancellationError()
                } catch let telemetryError as TelemetryError {
                    diagnostics.uploadEnded(signpost, statusCode: nil)
                    throw telemetryError
                } catch {
                    diagnostics.uploadEnded(signpost, statusCode: nil)
                    switch ResponseClassifier.classify(error: error) {
                    case .cancelled:
                        throw CancellationError()
                    case .configurationBlocked:
                        deliveryBlockedReason = "Transport configuration prevents delivery."
                        if explicit {
                            throw TelemetryError.transportFailed(deliveryBlockedReason!)
                        }
                        return statistics
                    case .retry:
                        guard
                            let delay = await retryDelay(
                                attempt: retryAttempt,
                                retryAfter: nil
                            )
                        else {
                            if explicit {
                                throw TelemetryError.transportFailed(
                                    "The bounded retry cycle was exhausted."
                                )
                            }
                            return statistics
                        }
                        retryAttempt += 1
                        try await clock.sleep(for: delay)
                        guard deliveryRevision == dataRevision else {
                            return statistics
                        }
                        continue
                    }
                }

                guard deliveryRevision == dataRevision else {
                    return statistics
                }
                guard consent == .granted else {
                    return statistics
                }
                guard deliveryRevision == dataRevision else {
                    return statistics
                }
                let disposition = ResponseClassifier.classify(
                    statusCode: response.statusCode,
                    headers: response.headers,
                    now: clock.now()
                )

                switch disposition {
                case .delivered:
                    try await removeQueuedEvents(ids: selectedEnvelopes.map(\.id))
                    statistics.uploaded += selectedEnvelopes.count
                    preferredBatchCount = configuration.batchSize
                    shouldSelectAnotherBatch = true
                case .discard:
                    try await removeQueuedEvents(ids: selectedEnvelopes.map(\.id))
                    statistics.permanentlyDropped += selectedEnvelopes.count
                    preferredBatchCount = configuration.batchSize
                    shouldSelectAnotherBatch = true
                case .authenticationBlocked:
                    deliveryBlockedReason = "The ingestion endpoint rejected authentication."
                    diagnostics.deliveryPaused(reasonCode: 3)
                    if explicit {
                        throw TelemetryError.transportFailed(deliveryBlockedReason!)
                    }
                    return statistics
                case .splitBatch:
                    if selectedEnvelopes.count == 1 {
                        try await removeQueuedEvents(ids: [selectedEnvelopes[0].id])
                        statistics.permanentlyDropped += 1
                        diagnostics.queueDroppedEvent(reasonCode: 5)
                    } else {
                        preferredBatchCount = max(1, selectedEnvelopes.count / 2)
                    }
                    shouldSelectAnotherBatch = true
                case .retry(let retryAfter):
                    guard
                        let delay = await retryDelay(
                            attempt: retryAttempt,
                            retryAfter: retryAfter
                        )
                    else {
                        if explicit {
                            throw TelemetryError.transportFailed(
                                "The bounded retry cycle was exhausted."
                            )
                        }
                        return statistics
                    }
                    retryAttempt += 1
                    try await clock.sleep(for: delay)
                    guard deliveryRevision == dataRevision else {
                        return statistics
                    }
                }
            }
        }

        return statistics
    }

    private func decode(
        _ envelopes: [StoredEnvelope]
    ) -> (events: [TelemetryEvent], invalidIdentifiers: [UUID]) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events: [TelemetryEvent] = []
        var invalidIdentifiers: [UUID] = []
        events.reserveCapacity(envelopes.count)

        for envelope in envelopes {
            guard let event = try? decoder.decode(TelemetryEvent.self, from: envelope.payload),
                event.id == envelope.id,
                enabledCategories.contains(event.category),
                let sanitized = privacyFilter.sanitize(event)
            else {
                invalidIdentifiers.append(envelope.id)
                continue
            }
            events.append(sanitized)
        }
        return (events, invalidIdentifiers)
    }

    private func encodeBatch(_ events: [TelemetryEvent]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(TelemetryUploadBatch(events: events, sentAt: clock.now()))
        } catch {
            throw TelemetryError.encodingFailed
        }
    }

    private func retryDelay(attempt: Int, retryAfter: Date?) async -> TimeInterval? {
        let randomUnit = await randomSource.nextUnit()
        return RetryDelayCalculator(policy: configuration.retryPolicy).delay(
            attempt: attempt,
            randomUnit: randomUnit,
            retryAfter: retryAfter,
            now: clock.now()
        )
    }

    private func aggregateQueueStatus() async -> TelemetryQueueStatus {
        let disk = await queue.status()
        let memory = ingress.status()
        return TelemetryQueueStatus(
            eventCount: disk.eventCount + memory.eventCount,
            byteCount: disk.byteCount + memory.byteCount,
            oldestEventDate: [disk.oldestEventDate, memory.oldestDate]
                .compactMap { $0 }
                .min()
        )
    }

    private func peekQueuedEvents(
        maxCount: Int,
        maxBytes: Int,
        now: Date
    ) async throws -> [StoredEnvelope] {
        do {
            return try await queue.peekBatch(
                maxCount: maxCount,
                maxBytes: maxBytes,
                now: now
            )
        } catch {
            throw TelemetryError.storageUnavailable(error.localizedDescription)
        }
    }

    private func removeQueuedEvents(ids: [UUID]) async throws {
        do {
            try await queue.remove(ids: ids)
        } catch {
            throw TelemetryError.storageUnavailable(error.localizedDescription)
        }
    }

    private func removeAllQueuedEvents() async throws {
        do {
            try await queue.removeAll()
        } catch {
            throw TelemetryError.storageUnavailable(error.localizedDescription)
        }
    }

    private func performRequiredPurge() async throws {
        try await acquirePersistence()
        do {
            try await removeAllQueuedEvents()
            purgeRequired = false
            releasePersistence()
        } catch {
            releasePersistence()
            throw error
        }
    }

    private func acquireDelivery() async throws {
        if !deliveryOwner {
            deliveryOwner = true
            return
        }

        let identifier = UUID()
        guard deliveryWaiters.count < maximumCoordinationWaiters else {
            throw TelemetryError.transportFailed("Too many concurrent flush operations.")
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                deliveryWaiters[identifier] = continuation
                deliveryWaiterOrder.append(identifier)
            }
        } onCancel: {
            Task { await self.cancelDeliveryWaiter(identifier) }
        }
    }

    private func cancelDeliveryWaiter(_ identifier: UUID) {
        guard let continuation = deliveryWaiters.removeValue(forKey: identifier) else {
            return
        }
        deliveryWaiterOrder.removeAll { $0 == identifier }
        continuation.resume(throwing: CancellationError())
    }

    private func releaseDelivery() {
        while let identifier = deliveryWaiterOrder.first {
            deliveryWaiterOrder.removeFirst()
            if let continuation = deliveryWaiters.removeValue(forKey: identifier) {
                continuation.resume()
                return
            }
        }
        deliveryOwner = false
    }

    private func acquirePersistence() async throws {
        if !persistenceOwner {
            persistenceOwner = true
            return
        }

        let identifier = UUID()
        guard persistenceWaiters.count < maximumCoordinationWaiters else {
            throw TelemetryError.storageUnavailable(
                "Too many concurrent persistence operations."
            )
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                persistenceWaiters[identifier] = continuation
                persistenceWaiterOrder.append(identifier)
            }
        } onCancel: {
            Task { await self.cancelPersistenceWaiter(identifier) }
        }
    }

    private func cancelPersistenceWaiter(_ identifier: UUID) {
        guard let continuation = persistenceWaiters.removeValue(forKey: identifier) else {
            return
        }
        persistenceWaiterOrder.removeAll { $0 == identifier }
        continuation.resume(throwing: CancellationError())
    }

    private func releasePersistence() {
        while let identifier = persistenceWaiterOrder.first {
            persistenceWaiterOrder.removeFirst()
            if let continuation = persistenceWaiters.removeValue(forKey: identifier) {
                continuation.resume()
                return
            }
        }
        persistenceOwner = false
    }
}
