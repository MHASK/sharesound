import Foundation
import SharedSoundCore

#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

@MainActor
final class SessionViewModel: ObservableObject {
    @Published var role: Peer.Role = .client
    @Published var registry = PeerRegistry()
    @Published var isRunning = false

    // Host state
    @Published var hostConnectedClients: [String] = []
    @Published var hostIsPlaying = false

    // Client state
    @Published var clientState: String = "Idle"
    @Published var connectedPeerID: UUID?

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
        } else {
            host.startPlaying()
            hostIsPlaying = true
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
        hostConnectedClients = []
        hostIsPlaying = false
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
