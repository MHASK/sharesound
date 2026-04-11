import Foundation
import Network
import os

private let log = Logger(subsystem: "dev.sharesound", category: "audio")

/// UDP audio transport. Two modes:
///
///   - **Sender** (host): opens a `NWConnection` to a client's declared
///     `host + audioPort`. `send(_:)` fires and forgets.
///   - **Receiver** (client): opens a `NWListener` on an ephemeral UDP port,
///     reports it via `port`, and hands decoded packets to `onPacket`.
///
/// UDP is unreliable by design: a lost 10ms frame is cheaper than a stalled
/// stream. M4 adds a jitter buffer + reordering using the sequence numbers.
public enum AudioChannel {

    // MARK: - Receiver

    public final class Receiver {
        public var onPacket: ((AudioPacket) -> Void)?
        public private(set) var port: UInt16 = 0

        private let listener: NWListener
        private let queue: DispatchQueue
        private var connections: [NWConnection] = []

        public init(queue: DispatchQueue) throws {
            self.queue = queue
            let params = NWParameters.udp
            params.allowLocalEndpointReuse = true
            self.listener = try NWListener(using: params)
        }

        public func start() {
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                self.connections.append(conn)
                conn.stateUpdateHandler = { _ in }
                conn.start(queue: self.queue)
                self.receive(on: conn)
            }
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state, let p = self?.listener.port {
                    self?.port = p.rawValue
                }
            }
            listener.start(queue: queue)
        }

        public func stop() {
            listener.cancel()
            connections.forEach { $0.cancel() }
            connections.removeAll()
        }

        private func receive(on conn: NWConnection) {
            conn.receiveMessage { [weak self] data, _, _, error in
                guard let self else { return }
                if let data, let pkt = AudioPacket.decode(data) {
                    self.onPacket?(pkt)
                }
                if error == nil {
                    self.receive(on: conn)
                }
            }
        }
    }

    // MARK: - Sender

    public final class Sender {
        private let connection: NWConnection
        private let queue: DispatchQueue

        public init(host: NWEndpoint.Host, port: NWEndpoint.Port, queue: DispatchQueue) {
            self.queue = queue
            let params = NWParameters.udp
            self.connection = NWConnection(host: host, port: port, using: params)
        }

        public func start() {
            connection.start(queue: queue)
        }

        public func stop() {
            connection.cancel()
        }

        public func send(_ packet: AudioPacket) {
            connection.send(
                content: packet.encoded(),
                completion: .contentProcessed { _ in }
            )
        }
    }
}
