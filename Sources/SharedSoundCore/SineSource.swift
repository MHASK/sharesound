import Foundation

/// Test signal generator. Produces interleaved Float32 stereo PCM at
/// `AudioFormat.sampleRate`, one frame's worth of samples per call.
/// Used in M2 to validate the transport before we wire real audio capture.
public final class SineSource {
    private let frequency: Double
    private let amplitude: Float
    private var phase: Double = 0

    public init(frequency: Double = 440.0, amplitude: Float = 0.2) {
        self.frequency = frequency
        self.amplitude = amplitude
    }

    /// Generates one `AudioFormat.samplesPerFrame`-sized stereo block.
    public func nextFrame() -> Data {
        let n = AudioFormat.samplesPerFrame
        let channels = Int(AudioFormat.channelCount)
        var samples = [Float](repeating: 0, count: n * channels)

        let increment = 2.0 * .pi * frequency / AudioFormat.sampleRate
        for i in 0..<n {
            let s = Float(sin(phase)) * amplitude
            samples[i * channels]     = s
            samples[i * channels + 1] = s
            phase += increment
            if phase > 2.0 * .pi { phase -= 2.0 * .pi }
        }
        return samples.withUnsafeBufferPointer { buf in
            Data(buffer: buf)
        }
    }
}
