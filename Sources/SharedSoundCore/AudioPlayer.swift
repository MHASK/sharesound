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
        self.format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioFormat.sampleRate,
            channels: AudioFormat.channelCount,
            interleaved: true
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
        // Interleaved Float32 stereo → channelData[0] points at the
        // interleaved block of length frameCount * channelCount.
        guard let dst = buffer.floatChannelData?[0] else { return }
        packet.pcm.withUnsafeBytes { raw in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            let count = Int(frameCapacity) * Int(AudioFormat.channelCount)
            dst.update(from: src, count: count)
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
    }
}
