import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Thin wrapper over `mach_absolute_time` that converts between mach host
/// ticks and nanoseconds.
///
/// Used everywhere we need to talk about *monotonic* time:
///   - `nowNanos()` stamps outgoing audio packets + time-sync probes.
///   - `hostTicks(fromNanos:)` converts a local play-time back into the
///     units `AVAudioTime(hostTime:)` wants, so the audio engine can
///     render the buffer at an exact sample-accurate instant.
///
/// Because mach_absolute_time is per-CPU-timebase (rare on Apple Silicon
/// but possible on Intel), we cache the timebase once at load.
public enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return tb
    }()

    /// Current monotonic time on this device, in nanoseconds.
    public static func nowNanos() -> UInt64 {
        let ticks = mach_absolute_time()
        // ticks * numer / denom → nanoseconds.
        return ticks &* UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    /// Convert a nanosecond timestamp (in *this device's* monotonic clock)
    /// into mach host ticks suitable for `AVAudioTime(hostTime:)`.
    public static func hostTicks(fromNanos nanos: UInt64) -> UInt64 {
        return nanos &* UInt64(timebase.denom) / UInt64(timebase.numer)
    }
}
