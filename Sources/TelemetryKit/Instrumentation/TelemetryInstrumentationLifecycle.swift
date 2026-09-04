import Foundation

internal protocol TelemetryInstrumentationLifecycle: AnyObject, Sendable {
    func start()
    func stop()
}
