import XCTest
import Network
@testable import SharedSoundCore

@MainActor
final class PeerRegistryTests: XCTestCase {

    private func makePeer(
        id: UUID = UUID(),
        name: String,
        role: Peer.Role = .client,
        serviceName: String = "svc"
    ) -> Peer {
        Peer(
            id: id,
            name: name,
            role: role,
            serviceName: serviceName,
            host: "192.168.0.1", port: 1234
        )
    }

    func testUpsertAddsNewPeer() {
        let reg = PeerRegistry()
        reg.upsert(makePeer(name: "Mac", role: .host))
        XCTAssertEqual(reg.peers.count, 1)
        XCTAssertEqual(reg.peers.first?.name, "Mac")
    }

    func testUpsertDedupesById() {
        let reg = PeerRegistry()
        let id = UUID()
        reg.upsert(makePeer(id: id, name: "Old Name", role: .client, serviceName: "svc-1"))
        reg.upsert(makePeer(id: id, name: "New Name", role: .host,   serviceName: "svc-2"))
        XCTAssertEqual(reg.peers.count, 1)
        XCTAssertEqual(reg.peers.first?.name, "New Name")
        XCTAssertEqual(reg.peers.first?.role, .host)
    }

    func testRemoveByServiceName() {
        let reg = PeerRegistry()
        reg.upsert(makePeer(name: "A", serviceName: "svc-a"))
        reg.upsert(makePeer(name: "B", serviceName: "svc-b"))
        reg.remove(serviceName: "svc-a")
        XCTAssertEqual(reg.peers.count, 1)
        XCTAssertEqual(reg.peers.first?.name, "B")
    }

    func testRemoveById() {
        let reg = PeerRegistry()
        let id = UUID()
        reg.upsert(makePeer(id: id, name: "A"))
        reg.remove(id: id)
        XCTAssertTrue(reg.peers.isEmpty)
    }

    func testPeersSortedByName() {
        let reg = PeerRegistry()
        reg.upsert(makePeer(name: "Charlie"))
        reg.upsert(makePeer(name: "alice"))
        reg.upsert(makePeer(name: "Bob"))
        XCTAssertEqual(reg.peers.map(\.name), ["alice", "Bob", "Charlie"])
    }
}
