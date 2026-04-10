import Foundation

/// Client-side clock synchroniser.
///
/// Tracks the offset `host_clock − client_clock` in nanoseconds using
/// NTP-style four-timestamp probes over the reliable control channel.
///
/// Algorithm per probe:
///
///     t0 : client send       (HostClock.nowNanos on client)
///     t1 : host  receive     (HostClock.nowNanos on host)
///     t2 : host  send        (HostClock.nowNanos on host)
///     t3 : client receive    (HostClock.nowNanos on client)
///
///     rtt    = (t3 − t0) − (t2 − t1)
///     offset = ((t1 − t0) + (t2 − t3)) / 2
///
/// A sample with RTT larger than `rttRejectNanos` is discarded entirely —
/// those are wifi retransmit events that would poison the mean.
///
/// Remaining samples feed an EWMA with a fast-converge bootstrap:
///   * First 8 accepted samples → straight average (rapid lock).
///   * After that → EWMA with α = 0.15 (smooth, responsive to real drift
///     but immune to single-packet jitter).
///
/// Thread safety: instances are confined to a single serial queue by the
/// caller (`ClientSession.queue`).
public final class TimeSync {
    public private(set) var offsetNanos: Int64 = 0
    public private(set) var lastRttNanos: UInt64 = 0
    public private(set) var isLocked: Bool = false

    /// Samples accumulated during bootstrap, before EWMA kicks in.
    private var bootstrap: [Int64] = []

    /// Reject samples whose round-trip exceeds this — wifi retransmits,
    /// GC pauses, scheduler hiccups. 80ms is generous for a LAN.
    private let rttRejectNanos: UInt64 = 80_000_000

    private let bootstrapSize = 8
    private let ewmaAlpha: Double = 0.15

    public init() {}

    /// Feed a four-tuple back from a `timeSyncResponse`. Returns true
    /// if the sample was accepted (within RTT budget), false if rejected.
    @discardableResult
    public func ingest(t0: UInt64, t1: UInt64, t2: UInt64, t3: UInt64) -> Bool {
        // Guard against absurd orderings that could wrap UInt64 math.
        guard t3 >= t0, t2 >= t1 else { return false }
        let rtt = (t3 - t0) - (t2 - t1)
        guard rtt <= rttRejectNanos else { return false }
        lastRttNanos = rtt

        // Signed arithmetic — the offset can go either way.
        let a = Int64(bitPattern: t1) &- Int64(bitPattern: t0)
        let b = Int64(bitPattern: t2) &- Int64(bitPattern: t3)
        let sample = (a &+ b) / 2

        if bootstrap.count < bootstrapSize {
            bootstrap.append(sample)
            offsetNanos = bootstrap.reduce(0, &+) / Int64(bootstrap.count)
            if bootstrap.count == bootstrapSize { isLocked = true }
        } else {
            let prev = Double(offsetNanos)
            let next = Double(sample)
            offsetNanos = Int64(prev + (next - prev) * ewmaAlpha)
        }
        return true
    }

    /// Translate a host-clock timestamp (e.g. from an audio packet) into
    /// the client's local monotonic clock.
    public func localNanos(forHostNanos hostNanos: UInt64) -> UInt64 {
        let signed = Int64(bitPattern: hostNanos) &- offsetNanos
        return signed < 0 ? 0 : UInt64(signed)
    }

    public func reset() {
        offsetNanos = 0
        lastRttNanos = 0
        isLocked = false
        bootstrap.removeAll()
    }
}
