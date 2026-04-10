import Foundation
import Network

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

    private var listener: NWListener?
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
        // We must accept connections or the service won't stay registered,
        // but at this milestone we just close them immediately.
        listener.newConnectionHandler = { conn in
            conn.cancel()
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    // MARK: - Browse

    private func startBrowsing() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil),
            using: params
        )
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            self?.handle(results: results)
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func handle(results: Set<NWBrowser.Result>) {
        var seenServiceNames = Set<String>()

        for result in results {
            guard case let .service(name: serviceName, type: _, domain: _, interface: _) = result.endpoint else {
                continue
            }
            seenServiceNames.insert(serviceName)

            // Filter ourselves out.
            if serviceName == localPeerID.uuidString { continue }

            guard case let .bonjour(txt) = result.metadata,
                  let idStr = txt[TXTKey.id],
                  let id = UUID(uuidString: idStr),
                  let displayName = txt[TXTKey.name],
                  let roleStr = txt[TXTKey.role],
                  let role = Peer.Role(rawValue: roleStr)
            else { continue }

            let peer = Peer(id: id, name: displayName, role: role, serviceName: serviceName)
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
}
