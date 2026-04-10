import Foundation
import Network
import os

private let log = Logger(subsystem: "dev.sharesound", category: "discovery")

/// Bonjour-based peer discovery over the local network.
///
/// Advertises the local device as `_sharedsound._tcp` and browses for the same
/// service type. TXT record carries a stable peer id, display name, role, and
/// protocol version so clients can dedupe and filter without opening a
/// connection.
///
/// Lifecycle:
///   let svc = DiscoveryService(localName: "Muhammed's Mac", role: .host)
///   svc.onPeerFound   = { peer in ... }
///   svc.onPeerLost    = { serviceName in ... }
///   svc.start()
///
/// Stop with `stop()` before releasing.
public final class DiscoveryService {
    public static let serviceType = "_sharedsound._tcp"
    public static let protocolVersion = "1"

    private enum TXTKey {
        static let id      = "id"
        static let name    = "name"
        static let role    = "role"
        static let version = "v"
    }

    public let localPeerID: UUID
    public let localName: String
    public let role: Peer.Role

    public var onPeerFound: ((Peer) -> Void)?
    public var onPeerLost: ((String) -> Void)?   // serviceName

    /// Fires when a remote peer opens a TCP connection to our advertised
    /// Bonjour service. Host side uses this as the incoming control channel.
    public var onIncomingConnection: ((NWConnection) -> Void)?

    public private(set) var listener: NWListener?
    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "sharedsound.discovery")

    public init(localPeerID: UUID = UUID(), localName: String, role: Peer.Role) {
        self.localPeerID = localPeerID
        self.localName = localName
        self.role = role
    }

    // MARK: - Lifecycle

    public func start() throws {
        try startAdvertising()
        startBrowsing()
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        browser?.cancel()
        browser = nil
    }

    // MARK: - Advertise

    private func startAdvertising() throws {
        let txt: [String: String] = [
            TXTKey.id: localPeerID.uuidString,
            TXTKey.name: localName,
            TXTKey.role: role.rawValue,
            TXTKey.version: Self.protocolVersion
        ]
        let txtRecord = NWTXTRecord(txt)

        // Port 0 = let the OS pick. The real audio/control ports are negotiated
        // later; discovery just needs *a* listener for Bonjour registration.
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let listener = try NWListener(using: params, on: .any)
        listener.service = NWListener.Service(
            name: localPeerID.uuidString,    // globally unique per launch
            type: Self.serviceType,
            txtRecord: txtRecord
        )
        listener.newConnectionHandler = { [weak self] conn in
            if let handler = self?.onIncomingConnection {
                handler(conn)
            } else {
                conn.cancel()
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    // MARK: - Browse

    private func startBrowsing() {
        let params = NWParameters()
        // Wi-Fi only for now. p2p (AWDL) adds interfaces that sometimes
        // deliver results without TXT records, which we can't parse.
        params.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: params
        )
        browser.stateUpdateHandler = { state in
            log.log("browser state: \(String(describing: state), privacy: .public)")
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            log.log("browser results: \(results.count, privacy: .public)")
            self?.handle(results: results)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func handle(results: Set<NWBrowser.Result>) {
        var seenServiceNames = Set<String>()

        for result in results {
            guard case let .service(name: serviceName, type: _, domain: _, interface: _) = result.endpoint else {
                log.log("skip non-service endpoint: \(String(describing: result.endpoint), privacy: .public)")
                continue
            }
            seenServiceNames.insert(serviceName)

            // Filter ourselves out.
            if serviceName == localPeerID.uuidString { continue }

            // Try to read TXT. NWBrowser sometimes delivers a result before
            // the TXT record arrives (metadata comes back as .none). Fall
            // back to the service name as a synthetic id so the peer still
            // shows up — we upgrade the entry once a later browse update
            // brings TXT along.
            let peer: Peer
            if case let .bonjour(txt) = result.metadata,
               let idStr = txt[TXTKey.id],
               let id = UUID(uuidString: idStr),
               let displayName = txt[TXTKey.name],
               let roleStr = txt[TXTKey.role],
               let role = Peer.Role(rawValue: roleStr) {
                peer = Peer(id: id, name: displayName, role: role,
                            serviceName: serviceName, endpoint: result.endpoint)
            } else {
                log.log("result without TXT, fallback: \(serviceName, privacy: .public) meta=\(String(describing: result.metadata), privacy: .public)")
                // Deterministic UUID from the service name so repeated fallbacks dedupe.
                let fallbackID = Self.deterministicUUID(from: serviceName)
                peer = Peer(
                    id: fallbackID,
                    name: serviceName.prefix(8).description,
                    role: .host,                  // assume host so clients can connect
                    serviceName: serviceName,
                    endpoint: result.endpoint
                )
            }
            log.log("peer: \(peer.name, privacy: .public) role=\(peer.role.rawValue, privacy: .public)")
            onPeerFound?(peer)
        }

        // Detect losses: anything we previously surfaced but isn't in this
        // snapshot. Browser delivers full set on each change so diffing here
        // is straightforward but requires tracking prior state.
        let lost = lastSeenServiceNames.subtracting(seenServiceNames)
        for name in lost { onPeerLost?(name) }
        lastSeenServiceNames = seenServiceNames
    }

    private var lastSeenServiceNames: Set<String> = []

    /// Stable UUID from a string via UUIDv5-style name hashing. Used as a
    /// fallback peer id when TXT record isn't yet available.
    private static func deterministicUUID(from name: String) -> UUID {
        var hasher = Hasher()
        hasher.combine(name)
        let h = UInt64(bitPattern: Int64(hasher.finalize()))
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i] = UInt8((h >> (i * 8)) & 0xff) }
        for i in 8..<16 { bytes[i] = UInt8((UInt64(name.count) >> ((i - 8) * 8)) & 0xff) }
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
