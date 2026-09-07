import Foundation

/// This Mac's local network address.
///
/// Shown in the setup guide: the most common reason for not connecting is that the phone and the
/// Mac are on DIFFERENT networks. Seeing the two addresses side by side makes that obvious at a
/// glance. Reading the Wi-Fi name requires location permission on macOS; reading the IP does not.
enum NetworkInfo {

    /// E.g. "192.168.1.5", or nil if there is no local network.
    static func localIPv4() -> String? {
        var address: String?
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            let name = String(cString: interface.ifa_name)
            // en0/en1 are Wi-Fi and Ethernet; awdl/llw are peer-to-peer and of no interest to us.
            guard name.hasPrefix("en") else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.ifa_addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let candidate = String(cString: host)
            guard !candidate.hasPrefix("169.254") else { continue }   // link-local, not a real network
            address = candidate
            break
        }
        return address
    }

    /// "192.168.1.5" -> "192.168.1"
    static func subnet(of ip: String?) -> String? {
        guard let ip, let index = ip.lastIndex(of: ".") else { return nil }
        return String(ip[ip.startIndex..<index])
    }
}
