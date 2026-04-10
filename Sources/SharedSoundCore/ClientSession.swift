import Foundation
import Network
import os

private let log = Logger(subsystem: "dev.sharesound", category: "client")

/// Client-side session.
///
/// Flow:
///   1. Open UDP receiver on an ephemeral port.
///   2. Open TCP control connection to the host's discovered endpoint.
///   3. Send `hello` with our peer id, name, and UDP port.
///   4. Wait for `welcome`; start playback.
///   5. Incoming `AudioPacket`s are fed straight to `AudioPlayer`.
public final class ClientSession {
    public enum State: Sendable {
        case idle
        case connecting
        case connected(hostName: String)
        case failed(String)
        case disconnected
    }

    public var onStateChange: ((State) -> Void)?

    private let peerID: UUID
    private let localName: String
    private let queue = DispatchQueue(label: "sharedsound.client")

    private var control: ControlChannel?
    private var receiver: AudioChannel.Receiver?
    private let player = AudioPlayer()

    public init(peerID: UUID, localName: String) {
        self.peerID = peerID
        self.localName = localName
    }

    public func connect(to host: Peer) {
        log.log("connect → \(host.name, privacy: .public) endpoint=\(String(describing: host.endpoint), privacy: .public)")
        disconnect()
        onStateChange?(.connecting)

        let recv: AudioChannel.Receiver
        do {
            recv = try AudioChannel.Receiver(queue: queue)
        } catch {
            onStateChange?(.failed("audio listener: \(error)"))
            return
        }
        recv.onPacket = { [weak self] pkt in
            self?.player.schedule(pkt)
        }
        recv.start()
        self.receiver = recv

        // The listener needs a moment to bind before we can report its port.
        // Poll briefly; bail if it doesn't come up.
        waitForReceiverPort { [weak self] port in
            guard let self else { return }
            guard let port else {
                self.onStateChange?(.failed("audio listener failed to bind"))
                return
            }
            self.openControl(to: host, audioPort: port)
        }
    }

    public func disconnect() {
        control?.send(.bye)
        control?.close()
        control = nil
        receiver?.stop()
        receiver = nil
        player.stop()
        onStateChange?(.disconnected)
    }

    // MARK: - Internals

    private func waitForReceiverPort(
        attempts: Int = 20,
        completion: @escaping (UInt16?) -> Void
    ) {
        if let port = receiver?.port, port != 0 {
            completion(port)
            return
        }
        if attempts == 0 {
            completion(nil)
            return
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            self?.waitForReceiverPort(attempts: attempts - 1, completion: completion)
        }
    }

    private func openControl(to host: Peer, audioPort: UInt16) {
        log.log("opening TCP control to \(String(describing: host.endpoint), privacy: .public) audioPort=\(audioPort, privacy: .public)")
        let params = NWParameters.tcp
        // Match the host's listener: wifi only, no AWDL.
        params.includePeerToPeer = false
        let conn = NWConnection(to: host.endpoint, using: params)
        let channel = ControlChannel(connection: conn, queue: queue)

        channel.onStateChange = { [weak self, weak channel] state in
            guard let self else { return }
            switch state {
            case .ready:
                channel?.send(.hello(peerID: self.peerID, name: self.localName, audioPort: audioPort))
            case .failed(let msg):
                self.onStateChange?(.failed(msg))
            case .closed:
                self.onStateChange?(.disconnected)
            case .connecting:
                break
            }
        }
        channel.onMessage = { [weak self] msg in
            guard let self else { return }
            if case .welcome(_, let name) = msg {
                do {
                    try self.player.start()
                    self.onStateChange?(.connected(hostName: name))
                } catch {
                    self.onStateChange?(.failed("audio engine: \(error)"))
                }
            }
        }
        channel.start()
        self.control = channel
    }
}
