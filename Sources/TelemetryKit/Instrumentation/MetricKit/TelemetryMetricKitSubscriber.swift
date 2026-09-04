#if canImport(MetricKit)
    import Foundation
    import MetricKit

    internal final class TelemetryMetricKitSubscriber: NSObject,
        TelemetryInstrumentationLifecycle,
        MXMetricManagerSubscriber,
        @unchecked Sendable
    {
        private weak var client: TelemetryClient?
        private let metricsEnabled: Bool
        private let diagnosticsEnabled: Bool
        private let maximumPayloadBytes: Int
        private let lock = NSLock()
        private var isStarted = false
        private var recentPayloadIdentifiers: [UUID] = []
        private var recentPayloadIdentifierSet: Set<UUID> = []
        private let maximumRememberedPayloads = 128

        internal init(
            client: TelemetryClient,
            metricsEnabled: Bool,
            diagnosticsEnabled: Bool,
            maximumPayloadBytes: Int
        ) {
            self.client = client
            self.metricsEnabled = metricsEnabled
            self.diagnosticsEnabled = diagnosticsEnabled
            self.maximumPayloadBytes = max(1, maximumPayloadBytes)
            super.init()
        }

        internal func start() {
            lock.lock()
            guard !isStarted else {
                lock.unlock()
                return
            }
            isStarted = true
            lock.unlock()
            MXMetricManager.shared.add(self)
        }

        internal func stop() {
            lock.lock()
            guard isStarted else {
                lock.unlock()
                return
            }
            isStarted = false
            recentPayloadIdentifiers.removeAll()
            recentPayloadIdentifierSet.removeAll()
            lock.unlock()
            MXMetricManager.shared.remove(self)
        }

        internal func didReceive(_ payloads: [MXMetricPayload]) {
            guard metricsEnabled else { return }
            for payload in payloads {
                capture(
                    data: payload.jsonRepresentation(),
                    name: "metrickit.metric",
                    category: .metricKitMetric
                )
            }
        }

        internal func didReceive(_ payloads: [MXDiagnosticPayload]) {
            guard diagnosticsEnabled else { return }
            for payload in payloads {
                capture(
                    data: payload.jsonRepresentation(),
                    name: "metrickit.diagnostic",
                    category: .metricKitDiagnostic
                )
            }
        }

        private func capture(data: Data, name: String, category: TelemetryCategory) {
            let identifier = Self.stableIdentifier(for: data)
            guard reserveIfNew(identifier) else { return }

            var attributes: [String: TelemetryValue] = [
                "payload_bytes": .integer(Int64(data.count))
            ]
            if data.count <= maximumPayloadBytes,
                let object = try? JSONSerialization.jsonObject(with: data),
                let value = TelemetryValue(foundationValue: object)
            {
                attributes["payload"] = value
            } else {
                attributes["payload_omitted"] = .boolean(true)
            }

            let result = client?.capture(
                TelemetryEvent(
                    id: identifier,
                    name: name,
                    level: category == .metricKitDiagnostic ? .warning : .info,
                    category: category,
                    attributes: attributes
                )
            )
            if result != .accepted {
                forget(identifier)
            }
        }

        private func reserveIfNew(_ identifier: UUID) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard isStarted, recentPayloadIdentifierSet.insert(identifier).inserted else {
                return false
            }
            recentPayloadIdentifiers.append(identifier)
            if recentPayloadIdentifiers.count > maximumRememberedPayloads {
                let expired = recentPayloadIdentifiers.removeFirst()
                recentPayloadIdentifierSet.remove(expired)
            }
            return true
        }

        private func forget(_ identifier: UUID) {
            lock.lock()
            recentPayloadIdentifierSet.remove(identifier)
            recentPayloadIdentifiers.removeAll { $0 == identifier }
            lock.unlock()
        }

        private static func stableIdentifier(for data: Data) -> UUID {
            var first: UInt64 = 14_695_981_039_346_656_037
            var second: UInt64 = 7_809_847_782_465_536_322
            for byte in data {
                first ^= UInt64(byte)
                first &*= 1_099_511_628_211
                second ^= UInt64(byte &+ 0x9d)
                second &*= 1_099_511_628_211
            }
            let raw = String(format: "%016llx%016llx", first, second)
            let uuidString =
                "\(raw.prefix(8))-\(raw.dropFirst(8).prefix(4))-"
                + "\(raw.dropFirst(12).prefix(4))-\(raw.dropFirst(16).prefix(4))-"
                + "\(raw.dropFirst(20).prefix(12))"
            return UUID(uuidString: uuidString) ?? UUID()
        }
    }
#endif
