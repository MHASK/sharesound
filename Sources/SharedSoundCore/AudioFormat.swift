import Foundation

/// Canonical audio format used on the wire and by every AVAudioEngine in the
/// system. Keep everyone on the same sample rate / channel layout so no one
/// has to resample — resampling in the hot path is a latency and quality tax.
public enum AudioFormat {
    public static let sampleRate: Double = 48_000
    public static let channelCount: UInt32 = 2
    public static let bytesPerSample: Int = MemoryLayout<Float32>.size

    /// 10ms frames → 480 samples per channel at 48kHz.
    /// Short enough for low latency, long enough that per-packet overhead
    /// stays negligible on the wire.
    public static let samplesPerFrame: Int = 480

    public static let bytesPerFrame: Int =
        samplesPerFrame * Int(channelCount) * bytesPerSample  // 3840 bytes
}
