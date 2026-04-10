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

    private var discovery: DiscoveryService?
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

    private func restart() {
        discovery?.stop()
        registry.clear()

        let svc = DiscoveryService(localPeerID: localID, localName: localName, role: role)
        svc.onPeerFound = { [weak self] peer in
            Task { @MainActor in self?.registry.upsert(peer) }
        }
        svc.onPeerLost = { [weak self] serviceName in
            Task { @MainActor in self?.registry.remove(serviceName: serviceName) }
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
