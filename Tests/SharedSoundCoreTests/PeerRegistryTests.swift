import XCTest
@testable import SharedSoundCore

@MainActor
final class PeerRegistryTests: XCTestCase {

    func testUpsertAddsNewPeer() {
        let reg = PeerRegistry()
        let peer = Peer(id: UUID(), name: "Mac", role: .host, serviceName: "svc-1")
        reg.upsert(peer)
        XCTAssertEqual(reg.peers.count, 1)
        XCTAssertEqual(reg.peers.first?.name, "Mac")
    }

    func testUpsertDedupesById() {
        let reg = PeerRegistry()
        let id = UUID()
        reg.upsert(Peer(id: id, name: "Old Name", role: .client, serviceName: "svc-1"))
        reg.upsert(Peer(id: id, name: "New Name", role: .host,   serviceName: "svc-2"))
        XCTAssertEqual(reg.peers.count, 1)
        XCTAssertEqual(reg.peers.first?.name, "New Name")
        XCTAssertEqual(reg.peers.first?.role, .host)
    }

    func testRemoveByServiceName() {
        let reg = PeerRegistry()
        reg.upsert(Peer(id: UUID(), name: "A", role: .client, serviceName: "svc-a"))
        reg.upsert(Peer(id: UUID(), name: "B", role: .client, serviceName: "svc-b"))
        reg.remove(serviceName: "svc-a")
        XCTAssertEqual(reg.peers.count, 1)
        XCTAssertEqual(reg.peers.first?.name, "B")
    }

    func testRemoveById() {
        let reg = PeerRegistry()
        let id = UUID()
        reg.upsert(Peer(id: id, name: "A", role: .client, serviceName: "svc-a"))
        reg.remove(id: id)
        XCTAssertTrue(reg.peers.isEmpty)
    }

    func testPeersSortedByName() {
        let reg = PeerRegistry()
        reg.upsert(Peer(id: UUID(), name: "Charlie", role: .client, serviceName: "c"))
        reg.upsert(Peer(id: UUID(), name: "alice",   role: .client, serviceName: "a"))
        reg.upsert(Peer(id: UUID(), name: "Bob",     role: .client, serviceName: "b"))
        XCTAssertEqual(reg.peers.map(\.name), ["alice", "Bob", "Charlie"])
    }
}
