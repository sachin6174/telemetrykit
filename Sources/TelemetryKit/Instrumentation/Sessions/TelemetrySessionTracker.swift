import Foundation

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

internal final class TelemetrySessionTracker: TelemetryInstrumentationLifecycle,
    @unchecked Sendable
{
    private struct SessionState {
        var id: UUID
        var startedAt: UInt64
        var becameInactiveAt: UInt64?
    }

    private weak var client: TelemetryClient?
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var observerTokens: [NSObjectProtocol] = []
    private var state: SessionState?
    private var isStarted = false

    internal init(client: TelemetryClient, timeout: TimeInterval) {
        self.client = client
        self.timeout = timeout
    }

    internal func start() {
        lock.lock()
        guard !isStarted else {
            lock.unlock()
            return
        }
        isStarted = true
        state = SessionState(
            id: UUID(),
            startedAt: DispatchTime.now().uptimeNanoseconds,
            becameInactiveAt: nil
        )
        let sessionID = state?.id
        lock.unlock()

        if let sessionID {
            recordSessionStarted(identifier: sessionID)
        }
        registerForLifecycleNotifications()
    }

    internal func stop() {
        lock.lock()
        guard isStarted else {
            lock.unlock()
            return
        }
        isStarted = false
        let endedState = state
        state = nil
        let tokens = observerTokens
        observerTokens.removeAll()
        lock.unlock()

        for token in tokens {
            NotificationCenter.default.removeObserver(token)
        }
        if let endedState {
            recordSessionFinished(endedState, endedAt: DispatchTime.now().uptimeNanoseconds)
        }
    }

    private func registerForLifecycleNotifications() {
        #if canImport(UIKit)
            let inactiveName = Notification.Name("UIApplicationDidEnterBackgroundNotification")
            let activeName = Notification.Name("UIApplicationDidBecomeActiveNotification")
        #elseif canImport(AppKit)
            let inactiveName = Notification.Name("NSApplicationDidResignActiveNotification")
            let activeName = Notification.Name("NSApplicationDidBecomeActiveNotification")
        #else
            return
        #endif

        let center = NotificationCenter.default
        let inactive = center.addObserver(
            forName: inactiveName,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.applicationBecameInactive()
        }
        let active = center.addObserver(
            forName: activeName,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.applicationBecameActive()
        }

        lock.lock()
        if isStarted {
            observerTokens.append(contentsOf: [inactive, active])
            lock.unlock()
        } else {
            lock.unlock()
            center.removeObserver(inactive)
            center.removeObserver(active)
        }
    }

    private func applicationBecameInactive() {
        lock.lock()
        guard isStarted, state != nil else {
            lock.unlock()
            return
        }
        state?.becameInactiveAt = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
    }

    private func applicationBecameActive() {
        let now = DispatchTime.now().uptimeNanoseconds
        var finished: SessionState?
        var newIdentifier: UUID?

        lock.lock()
        guard isStarted else {
            lock.unlock()
            return
        }

        if let current = state, let inactiveAt = current.becameInactiveAt {
            let inactiveDuration = Self.seconds(from: inactiveAt, to: now)
            if inactiveDuration >= timeout {
                finished = current
                let identifier = UUID()
                state = SessionState(id: identifier, startedAt: now, becameInactiveAt: nil)
                newIdentifier = identifier
            } else {
                state?.becameInactiveAt = nil
            }
        } else if state == nil {
            let identifier = UUID()
            state = SessionState(id: identifier, startedAt: now, becameInactiveAt: nil)
            newIdentifier = identifier
        }
        lock.unlock()

        if let finished {
            recordSessionFinished(
                finished,
                endedAt: finished.becameInactiveAt ?? now
            )
        }
        if let newIdentifier {
            recordSessionStarted(identifier: newIdentifier)
        }
    }

    private func recordSessionStarted(identifier: UUID) {
        _ = client?.capture(
            "session.started",
            attributes: ["session_id": .string(identifier.uuidString.lowercased())],
            category: .session
        )
    }

    private func recordSessionFinished(_ session: SessionState, endedAt: UInt64) {
        _ = client?.capture(
            "session.finished",
            attributes: [
                "duration_ms": .double(Self.seconds(from: session.startedAt, to: endedAt) * 1_000),
                "session_id": .string(session.id.uuidString.lowercased()),
            ],
            category: .session
        )
    }

    private static func seconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        guard end >= start else { return 0 }
        return TimeInterval(end - start) / 1_000_000_000
    }
}
