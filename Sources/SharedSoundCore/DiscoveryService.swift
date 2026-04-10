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
        static let host    = "h"
        static let port    = "p"
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
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let listener = try NWListener(using: params, on: .any)

        listener.newConnectionHandler = { [weak self] conn in
            if let handler = self?.onIncomingConnection {
                handler(conn)
            } else {
                conn.cancel()
            }
        }

        // The TXT record needs the listener's actual port, which isn't
        // known until the listener reaches `.ready`. Publish the Bonjour
        // service then, with host:port baked in.
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            guard let self, let listener else { return }
            log.log("listener state: \(String(describing: state), privacy: .public)")
            if case .ready = state, let p = listener.port?.rawValue {
                let host = LocalAddress.ipv4() ?? "0.0.0.0"
                let txt: [String: String] = [
                    TXTKey.id: self.localPeerID.uuidString,
                    TXTKey.name: self.localName,
                    TXTKey.role: self.role.rawValue,
                    TXTKey.version: Self.protocolVersion,
                    TXTKey.host: host,
                    TXTKey.port: String(p)
                ]
                listener.service = NWListener.Service(
                    name: self.localPeerID.uuidString,
                    type: Self.serviceType,
                    txtRecord: NWTXTRecord(txt)
                )
                log.log("advertising \(host, privacy: .public):\(p, privacy: .public) as \(self.role.rawValue, privacy: .public)")
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

            // We require TXT now — without it we have no host:port and
            // can't connect. NWBrowser delivers TXT in a follow-up update if
            // it isn't ready yet, so silently skip and wait for the next
            // results-changed callback.
            guard case let .bonjour(txt) = result.metadata,
                  let idStr = txt[TXTKey.id],
                  let id = UUID(uuidString: idStr),
                  let displayName = txt[TXTKey.name],
                  let roleStr = txt[TXTKey.role],
                  let role = Peer.Role(rawValue: roleStr),
                  let host = txt[TXTKey.host],
                  let portStr = txt[TXTKey.port],
                  let port = UInt16(portStr)
            else {
                log.log("skip (no TXT yet): \(serviceName, privacy: .public)")
                continue
            }
            let peer = Peer(
                id: id, name: displayName, role: role,
                serviceName: serviceName, host: host, port: port
            )
            log.log("peer: \(peer.name, privacy: .public) role=\(peer.role.rawValue, privacy: .public) at \(host, privacy: .public):\(port, privacy: .public)")
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
