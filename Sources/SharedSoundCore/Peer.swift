import Foundation

/// A device participating in a SharedSound session — either advertising itself or discovered on the network.
public struct Peer: Identifiable, Hashable, Sendable {
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

    /// Bonjour service name — opaque, used to re-resolve the endpoint.
    public let serviceName: String

    public init(id: UUID, name: String, role: Role, serviceName: String) {
        self.id = id
        self.name = name
        self.role = role
        self.serviceName = serviceName
    }
}
