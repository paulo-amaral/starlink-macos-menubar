import Darwin
import SystemConfiguration

enum NetworkGateway {
    /// Default IPv4 gateway from the system network state, e.g. "10.0.0.1".
    static func current() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "StarPulse" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return global["Router"] as? String
    }

    /// This Mac's own IPv4 addresses, to recognise it in the router's client list.
    static func localAddresses() -> Set<String> {
        var result = Set<String>()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.insert(String(cString: host))
            }
        }
        return result
    }
}
