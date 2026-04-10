import Foundation
import AVFoundation

/// Schedules incoming PCM frames onto an AVAudioPlayerNode.
///
/// M2 version: no jitter buffer, no clock sync. Packets are scheduled the
/// moment they arrive. Expect pops under wifi jitter — M4 fixes this with a
/// proper buffer and scheduled host-time playback.
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

    public func schedule(_ packet: AudioPacket) {
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
        player.scheduleBuffer(buffer, completionHandler: nil)
    }
}
