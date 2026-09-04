import Foundation

/// A small FIFO async mutex used only for lifecycle mutations. Capture and
/// delivery stay on their separate fast paths.
internal actor TelemetryOperationGate {
    private var isOwned = false
    private var isClosed = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var waiterOrder: [UUID] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []
    private let maximumWaiters = 64

    internal func acquire() async throws {
        try Task.checkCancellation()
        guard !isClosed else { throw TelemetryError.clientStopped }
        if !isOwned {
            isOwned = true
            do {
                try Task.checkCancellation()
            } catch {
                isOwned = false
                throw error
            }
            return
        }

        guard waiters.count < maximumWaiters else {
            throw TelemetryError.operationRejected(
                "Too many concurrent lifecycle operations."
            )
        }
        let identifier = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[identifier] = continuation
                waiterOrder.append(identifier)
            }
        } onCancel: {
            Task { await self.cancelWaiter(identifier) }
        }
        do {
            try Task.checkCancellation()
        } catch {
            release()
            throw error
        }
    }

    /// Closes the gate to new lifecycle mutations and waits for the current
    /// owner without observing caller cancellation. Terminal cleanup must not
    /// race queue ownership or release its storage lease early.
    internal func acquireForShutdown() async -> Bool {
        if !isClosed {
            isClosed = true
            for continuation in waiters.values {
                continuation.resume(throwing: TelemetryError.clientStopped)
            }
            waiters.removeAll()
            waiterOrder.removeAll()
        }
        if !isOwned {
            isOwned = true
            return true
        }
        guard shutdownWaiters.count < maximumWaiters else { return false }
        await withCheckedContinuation { continuation in
            shutdownWaiters.append(continuation)
        }
        return true
    }

    internal func release() {
        if !shutdownWaiters.isEmpty {
            shutdownWaiters.removeFirst().resume()
            return
        }
        while let identifier = waiterOrder.first {
            waiterOrder.removeFirst()
            if let continuation = waiters.removeValue(forKey: identifier) {
                continuation.resume()
                return
            }
        }
        isOwned = false
    }

    private func cancelWaiter(_ identifier: UUID) {
        guard let continuation = waiters.removeValue(forKey: identifier) else {
            return
        }
        waiterOrder.removeAll { $0 == identifier }
        continuation.resume(throwing: CancellationError())
    }
}
