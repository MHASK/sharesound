import Foundation

/// Wire formats for SharedSound's two channels.
///
/// **Control channel (TCP):** length-prefixed JSON. Reliable, ordered, used
/// for handshake, volume, mute, disconnect. Low volume, so JSON's overhead
/// doesn't matter and the debugging ergonomics are worth it.
///
/// **Audio channel (UDP):** compact fixed header + raw PCM payload. Unreliable
/// by design — a dropped 10ms frame is better than a stalled stream, and M4's
/// jitter buffer will handle reordering.

// MARK: - Control

public enum ControlMessage: Codable, Sendable {
    /// Client → host, first message. Announces who's connecting and on which
    /// UDP port the client is listening for audio.
    case hello(peerID: UUID, name: String, audioPort: UInt16)

    /// Host → client, reply to hello. Confirms session, echoes host id.
    case welcome(hostID: UUID, name: String)

    /// Either side, graceful disconnect.
    case bye

    // Placeholder keyed coding — swap to a discriminator if this grows.
    private enum Kind: String, Codable { case hello, welcome, bye }

    private enum CodingKeys: String, CodingKey {
        case kind, peerID, name, audioPort, hostID
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hello(let peerID, let name, let audioPort):
            try c.encode(Kind.hello, forKey: .kind)
            try c.encode(peerID, forKey: .peerID)
            try c.encode(name, forKey: .name)
            try c.encode(audioPort, forKey: .audioPort)
        case .welcome(let hostID, let name):
            try c.encode(Kind.welcome, forKey: .kind)
            try c.encode(hostID, forKey: .hostID)
            try c.encode(name, forKey: .name)
        case .bye:
            try c.encode(Kind.bye, forKey: .kind)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .hello:
            self = .hello(
                peerID: try c.decode(UUID.self, forKey: .peerID),
                name: try c.decode(String.self, forKey: .name),
                audioPort: try c.decode(UInt16.self, forKey: .audioPort)
            )
        case .welcome:
            self = .welcome(
                hostID: try c.decode(UUID.self, forKey: .hostID),
                name: try c.decode(String.self, forKey: .name)
            )
        case .bye:
            self = .bye
        }
    }
}

/// Encodes / decodes control messages as `length(4 BE) + JSON`.
public enum ControlFrame {
    public static func encode(_ message: ControlMessage) throws -> Data {
        let json = try JSONEncoder().encode(message)
        var out = Data(capacity: 4 + json.count)
        var len = UInt32(json.count).bigEndian
        withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
        out.append(json)
        return out
    }

    /// Attempts to pull one frame off the front of `buffer`. On success,
    /// removes the consumed bytes and returns the decoded message. Returns
    /// nil if not enough bytes have arrived yet.
    public static func decode(from buffer: inout Data) throws -> ControlMessage? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(as: UInt32.self).bigEndian
        }
        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }
        let json = buffer.subdata(in: 4..<total)
        buffer.removeSubrange(0..<total)
        return try JSONDecoder().decode(ControlMessage.self, from: json)
    }
}

// MARK: - Audio

/// UDP audio packet: fixed 14-byte header + interleaved Float32 PCM.
///
/// Header layout (big-endian):
///   offset  size  field
///      0     4    sequenceNumber (UInt32)         — detect loss / reorder
///      4     8    hostTimeNanos  (UInt64)         — reserved for M4 sync
///     12     2    sampleCount    (UInt16)         — samples *per channel*
///
/// Channel count and sample rate are implicit — negotiated at session start,
/// not repeated per packet.
public struct AudioPacket: Sendable {
    public static let headerSize = 14

    public var sequenceNumber: UInt32
    public var hostTimeNanos: UInt64
    public var sampleCount: UInt16
    public var pcm: Data   // interleaved Float32 stereo

    public init(sequenceNumber: UInt32, hostTimeNanos: UInt64, sampleCount: UInt16, pcm: Data) {
        self.sequenceNumber = sequenceNumber
        self.hostTimeNanos = hostTimeNanos
        self.sampleCount = sampleCount
        self.pcm = pcm
    }

    public func encoded() -> Data {
        var out = Data(capacity: Self.headerSize + pcm.count)
        var seqBE = sequenceNumber.bigEndian
        var htBE  = hostTimeNanos.bigEndian
        var scBE  = sampleCount.bigEndian
        withUnsafeBytes(of: &seqBE) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &htBE)  { out.append(contentsOf: $0) }
        withUnsafeBytes(of: &scBE)  { out.append(contentsOf: $0) }
        out.append(pcm)
        return out
    }

    public static func decode(_ data: Data) -> AudioPacket? {
        guard data.count >= headerSize else { return nil }
        let seq = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 0, as: UInt32.self).bigEndian }
        let ht  = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt64.self).bigEndian }
        let sc  = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 12, as: UInt16.self).bigEndian }
        let pcm = data.subdata(in: headerSize..<data.count)
        return AudioPacket(sequenceNumber: seq, hostTimeNanos: ht, sampleCount: sc, pcm: pcm)
    }
}
