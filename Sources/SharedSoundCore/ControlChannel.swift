import Foundation
import Network
import os

private let log = Logger(subsystem: "dev.sharesound", category: "control")

/// One TCP control connection, host or client side. Handles the length-prefix
/// framing so callers just see whole `ControlMessage` values.
public final class ControlChannel {
    public enum State: Sendable {
        case connecting
        case ready
        case failed(String)
        case closed
    }

    public var onMessage: ((ControlMessage) -> Void)?
    public var onStateChange: ((State) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var rxBuffer = Data()

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public func start() {
        log.log("control start, endpoint=\(String(describing: self.connection.endpoint), privacy: .public)")
        connection.stateUpdateHandler = { [weak self] state in
            log.log("control state: \(String(describing: state), privacy: .public)")
            switch state {
            case .ready:          self?.onStateChange?(.ready)
            case .failed(let e):  self?.onStateChange?(.failed("\(e)"))
            case .cancelled:      self?.onStateChange?(.closed)
            default:              self?.onStateChange?(.connecting)
            }
        }
        connection.start(queue: queue)
        scheduleRead()
    }

    public func send(_ message: ControlMessage) {
        do {
            let data = try ControlFrame.encode(message)
            connection.send(content: data, completion: .contentProcessed { _ in })
        } catch {
            onStateChange?(.failed("encode: \(error)"))
        }
    }

    public func close() {
        connection.cancel()
    }

    private func scheduleRead() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isEOF, error in
            guard let self else { return }
            if let error {
                self.onStateChange?(.failed("\(error)"))
                return
            }
            if let data, !data.isEmpty {
                self.rxBuffer.append(data)
                self.drainBuffer()
            }
            if isEOF {
                self.onStateChange?(.closed)
                return
            }
            self.scheduleRead()
        }
    }

    private func drainBuffer() {
        while true {
            do {
                guard let msg = try ControlFrame.decode(from: &rxBuffer) else { return }
                onMessage?(msg)
            } catch {
                onStateChange?(.failed("decode: \(error)"))
                connection.cancel()
                return
            }
        }
    }
}
