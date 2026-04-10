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
public final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let format: AVAudioFormat

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
        let frameCapacity = AVAudioFrameCount(packet.sampleCount)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            return
        }
        buffer.frameLength = frameCapacity
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(frameCapacity)
        let channels = Int(AudioFormat.channelCount)

        packet.pcm.withUnsafeBytes { raw in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            // De-interleave [L0,R0,L1,R1,...] into channelData[0]=L, [1]=R.
            for ch in 0..<channels {
                let dst = channelData[ch]
                for i in 0..<frames {
                    dst[i] = src[i * channels + ch]
                }
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
