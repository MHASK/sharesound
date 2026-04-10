import Foundation
import Combine

/// Thread-safe, observable set of known peers. UI binds to `peers`.
///
/// Deduplication is by `Peer.id` (the UUID carried in the TXT record). Bonjour
/// may surface the same device twice — once per network interface — so we
/// collapse on identity rather than on service name.
@MainActor
public final class PeerRegistry: ObservableObject {
    @Published public private(set) var peers: [Peer] = []

    public init() {}

    public func upsert(_ peer: Peer) {
        if let idx = peers.firstIndex(where: { $0.id == peer.id }) {
            peers[idx] = peer
        } else {
            peers.append(peer)
            peers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    public func remove(serviceName: String) {
        peers.removeAll { $0.serviceName == serviceName }
    }

    public func remove(id: UUID) {
        peers.removeAll { $0.id == id }
    }

    public func clear() {
        peers.removeAll()
    }
}
