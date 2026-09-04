import Foundation

/// Races one runtime flush against a real-time deadline without making the
/// caller wait for a cancelled child task to unwind from URLSession.
internal final class FlushOperationCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<TelemetryFlushReport, Error>?
    private var flushTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var isResolved = false

    internal func run(
        runtime: TelemetryRuntime,
        timeoutNanoseconds: UInt64
    ) async throws -> TelemetryFlushReport {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                start(
                    continuation: continuation,
                    runtime: runtime,
                    timeoutNanoseconds: timeoutNanoseconds
                )
            }
        } onCancel: {
            self.resolve(.failure(CancellationError()))
        }
    }

    private func start(
        continuation: CheckedContinuation<TelemetryFlushReport, Error>,
        runtime: TelemetryRuntime,
        timeoutNanoseconds: UInt64
    ) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        flushTask = Task {
            do {
                self.resolve(.success(try await runtime.flush()))
            } catch {
                self.resolve(.failure(error))
            }
        }
        timeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                self.resolve(.failure(TelemetryError.flushTimedOut))
            } catch {
                // The flush won the race and cancelled this timer.
            }
        }
        lock.unlock()
    }

    private func resolve(_ result: Result<TelemetryFlushReport, Error>) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        let continuation = continuation
        self.continuation = nil
        let flushTask = flushTask
        let timeoutTask = timeoutTask
        self.flushTask = nil
        self.timeoutTask = nil
        lock.unlock()

        flushTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}
