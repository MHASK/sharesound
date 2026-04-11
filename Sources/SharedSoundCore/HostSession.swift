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
        public var mode: ChannelMode
    }

    public var onClientsChanged: (([ConnectedClient]) -> Void)?

    /// Fires on main when the host transitions in/out of "waiting for
    /// clients to sync" state. True between `startPlaying()` and the
    /// moment every connected client has reported `.syncReady`.
    public var onSyncingChanged: ((Bool) -> Void)?

    private let hostID: UUID
    private let hostName: String
    private let discovery: DiscoveryService
    private let queue = DispatchQueue(label: "sharedsound.host")
    private let source = SystemAudioSource()
    private let webServer = WebStreamServer()

    private var clients: [UUID: ConnectedClient] = [:]
    private var clientModes: [UUID: ChannelMode] = [:]
    private var pendingByConnection: [ObjectIdentifier: ControlChannel] = [:]
    private var isPlaying = false
    private var captureStarted = false
    private var waitingForSync = false
    private var readyPeers: Set<UUID> = []
    private var syncTimeoutWork: DispatchWorkItem?
    private var sequence: UInt32 = 0


    /// Max time we'll hold the host back waiting on a client to sync
    /// before starting capture anyway. Covers the case of a misbehaving
    /// or very-slow client that never sends `.syncReady`.
    private let syncGateTimeoutNanos: Int = 3_000  // milliseconds

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

        // Web server spins up immediately — browsers don't need sync.
        do {
            try webServer.start()
            let ip = LocalAddress.ipv4() ?? "localhost"
            webURL = "http://\(ip):\(WebStreamServer.defaultPort)"
            log.log("web URL: \(self.webURL ?? "-", privacy: .public)")
        } catch {
            log.log("web server start failed: \(String(describing: error), privacy: .public)")
        }

        // Native clients need the time-sync filter to lock before they
        // can schedule audio. Wait until every currently-connected
        // client has sent `.syncReady`, then start capture so the first
        // sample the user hears is actually live everywhere.
        let pending = Set(clients.keys).subtracting(readyPeers)
        if pending.isEmpty {
            startCapture()
        } else {
            waitingForSync = true
            emitSyncingChanged(true)
            log.log("waiting on \(pending.count, privacy: .public) client(s) to sync before starting capture")
            scheduleSyncTimeout()
        }
    }

    public func stopPlaying() {
        guard isPlaying else { return }
        if captureStarted {
            source.stop()
            captureStarted = false
        }
        webServer.stop()
        webURL = nil
        isPlaying = false
        if waitingForSync {
            waitingForSync = false
            emitSyncingChanged(false)
        }
        syncTimeoutWork?.cancel()
        syncTimeoutWork = nil
    }

    private func startCapture() {
        guard !captureStarted else { return }
        do {
            try source.start()
            captureStarted = true
            log.log("capture started")
        } catch {
            log.log("capture start failed: \(String(describing: error), privacy: .public)")
            isPlaying = false
            return
        }
        if waitingForSync {
            waitingForSync = false
            emitSyncingChanged(false)
        }
        syncTimeoutWork?.cancel()
        syncTimeoutWork = nil
    }

    private func scheduleSyncTimeout() {
        syncTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.waitingForSync else { return }
            log.log("sync gate timed out — starting capture anyway")
            self.startCapture()
        }
        syncTimeoutWork = work
        queue.asyncAfter(deadline: .now() + .milliseconds(syncGateTimeoutNanos), execute: work)
    }

    private func emitSyncingChanged(_ syncing: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onSyncingChanged?(syncing)
        }
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

            let initialMode: ChannelMode = clientModes[peerID] ?? .stereo
            let client = ConnectedClient(
                peerID: peerID,
                name: name,
                control: control,
                audio: sender,
                mode: initialMode
            )
            clients[peerID] = client
            clientModes[peerID] = initialMode
            pendingByConnection.removeValue(forKey: ObjectIdentifier(connection))

            control.send(.welcome(hostID: hostID, name: hostName))
            // Push the assigned mode immediately so a reconnecting peer
            // resumes its previous role without the host having to
            // re-touch the picker.
            control.send(.setChannelMode(mode: initialMode))
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

        case .syncReady(let peerID):
            guard clients[peerID] != nil else { return }
            readyPeers.insert(peerID)
            log.log("client \(peerID.uuidString, privacy: .public) syncReady (\(self.readyPeers.count, privacy: .public)/\(self.clients.count, privacy: .public))")
            if waitingForSync {
                let pending = Set(clients.keys).subtracting(readyPeers)
                if pending.isEmpty {
                    startCapture()
                }
            }

        case .setChannelMode:
            break   // hosts shouldn't receive this; ignore defensively

        case .unknown:
            log.log("ignoring unknown control message from \(String(describing: connection.endpoint), privacy: .public)")
        }
    }

    /// Assign (or reassign) a connected listener's channel role. Updates
    /// local bookkeeping AND pushes a `setChannelMode` control frame to
    /// the affected client. Safe to call from any thread.
    public func setClientMode(_ peerID: UUID, _ mode: ChannelMode) {
        queue.async { [weak self] in
            guard let self else { return }
            self.clientModes[peerID] = mode
            guard var client = self.clients[peerID] else { return }
            client.mode = mode
            self.clients[peerID] = client
            client.control.send(.setChannelMode(mode: mode))
            log.log("client \(peerID.uuidString, privacy: .public) → \(mode.rawValue, privacy: .public)")
            self.emitClients()
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
            readyPeers.remove(victimID)
            emitClients()
            // If we were waiting on this peer specifically, releasing it
            // may unblock the gate.
            if waitingForSync {
                let pending = Set(clients.keys).subtracting(readyPeers)
                if pending.isEmpty {
                    startCapture()
                }
            }
        }
    }

    private func emitClients() {
        let snapshot = Array(clients.values)
        DispatchQueue.main.async { [weak self] in
            self?.onClientsChanged?(snapshot)
        }
    }
}
