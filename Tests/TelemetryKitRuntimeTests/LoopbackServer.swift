import Foundation
import Network

/// A bounded, loopback-only HTTP fixture. All mutable state is confined to queue.
final class LoopbackServer: @unchecked Sendable {
    struct Request: Sendable {
        let headers: String
        let body: Data
    }

    private let queue = DispatchQueue(label: "io.telemetrykit.tests.http")
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var received: [Request] = []
    private let responses: [String]
    var port: UInt16 { queue.sync { listener.port!.rawValue } }

    init(responses: [String]) throws {
        self.responses = responses
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else {
                connection.cancel()
                return
            }
            guard self.connections.count < 64 else {
                connection.cancel()
                return
            }
            self.connections.append(connection)
            connection.start(queue: self.queue)
            self.receive(connection, accumulated: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
    }

    var endpoint: URL { URL(string: "http://127.0.0.1:\(port)/events")! }

    func requests() -> [Request] { queue.sync { received } }

    func stop() {
        queue.sync {
            listener.cancel()
            for connection in connections { connection.cancel() }
            connections.removeAll()
        }
    }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
            [weak self] data, _, complete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var bytes = accumulated
            if let data { bytes.append(data) }
            guard bytes.count <= 2 * 1_024 * 1_024 else {
                connection.cancel()
                return
            }
            if let boundary = bytes.range(of: Data("\r\n\r\n".utf8)) {
                let headers = String(decoding: bytes[..<boundary.lowerBound], as: UTF8.self)
                let contentLength =
                    headers.components(separatedBy: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                guard contentLength >= 0, contentLength <= 1_024 * 1_024 else {
                    connection.cancel()
                    return
                }
                if bytes.count - boundary.upperBound >= contentLength {
                    let index = self.received.count
                    self.received.append(
                        Request(
                            headers: headers,
                            body: Data(bytes[boundary.upperBound..<(boundary.upperBound + contentLength)])
                        ))
                    let response = self.responses.isEmpty ? "" : self.responses[min(index, self.responses.count - 1)]
                    // Empty responses deliberately stall until client cancellation.
                    if !response.isEmpty {
                        connection.send(
                            content: Data(response.utf8),
                            completion: .contentProcessed { _ in
                                connection.cancel()
                            })
                    }
                    return
                }
            }
            if complete || error != nil {
                connection.cancel()
                return
            }
            self.receive(connection, accumulated: bytes)
        }
    }

    static func response(_ status: Int, headers: String = "") -> String {
        "HTTP/1.1 \(status) Test\r\nContent-Length: 0\r\nConnection: close\r\n\(headers)\r\n"
    }
}
