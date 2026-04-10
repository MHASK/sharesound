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

    /// Direct host:port the peer is listening on. Read from TXT so the
    /// connect path doesn't need to resolve a Bonjour service endpoint —
    /// `NWConnection.hostPort` is far more reliable across macOS/iOS than
    /// `NWConnection(to: .service(...))`.
    public let host: String
    public let port: UInt16

    public init(id: UUID, name: String, role: Role, serviceName: String, host: String, port: UInt16) {
        self.id = id
        self.name = name
        self.role = role
        self.serviceName = serviceName
        self.host = host
        self.port = port
    }

    // Identity is by `id` only — two results for the same device on different
    // interfaces should collapse to one row in the UI.
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
    public static func == (lhs: Peer, rhs: Peer) -> Bool { lhs.id == rhs.id }
}
