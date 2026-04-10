import Foundation
import Network

/// A device participating in a SharedSound session — either advertising itself or discovered on the network.
public struct Peer: Identifiable, Hashable, @unchecked Sendable {
    public enum Role: String, Sendable, Codable {
        case host
        case client
    }

    /// Stable per-launch identifier. Carried in the Bonjour TXT record so peers can
    /// dedupe when a device changes name or re-advertises on a new interface.
    public let id: UUID

    /// Human-readable device name (e.g. "Muhammed's MacBook Pro").
    public var name: String

    public var role: Role

    /// Bonjour service name — opaque, used for tracking losses.
    public let serviceName: String

    /// Resolvable network endpoint. Pass straight to `NWConnection(to:using:)`.
    public let endpoint: NWEndpoint

    public init(id: UUID, name: String, role: Role, serviceName: String, endpoint: NWEndpoint) {
        self.id = id
        self.name = name
        self.role = role
        self.serviceName = serviceName
        self.endpoint = endpoint
    }

    // Identity is by `id` only — two results for the same device on different
    // interfaces should collapse to one row in the UI.
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (lhs: Peer, rhs: Peer) -> Bool { lhs.id == rhs.id }
}
