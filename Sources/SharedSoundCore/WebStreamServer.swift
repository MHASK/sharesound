import Foundation
import Network
import os

private let log = Logger(subsystem: "dev.sharesound", category: "web")

/// Tiny zero-dependency HTTP server that lets any device with a browser join
/// a SharedSound session — no Mac required, no app install. Two endpoints:
///
///   GET /         → an HTML page that auto-plays /stream via `<audio>`
///   GET /stream   → an "infinite" 48kHz/16-bit/stereo WAV chunked PCM
///                   stream. Browsers, VLC, ffplay, curl all handle this.
///
/// Implementation: a plain TCP listener with a naive HTTP/1.1 request-line
/// parser. Once a client GETs /stream we hold the connection open and write
/// raw little-endian Int16 samples forever. We declare a fake content length
/// in the WAV header (max UInt32) which is the canonical hack for streaming
/// WAV over HTTP and is universally accepted.
public final class WebStreamServer {
    public static let defaultPort: UInt16 = 8080

    private let port: UInt16
    private let queue = DispatchQueue(label: "sharedsound.web")
    private var listener: NWListener?

    /// Connections currently subscribed to /stream. Each tick we encode the
    /// PCM frame as Int16 LE and write it to all of them.
    private var streamSubscribers: [NWConnection] = []
    private let subscribersLock = NSLock()

    public init(port: UInt16 = WebStreamServer.defaultPort) {
        self.port = port
    }

