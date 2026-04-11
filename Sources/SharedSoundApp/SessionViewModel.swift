import Foundation
import Combine
import SharedSoundCore

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
final class SessionViewModel: ObservableObject {
    @Published var role: Peer.Role = .client
    @Published var peers: [Peer] = []
    @Published var isRunning = false

    // Internal — UI binds to `peers` above. We re-emit registry changes
    // through the parent so SwiftUI actually sees them; @Published on a
    // nested ObservableObject only fires when the *reference* changes,
    // not when the reference's contents change.
    private let registry = PeerRegistry()
    private var registryCancellable: AnyCancellable?

    init() {
        registryCancellable = registry.$peers
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newPeers in
                self?.peers = newPeers
                self?.maybeAutoConnect()
            }
    }

    /// CI / headless escape hatch: when launched with
    /// `SHAREDSOUND_AUTO_CONNECT=1` we automatically connect to the first
    /// discovered host without waiting for a UI tap. Lets a Claude session
    /// drive the connect flow on a Mac with no human at the keyboard.
    private var didAutoConnect = false
    private func maybeAutoConnect() {
        guard !didAutoConnect,
              role == .client,
              ProcessInfo.processInfo.environment["SHAREDSOUND_AUTO_CONNECT"] == "1",
              let firstHost = peers.first(where: { $0.role == .host })
        else { return }
        didAutoConnect = true
        connect(to: firstHost)
    }

    // Host state
    @Published var hostConnectedClients: [String] = []
    @Published var hostIsPlaying = false
    @Published var hostIsSyncing = false
    @Published var hostWebURL: String?

    // Client state
    @Published var clientState: String = "Idle"
    @Published var connectedPeerID: UUID?
    @Published var channelMode: ChannelMode = {
        // Persist across launches so a Mac configured as "left speaker"
        // stays that way until you change it.
        if let raw = UserDefaults.standard.string(forKey: "sharedsound.channelMode"),
           let mode = ChannelMode(rawValue: raw) {
            return mode
        }
        return .stereo
    }() {
        didSet {
            UserDefaults.standard.set(channelMode.rawValue, forKey: "sharedsound.channelMode")
            clientSession?.setChannelMode(channelMode)
        }
    }

    private var discovery: DiscoveryService?
    private var hostSession: HostSession?
    private var clientSession: ClientSession?
    private let localID = UUID()

    var localName: String {
        #if os(macOS)
        return Host.current().localizedName ?? "Mac"
        #elseif canImport(UIKit)
        return UIDevice.current.name
        #else
        return "Device"
        #endif
    }

    func start() {
        guard !isRunning else { return }
        restart()
    }

    func toggleRole() {
        role = (role == .host) ? .client : .host
        restart()
    }

    func togglePlayback() {
        guard role == .host, let host = hostSession else { return }
        if hostIsPlaying {
            host.stopPlaying()
            hostIsPlaying = false
            hostWebURL = nil
        } else {
            host.startPlaying()
            hostIsPlaying = true
            hostWebURL = host.webURL
        }
    }

    func connect(to peer: Peer) {
        guard role == .client else { return }
        clientState = "Connecting to \(peer.name)…"
        let cs = ClientSession(peerID: localID, localName: localName)
        cs.onStateChange = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .idle:                       self?.clientState = "Idle"
                case .connecting:                 self?.clientState = "Connecting…"
                case .connected(let name):
                    self?.clientState = "Connected to \(name)"
                    self?.connectedPeerID = peer.id
                case .failed(let msg):            self?.clientState = "Failed: \(msg)"
                case .disconnected:
                    self?.clientState = "Disconnected"
                    self?.connectedPeerID = nil
                }
            }
        }
        cs.connect(to: peer)
        cs.setChannelMode(channelMode)
        clientSession = cs
    }

    func disconnect() {
        clientSession?.disconnect()
        clientSession = nil
    }

    private func restart() {
        hostSession?.shutdown()
        hostSession = nil
        clientSession?.disconnect()
        clientSession = nil

        discovery?.stop()
        registry.clear()
        peers = []
        hostConnectedClients = []
        hostIsPlaying = false
        hostIsSyncing = false
        hostWebURL = nil
        connectedPeerID = nil

        let svc = DiscoveryService(localPeerID: localID, localName: localName, role: role)
        svc.onPeerFound = { [weak self] peer in
            Task { @MainActor in self?.registry.upsert(peer) }
        }
        svc.onPeerLost = { [weak self] serviceName in
            Task { @MainActor in self?.registry.remove(serviceName: serviceName) }
        }

        if role == .host {
            let host = HostSession(hostID: localID, hostName: localName, discovery: svc)
            host.onClientsChanged = { [weak self] clients in
                Task { @MainActor in
                    self?.hostConnectedClients = clients.map(\.name)
                }
            }
            host.onSyncingChanged = { [weak self] syncing in
                Task { @MainActor in
                    self?.hostIsSyncing = syncing
                }
            }
            hostSession = host
        }

        do {
            try svc.start()
            discovery = svc
            isRunning = true
        } catch {
            print("Discovery failed: \(error)")
            isRunning = false
        }
    }
}
