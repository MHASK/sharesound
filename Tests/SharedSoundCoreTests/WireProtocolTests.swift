import XCTest
@testable import SharedSoundCore

final class WireProtocolTests: XCTestCase {

    // MARK: - Control

    func testControlRoundtripHello() throws {
        let id = UUID()
        let msg = ControlMessage.hello(peerID: id, name: "Mac A", audioPort: 55123)
        let data = try ControlFrame.encode(msg)
        var buf = data
        guard let decoded = try ControlFrame.decode(from: &buf) else {
            return XCTFail("decode returned nil")
        }
        XCTAssertTrue(buf.isEmpty)
        guard case let .hello(peerID, name, audioPort) = decoded else {
            return XCTFail("wrong case")
        }
        XCTAssertEqual(peerID, id)
        XCTAssertEqual(name, "Mac A")
        XCTAssertEqual(audioPort, 55123)
    }

    func testControlRoundtripWelcome() throws {
        let id = UUID()
        let data = try ControlFrame.encode(.welcome(hostID: id, name: "Host"))
        var buf = data
        let decoded = try ControlFrame.decode(from: &buf)
        guard case .welcome(let hid, let name) = decoded else {
            return XCTFail()
        }
        XCTAssertEqual(hid, id)
        XCTAssertEqual(name, "Host")
    }

    func testControlPartialFrameReturnsNil() throws {
        let data = try ControlFrame.encode(.bye)
        var partial = data.prefix(2)   // not enough bytes
        XCTAssertNil(try ControlFrame.decode(from: &partial))
    }

    func testControlMultipleFramesInBuffer() throws {
        var buf = Data()
        buf.append(try ControlFrame.encode(.bye))
        buf.append(try ControlFrame.encode(.hello(peerID: UUID(), name: "x", audioPort: 1)))

        let first = try ControlFrame.decode(from: &buf)
        if case .bye = first {} else { XCTFail("first should be bye") }

        let second = try ControlFrame.decode(from: &buf)
        if case .hello = second {} else { XCTFail("second should be hello") }

        XCTAssertTrue(buf.isEmpty)
    }

    // MARK: - Audio

    func testAudioPacketRoundtrip() {
        let pcm = Data(repeating: 0xAB, count: AudioFormat.bytesPerFrame)
        let pkt = AudioPacket(
            sequenceNumber: 42,
            hostTimeNanos: 1_234_567_890,
            sampleCount: UInt16(AudioFormat.samplesPerFrame),
            pcm: pcm
        )
        let wire = pkt.encoded()
        XCTAssertEqual(wire.count, AudioPacket.headerSize + pcm.count)

        guard let decoded = AudioPacket.decode(wire) else {
            return XCTFail("decode failed")
        }
        XCTAssertEqual(decoded.sequenceNumber, 42)
        XCTAssertEqual(decoded.hostTimeNanos, 1_234_567_890)
        XCTAssertEqual(decoded.sampleCount, UInt16(AudioFormat.samplesPerFrame))
        XCTAssertEqual(decoded.pcm, pcm)
    }

    func testAudioPacketRejectsTooShort() {
        XCTAssertNil(AudioPacket.decode(Data([0, 1, 2])))
    }
}