    public func start() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
        listener.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener.stateUpdateHandler = { state in
            log.log("web listener state: \(String(describing: state), privacy: .public)")
        }
        listener.start(queue: queue)
        self.listener = listener
        log.log("web server listening on \(self.port, privacy: .public)")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        subscribersLock.lock()
        let conns = streamSubscribers
        streamSubscribers.removeAll()
        subscribersLock.unlock()
        conns.forEach { $0.cancel() }
    }

    /// Push one wire frame (Float32 interleaved stereo, `samplesPerFrame`
    /// samples per channel) to every web subscriber. Called from
    /// HostSession's tick.
    public func broadcast(_ floatPCM: Data) {
        // Convert Float32 → Int16 LE on the way out.
        let int16Bytes = Self.floatToInt16LE(floatPCM)

        subscribersLock.lock()
        let conns = streamSubscribers
        subscribersLock.unlock()

        for conn in conns {
            conn.send(content: int16Bytes, completion: .contentProcessed { _ in })
        }
    }

    public var subscriberCount: Int {
        subscribersLock.lock(); defer { subscribersLock.unlock() }
        return streamSubscribers.count
    }

    // MARK: - HTTP

    private func handleConnection(_ conn: NWConnection) {
        conn.start(queue: queue)
        // Read up to 4 KB — enough for any sane request line + headers.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                log.log("web read error: \(String(describing: error), privacy: .public)")
                conn.cancel()
                return
            }
            guard let data,
                  let request = String(data: data, encoding: .utf8),
                  let path = self.parseRequestPath(request)
            else {
                self.writeAndClose(conn, status: "400 Bad Request", body: "bad request\n")
                return
            }
            log.log("GET \(path, privacy: .public)")
            switch path {
            case "/":             self.serveHTML(conn)
            case "/stream":       self.serveStream(conn)
            default:              self.writeAndClose(conn, status: "404 Not Found", body: "not found\n")
            }
        }
    }

    private func parseRequestPath(_ request: String) -> String? {
        guard let firstLine = request.split(separator: "\r\n", omittingEmptySubsequences: true).first else {
            return nil
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else { return nil }
        return String(parts[1])
    }

    private func serveHTML(_ conn: NWConnection) {
        let html = Self.htmlPage
        var resp = "HTTP/1.1 200 OK\r\n"
        resp += "Content-Type: text/html; charset=utf-8\r\n"
        resp += "Content-Length: \(html.utf8.count)\r\n"
        resp += "Connection: close\r\n\r\n"
        var data = Data(resp.utf8)
        data.append(Data(html.utf8))
        conn.send(content: data, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func serveStream(_ conn: NWConnection) {
        // Send WAV header + HTTP headers. Then keep the connection open
        // and start mirroring broadcast() into it.
        var resp = "HTTP/1.1 200 OK\r\n"
        resp += "Content-Type: audio/wav\r\n"
        resp += "Cache-Control: no-cache, no-store\r\n"
        resp += "Connection: close\r\n\r\n"
        var data = Data(resp.utf8)
        data.append(Self.wavHeader())

        conn.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil { conn.cancel(); return }
            self.subscribersLock.lock()
            self.streamSubscribers.append(conn)
            self.subscribersLock.unlock()
            log.log("subscriber joined, total=\(self.subscriberCount, privacy: .public)")

            // Detect drop via state callback.
            conn.stateUpdateHandler = { [weak self] state in
                if case .cancelled = state { self?.removeSubscriber(conn) }
                if case .failed = state    { self?.removeSubscriber(conn) }
            }
        })
    }

    private func removeSubscriber(_ conn: NWConnection) {
        subscribersLock.lock()
        streamSubscribers.removeAll { $0 === conn }
        let n = streamSubscribers.count
        subscribersLock.unlock()
        log.log("subscriber left, total=\(n, privacy: .public)")
    }

    private func writeAndClose(_ conn: NWConnection, status: String, body: String) {
        var resp = "HTTP/1.1 \(status)\r\n"
        resp += "Content-Type: text/plain; charset=utf-8\r\n"
        resp += "Content-Length: \(body.utf8.count)\r\n"
        resp += "Connection: close\r\n\r\n"
        resp += body
        conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - WAV header

    /// 44-byte RIFF/WAV header for 48 kHz / 16-bit / stereo PCM, with the
    /// file-size and data-size fields set to "max" so the stream is treated
    /// as effectively infinite.
    private static func wavHeader() -> Data {
        let sampleRate: UInt32 = UInt32(AudioFormat.sampleRate)
        let channels: UInt16 = UInt16(AudioFormat.channelCount)
        let bitsPerSample: UInt16 = 16
        let byteRate: UInt32 = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)
        let infinite: UInt32 = 0xFFFFFFFE

        var d = Data()
        d.append("RIFF".data(using: .ascii)!)
        d.append(le32(infinite))                          // chunkSize
        d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!)
        d.append(le32(16))                                // fmt chunk size
        d.append(le16(1))                                 // format = PCM
        d.append(le16(channels))
        d.append(le32(sampleRate))
        d.append(le32(byteRate))
        d.append(le16(blockAlign))
        d.append(le16(bitsPerSample))
        d.append("data".data(using: .ascii)!)
        d.append(le32(infinite))                          // data chunk size
        return d
    }

    private static func le16(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return withUnsafeBytes(of: &x) { Data($0) }
    }
    private static func le32(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return withUnsafeBytes(of: &x) { Data($0) }
    }

    /// Float32 interleaved → Int16 LE interleaved. Clips on overload.
    private static func floatToInt16LE(_ floatPCM: Data) -> Data {
        let floatCount = floatPCM.count / MemoryLayout<Float>.size
        var ints = [Int16](repeating: 0, count: floatCount)
        floatPCM.withUnsafeBytes { raw in
            guard let src = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            for i in 0..<floatCount {
                let scaled = max(-1.0, min(1.0, src[i])) * 32767.0
                ints[i] = Int16(scaled)
            }
        }
        return ints.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    // MARK: - HTML page

    private static let htmlPage: String = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>SharedSound</title>
      <style>
        :root { color-scheme: dark light; }
        body {
          font-family: -apple-system, system-ui, sans-serif;
          max-width: 480px; margin: 4rem auto; padding: 1rem;
          text-align: center;
        }
        h1 { font-weight: 600; }
        audio { width: 100%; margin-top: 2rem; }
        .hint { opacity: .6; font-size: .9rem; margin-top: 1rem; }
      </style>
    </head>
    <body>
      <h1>🔊 SharedSound</h1>
      <p>You're joining the host's audio stream.</p>
      <audio controls autoplay src="/stream"></audio>
      <p class="hint">Tap play if your browser blocks autoplay.<br>
         Works in any browser, on any device.</p>
    </body>
    </html>
    """
}
