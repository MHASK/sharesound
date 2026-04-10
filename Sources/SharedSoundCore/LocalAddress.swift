import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Returns the local non-loopback IPv4 address (e.g. "192.168.29.166").
/// Used so the host can advertise its own host:port directly in the Bonjour
/// TXT record, bypassing NWConnection's flaky service-endpoint resolution.
public enum LocalAddress {
    public static func ipv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ptr = first as UnsafeMutablePointer<ifaddrs>?
        while let p = ptr {
            defer { ptr = p.pointee.ifa_next }
            let flags = Int32(p.pointee.ifa_flags)
            // Skip down / loopback / point-to-point.
            guard (flags & IFF_UP) == IFF_UP,
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = p.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET)
            else { continue }

            let name = String(cString: p.pointee.ifa_name)
            // Common Wi-Fi / wired interface names on macOS / iOS.
            guard name == "en0" || name == "en1" else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let res = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &host, socklen_t(host.count),
                nil, 0,
                NI_NUMERICHOST
            )
            if res == 0 {
                return String(cString: host)
            }
        }
        return nil
    }
}
