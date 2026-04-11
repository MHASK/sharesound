import Foundation
import AVFoundation

/// Schedules incoming PCM frames onto an AVAudioPlayerNode.
///
/// Playback is **clock-synchronised**: each buffer is scheduled with an
/// explicit `AVAudioTime(hostTime:)` derived from the host's capture
/// timestamp translated into this client's monotonic clock (see
/// `TimeSync` + `ClientSession.handleAudioPacket`). That gives:
///
///   * fixed end-to-end latency (no queue buildup from clock drift),
///   * sample-accurate multi-device synchronisation (all clients playing
///     the same host sample at the same wall-clock instant),
///   * automatic drop of packets that arrive too late to render.
/// Per-client audio routing. Lets you turn one client into the "left
/// speaker" of a stereo pair across two Macs, the "right speaker", a
/// silent passive, or a normal stereo listener.
public enum ChannelMode: String, Sendable, CaseIterable, Codable {
    /// Pass the host's L/R through unchanged.
    case stereo
    /// Play the host's left channel on BOTH local outputs.
    /// Use on the Mac you want to act as the left speaker.
    case leftChannel
    /// Play the host's right channel on BOTH local outputs.
    /// Use on the Mac you want to act as the right speaker.
    case rightChannel
    /// Drop every buffer. Useful when one machine is the host and the
    /// other is the only listener you want sound from.
    case muted

    public var displayName: String {
        switch self {
        case .stereo:       return "Stereo"
        case .leftChannel:  return "Left only"
        case .rightChannel: return "Right only"
        case .muted:        return "Muted"
        }
    }
}

public final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

    /// Routing mode applied at de-interleave time. Cheap to flip — the
    /// next packet picks up the new value. Default is straight stereo.
    public var channelMode: ChannelMode = .stereo

    public init() {
        // AVAudioEngine.mainMixerNode rejects interleaved input formats and
        // raises an NSException at connect time. Use a non-interleaved
        // (planar) format here even though the wire protocol carries
        // interleaved samples — we de-interleave in `schedule(_:)`.
        self.format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.sampleRate,
            channels: AudioFormat.channelCount,
            interleaved: false
        )!
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
    }

    public func start() throws {
        try engine.start()
        player.play()
    }

    public func stop() {
        player.stop()
        engine.stop()
    }

    /// Schedule a packet to render at the given mach host-time (ticks in
    /// this device's monotonic clock). The caller is responsible for
    /// computing the play-time via `TimeSync`. If `atHostTime` is nil,
    /// the buffer is enqueued immediately (legacy/free-running mode —
    /// only used by tests).
    public func schedule(_ packet: AudioPacket, atHostTime: UInt64? = nil) {
        // Muted: drop the buffer entirely. Saves CPU and the engine
        // simply renders silence until the next non-muted packet lands.
        if channelMode == .muted { return }

        let frameCapacity = AVAudioFrameCount(packet.sampleCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return
        }
        buffer.frameLength = frameCapacity
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(frameCapacity)
        let channels = Int(AudioFormat.channelCount)
        let mode = channelMode

        packet.pcm.withUnsafeBytes { raw in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            switch mode {
            case .stereo:
                // De-interleave [L0,R0,L1,R1,...] → planar L / R.
                for ch in 0..<channels {
                    let dst = channelData[ch]
                    for i in 0..<frames {
                        dst[i] = src[i * channels + ch]
                    }
                }
            case .leftChannel:
                // Host L → both local outputs (mono from L source).
                let dstL = channelData[0]
                let dstR = channels > 1 ? channelData[1] : channelData[0]
                for i in 0..<frames {
                    let v = src[i * channels + 0]
                    dstL[i] = v
                    dstR[i] = v
                }
            case .rightChannel:
                // Host R → both local outputs (mono from R source).
                let dstL = channelData[0]
                let dstR = channels > 1 ? channelData[1] : channelData[0]
                let rIdx = channels > 1 ? 1 : 0
                for i in 0..<frames {
                    let v = src[i * channels + rIdx]
                    dstL[i] = v
                    dstR[i] = v
                }
            case .muted:
                break   // unreachable, returned above
            }
        }

        if let ticks = atHostTime {
            let when = AVAudioTime(hostTime: ticks)
            player.scheduleBuffer(buffer, at: when, options: [], completionHandler: nil)
        } else {
            player.scheduleBuffer(buffer, completionHandler: nil)
        }
    }
}
