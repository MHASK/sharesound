import Foundation
import Network
import os

private let log = Logger(subsystem: "dev.sharesound", category: "client")

/// Client-side session.
///
/// Flow:
///   1. Open UDP receiver on an ephemeral port.
///   2. Open TCP control connection to the host's discovered endpoint.
///   3. Send `hello` with our peer id, name, and UDP port.
///   4. Wait for `welcome`; start playback.
///   5. Incoming `AudioPacket`s are fed straight to `AudioPlayer`.
public final class ClientSession {
    public enum State: Sendable {
        case idle
        case connecting
        case connected(hostName: String)
        case failed(String)
        case disconnected
    }

    public var onStateChange: ((State) -> Void)?

    private let peerID: UUID
    private let localName: String
    private let queue = DispatchQueue(label: "sharedsound.client")

    private var control: ControlChannel?
    private var receiver: AudioChannel.Receiver?
    private let player = AudioPlayer()
    private let timeSync = TimeSync()
    private var syncTimer: DispatchSourceTimer?

    /// Target end-to-end latency from capture on host to output on
    /// client, in nanoseconds. Packets that can't be scheduled to land
    /// at least this far in the future are dropped. 80 ms is tight for
    /// music playback while still absorbing typical wifi jitter.
    public static let targetLatencyNanos: UInt64 = 80_000_000

    public init(peerID: UUID, localName: String) {
        self.peerID = peerID
        self.localName = localName
    }

    public func connect(to host: Peer) {
        log.log("connect → \(host.name, privacy: .public) at \(host.host, privacy: .public):\(host.port, privacy: .public)")
        disconnect()
        onStateChange?(.connecting)

        let recv: AudioChannel.Receiver
        do {
            recv = try AudioChannel.Receiver(queue: queue)
        } catch {
            onStateChange?(.failed("audio listener: \(error)"))
            return
        }
        recv.onPacket = { [weak self] pkt in
            self?.handleAudioPacket(pkt)
        }
        recv.start()
        self.receiver = recv

        // The listener needs a moment to bind before we can report its port.
        // Poll briefly; bail if it doesn't come up.
        waitForReceiverPort { [weak self] port in
            guard let self else { return }
            guard let port else {
                self.onStateChange?(.failed("audio listener failed to bind"))
                return
            }
            self.openControl(to: host, audioPort: port)
        }
    }

    public func disconnect() {
        syncTimer?.cancel()
        syncTimer = nil
        timeSync.reset()
        control?.send(.bye)
        control?.close()
        control = nil
        receiver?.stop()
        receiver = nil
        player.stop()
        onStateChange?(.disconnected)
    }

    // MARK: - Audio arrival

    private func handleAudioPacket(_ pkt: AudioPacket) {
        // Until the clock offset has locked, we don't know when to play
        // anything — drop until sync converges. This only affects the
        // first ~400ms after connect.
        guard timeSync.isLocked else { return }

        // Translate the host's capture timestamp into this client's
        // monotonic clock, then add the target latency. That's the wall
        // time at which this buffer's first sample should render.
        let localCaptureNanos = timeSync.localNanos(forHostNanos: pkt.hostTimeNanos)
        let playAtNanos = localCaptureNanos &+ Self.targetLatencyNanos

        // Drop packets that have already missed their slot — the output
        // stage cannot render them even if we tried.
        let now = HostClock.nowNanos()
        guard playAtNanos > now else { return }

        let playAtTicks = HostClock.hostTicks(fromNanos: playAtNanos)
        player.schedule(pkt, atHostTime: playAtTicks)
    }

    // MARK: - Time sync

    private func startTimeSyncLoop(on channel: ControlChannel) {
        syncTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // Fast bootstrap: probes every 80ms until the filter locks (~8
        // samples in < 1s), then taper to 2s for steady-state drift.
        timer.schedule(deadline: .now(), repeating: .milliseconds(80))
        timer.setEventHandler { [weak self, weak channel] in
            guard let self, let channel else { return }
            channel.send(.timeSyncRequest(t0: HostClock.nowNanos()))
            if self.timeSync.isLocked {
                // Slow the cadence once locked — we only need enough
                // samples to track crystal drift (~1 ppm).
                self.syncTimer?.schedule(
                    deadline: .now() + .seconds(2),
                    repeating: .seconds(2)
                )
            }
        }
        timer.resume()
        syncTimer = timer
    }

    // MARK: - Internals

    private func waitForReceiverPort(
        attempts: Int = 20,
        completion: @escaping (UInt16?) -> Void
    ) {
        if let port = receiver?.port, port != 0 {
            completion(port)
            return
        }
        if attempts == 0 {
            completion(nil)
            return
        }
        queue.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            self?.waitForReceiverPort(attempts: attempts - 1, completion: completion)
        }
    }

    private func openControl(to host: Peer, audioPort: UInt16) {
        log.log("opening TCP control to \(host.host, privacy: .public):\(host.port, privacy: .public) audioPort=\(audioPort, privacy: .public)")
        let params = NWParameters.tcp
        params.includePeerToPeer = false
        let conn = NWConnection(
            host: NWEndpoint.Host(host.host),
            port: NWEndpoint.Port(rawValue: host.port) ?? .any,
            using: params
        )
        let channel = ControlChannel(connection: conn, queue: queue)

        channel.onStateChange = { [weak self, weak channel] state in
            guard let self, let channel else { return }
            switch state {
            case .ready:
                channel.send(.hello(peerID: self.peerID, name: self.localName, audioPort: audioPort))
                self.startTimeSyncLoop(on: channel)
            case .failed(let msg):
                self.onStateChange?(.failed(msg))
            case .closed:
                self.onStateChange?(.disconnected)
            case .connecting:
                break
            }
        }
        channel.onMessage = { [weak self] msg in
            guard let self else { return }
            switch msg {
            case .welcome(_, let name):
                do {
                    try self.player.start()
                    self.onStateChange?(.connected(hostName: name))
                } catch {
                    self.onStateChange?(.failed("audio engine: \(error)"))
                }
            case .timeSyncResponse(let t0, let t1, let t2):
                let t3 = HostClock.nowNanos()
                self.timeSync.ingest(t0: t0, t1: t1, t2: t2, t3: t3)
            default:
                break
            }
        }
        channel.start()
        self.control = channel
    }
}
