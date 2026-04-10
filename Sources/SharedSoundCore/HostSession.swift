import Foundation
import Network
import os

private let log = Logger(subsystem: "dev.sharesound", category: "host")

/// Host-side session. Owns:
///   - the DiscoveryService (so it can re-wire incoming TCP connections)
///   - the set of connected clients (control + audio sender per client)
///   - a timer-driven audio source that pushes packets to every client
///
/// M2 audio source is a fixed sine generator. M3+ replaces it with a real
/// capture source.
public final class HostSession {
    public struct ConnectedClient {
        public let peerID: UUID
        public let name: String
        public let control: ControlChannel
        public let audio: AudioChannel.Sender
    }

    public var onClientsChanged: (([ConnectedClient]) -> Void)?

    private let hostID: UUID
    private let hostName: String
    private let discovery: DiscoveryService
    private let queue = DispatchQueue(label: "sharedsound.host")
    private let source = SineSource()

    private var clients: [UUID: ConnectedClient] = [:]
    private var pendingByConnection: [ObjectIdentifier: ControlChannel] = [:]
    private var isPlaying = false
    private var sendTimer: DispatchSourceTimer?
    private var sequence: UInt32 = 0

    public init(hostID: UUID, hostName: String, discovery: DiscoveryService) {
        self.hostID = hostID
        self.hostName = hostName
        self.discovery = discovery
        discovery.onIncomingConnection = { [weak self] conn in
            self?.handleIncoming(conn)
        }
    }

    public func startPlaying() {
        guard !isPlaying else { return }
        isPlaying = true
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // 10ms packet interval matches AudioFormat.samplesPerFrame at 48kHz.
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        sendTimer = timer
    }

    public func stopPlaying() {
        sendTimer?.cancel()
        sendTimer = nil
        isPlaying = false
    }

    public func shutdown() {
        stopPlaying()
        for client in clients.values {
            client.control.send(.bye)
            client.control.close()
            client.audio.stop()
        }
        clients.removeAll()
        onClientsChanged?([])
    }

    // MARK: - Internals

    private func tick() {
        let pcm = source.nextFrame()
        sequence &+= 1
        let packet = AudioPacket(
            sequenceNumber: sequence,
            hostTimeNanos: 0,
            sampleCount: UInt16(AudioFormat.samplesPerFrame),
            pcm: pcm
        )
        for client in clients.values {
            client.audio.send(packet)
        }
    }

    private func handleIncoming(_ conn: NWConnection) {
        log.log("incoming TCP from \(String(describing: conn.endpoint), privacy: .public)")
        let control = ControlChannel(connection: conn, queue: queue)
        let key = ObjectIdentifier(conn)
        pendingByConnection[key] = control

        control.onMessage = { [weak self] msg in
            self?.handleControlMessage(msg, control: control, connection: conn)
        }
        control.onStateChange = { [weak self] state in
            if case .closed = state {
                self?.dropConnection(conn)
            } else if case .failed = state {
                self?.dropConnection(conn)
            }
        }
        control.start()
    }

    private func handleControlMessage(_ msg: ControlMessage, control: ControlChannel, connection: NWConnection) {
        switch msg {
        case .hello(let peerID, let name, let audioPort):
            log.log("hello from \(name, privacy: .public) peerID=\(peerID.uuidString, privacy: .public) audioPort=\(audioPort, privacy: .public)")
            let remoteHost = remoteHost(from: connection)
            let sender = AudioChannel.Sender(
                host: remoteHost,
                port: NWEndpoint.Port(rawValue: audioPort) ?? .any,
                queue: queue
            )
            sender.start()

            let client = ConnectedClient(
                peerID: peerID,
                name: name,
                control: control,
                audio: sender
            )
            clients[peerID] = client
            pendingByConnection.removeValue(forKey: ObjectIdentifier(connection))

            control.send(.welcome(hostID: hostID, name: hostName))
            emitClients()

        case .bye:
            control.close()

        case .welcome:
            break   // hosts shouldn't receive welcome
        }
    }

    private func remoteHost(from connection: NWConnection) -> NWEndpoint.Host {
        if case let .hostPort(host: host, port: _) = connection.endpoint {
            return host
        }
        return .ipv4(.loopback)
    }

    private func dropConnection(_ conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        pendingByConnection.removeValue(forKey: key)
        if let victimID = clients.first(where: { _, v in ObjectIdentifier(v.control as AnyObject) == ObjectIdentifier(conn) })?.key {
            clients[victimID]?.audio.stop()
            clients.removeValue(forKey: victimID)
            emitClients()
        }
    }

    private func emitClients() {
        let snapshot = Array(clients.values)
        DispatchQueue.main.async { [weak self] in
            self?.onClientsChanged?(snapshot)
        }
    }
}
