import Foundation
import ScreenCaptureKit
import CoreMedia
import AudioToolbox
import os

private let log = Logger(subsystem: "dev.sharesound", category: "sysaudio")

/// Lossless system-audio capture for macOS via ScreenCaptureKit. Taps the
/// OS audio mixer directly — no mic, no room noise, no resampling beyond
/// what the OS does when the output device runs at a non-48k rate.
///
/// First start() will trigger the Screen Recording TCC prompt. That's the
/// only permission ScreenCaptureKit uses for audio capture — Apple has no
/// separate "system audio" permission.
///
/// Emits `onFrame` with `AudioFormat.samplesPerFrame` interleaved Float32
/// stereo frames, same contract as the old MicSource.
public final class SystemAudioSource: NSObject, @unchecked Sendable {
    /// Called with a full wire frame and the host-capture timestamp (in
    /// the host's monotonic nanosecond clock) of the *first* sample in
    /// the frame.
    public var onFrame: ((Data, UInt64) -> Void)?

    private let queue = DispatchQueue(label: "sharedsound.sysaudio")
    private var stream: SCStream?
    private let output = StreamOutput()

    /// Accumulates interleaved Float32 stereo samples until we have a full
    /// wire frame. Mutated only on `queue`.
    private var frameBuffer = [Float]()

    /// Capture timestamp (ns) of the sample currently sitting at index 0
    /// of `frameBuffer`. Advances by `nsPerSample` each time we emit a
    /// wire frame.
    private var frameBufferStartNanos: UInt64 = 0

    private static let nsPerSample: Double =
        1_000_000_000.0 / Double(AudioFormat.sampleRate)

    public override init() {
        super.init()
        output.owner = self
    }

    public func start() throws {
        // SCStream setup is async. We bridge it through a semaphore so the
        // existing HostSession.startPlaying() stays synchronous.
        var startError: Error?
        let sem = DispatchSemaphore(value: 0)
        Task { [weak self] in
            do {
                try await self?.startAsync()
            } catch {
                startError = error
            }
            sem.signal()
        }
        sem.wait()
        if let startError { throw startError }
    }

    public func stop() {
        stream?.stopCapture { _ in }
        stream = nil
        queue.async { [weak self] in self?.frameBuffer.removeAll() }
    }

    private func startAsync() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudioSource", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "no display available for SCStream"])
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(AudioFormat.sampleRate)
        config.channelCount = Int(AudioFormat.channelCount)
        config.excludesCurrentProcessAudio = true
        // A video track is always captured; set it tiny and slow so it
        // costs ~nothing. We don't add a screen-output consumer.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6

        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .audio,
                                   sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        log.log("SCStream audio capture started")
    }

    // Called on `queue`.
    fileprivate func handleAudioSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        // PTS of the first sample in *this* chunk, in the host clock's
        // nanosecond domain. CMClock.hostTimeClock is mach_absolute_time
        // expressed as seconds, so CMTimeGetSeconds · 1e9 gives us a
        // directly-comparable `HostClock.nowNanos()` value.
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let chunkStartNanos: UInt64
        if pts.isValid && !pts.isIndefinite {
            chunkStartNanos = UInt64(max(0, CMTimeGetSeconds(pts) * 1_000_000_000))
        } else {
            chunkStartNanos = HostClock.nowNanos()
        }
        // If the frame buffer is currently empty, anchor its start time
        // to the new chunk. Otherwise we keep the existing anchor and
        // trust that incoming chunks are contiguous (SCStream is).
        if frameBuffer.isEmpty {
            frameBufferStartNanos = chunkStartNanos
        }

        var blockBuffer: CMBlockBuffer?
        var ablSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &ablSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard ablSize > 0 else { return }

        let ablPtr = UnsafeMutableRawPointer.allocate(
            byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { ablPtr.deallocate() }
        let ablTyped = ablPtr.assumingMemoryBound(to: AudioBufferList.self)

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablTyped,
            bufferListSize: ablSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else { return }

        let list = UnsafeMutableAudioBufferListPointer(ablTyped)
        let channels = Int(AudioFormat.channelCount)

        if list.count == channels {
            // Non-interleaved / planar: one AudioBuffer per channel.
            let frames = Int(list[0].mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { return }
            var srcs: [UnsafePointer<Float>] = []
            srcs.reserveCapacity(channels)
            for ch in 0..<channels {
                guard let raw = list[ch].mData else { return }
                srcs.append(raw.assumingMemoryBound(to: Float.self))
            }
            frameBuffer.reserveCapacity(frameBuffer.count + frames * channels)
            for i in 0..<frames {
                for ch in 0..<channels {
                    frameBuffer.append(srcs[ch][i])
                }
            }
        } else if list.count == 1 {
            // Interleaved.
            let buf = list[0]
            let totalSamples = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            guard totalSamples > 0, let raw = buf.mData else { return }
            let src = raw.assumingMemoryBound(to: Float.self)
            frameBuffer.append(contentsOf: UnsafeBufferPointer(start: src, count: totalSamples))
        } else {
            return
        }

        emitWholeFrames()
    }

    private func emitWholeFrames() {
        let samplesPerWireFrame = AudioFormat.samplesPerFrame * Int(AudioFormat.channelCount)
        let nsPerFrame = UInt64(Double(AudioFormat.samplesPerFrame) * Self.nsPerSample)
        while frameBuffer.count >= samplesPerWireFrame {
            let chunk = Array(frameBuffer.prefix(samplesPerWireFrame))
            frameBuffer.removeFirst(samplesPerWireFrame)
            let data = chunk.withUnsafeBufferPointer { Data(buffer: $0) }
            let captureNanos = frameBufferStartNanos
            frameBufferStartNanos &+= nsPerFrame
            onFrame?(data, captureNanos)
        }
    }
}

/// SCStreamOutput / SCStreamDelegate lives on its own object so the public
/// class doesn't have to inherit NSObject conformance warnings in Swift 6.
private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var owner: SystemAudioSource?

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid else { return }
        owner?.handleAudioSampleBuffer(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log.log("SCStream stopped: \(String(describing: error), privacy: .public)")
    }
}
