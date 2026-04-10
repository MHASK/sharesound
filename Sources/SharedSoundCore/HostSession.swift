import Foundation
import Network
import os

private let log = Logger(subsystem: "dev.sharesound", category: "host")

/// Host-side session. Owns:
///   - the DiscoveryService (so it can re-wire incoming TCP connections)
///   - the set of connected clients (control + audio sender per client)
///   - a MicSource that pushes captured audio frames to every client
///   - a WebStreamServer so browsers on the LAN can also listen in
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
    private let source = SystemAudioSource()
    private let webServer = WebStreamServer()

    private var clients: [UUID: ConnectedClient] = [:]
    private var pendingByConnection: [ObjectIdentifier: ControlChannel] = [:]
    private var isPlaying = false
    private var sequence: UInt32 = 0

    /// URL to share with browser guests once `startPlaying()` has been
    /// called. nil before the web server is up.
    public private(set) var webURL: String?

    public init(hostID: UUID, hostName: String, discovery: DiscoveryService) {
        self.hostID = hostID
        self.hostName = hostName
        self.discovery = discovery
        discovery.onIncomingConnection = { [weak self] conn in
            self?.handleIncoming(conn)
        }
        source.onFrame = { [weak self] pcm, captureNanos in
            self?.queue.async { self?.broadcast(pcm, captureNanos: captureNanos) }
        }
    }

    public func startPlaying() {
        guard !isPlaying else { return }
        isPlaying = true
        do {
            try source.start()
        } catch {
            log.log("mic start failed: \(String(describing: error), privacy: .public)")
            isPlaying = false
            return
        }
        do {
            try webServer.start()
            let ip = LocalAddress.ipv4() ?? "localhost"
            webURL = "http://\(ip):\(WebStreamServer.defaultPort)"
            log.log("web URL: \(self.webURL ?? "-", privacy: .public)")
        } catch {
            log.log("web server start failed: \(String(describing: error), privacy: .public)")
        }
    }

    public func stopPlaying() {
        guard isPlaying else { return }
        source.stop()
        webServer.stop()
        webURL = nil
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

    private func broadcast(_ pcm: Data, captureNanos: UInt64) {
        sequence &+= 1
        let packet = AudioPacket(
            sequenceNumber: sequence,
            hostTimeNanos: captureNanos,
            sampleCount: UInt16(AudioFormat.samplesPerFrame),
            pcm: pcm
        )
        for client in clients.values {
            client.audio.send(packet)
        }
        webServer.broadcast(pcm)
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
        // Stamp receive time as early as possible — before any decoding
        // work — so clients see the tightest possible RTT bound.
        let receiveNanos = HostClock.nowNanos()
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

        case .timeSyncRequest(let t0):
            // Reply with the host's receive + send stamps. Keep the
            // compute window between these two reads as small as
            // possible; the delta is the irreducible host-side processing
            // latency that the client will factor out.
            let sendNanos = HostClock.nowNanos()
            control.send(.timeSyncResponse(t0: t0, t1: receiveNanos, t2: sendNanos))

        case .timeSyncResponse:
            break   // hosts shouldn't receive responses
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
