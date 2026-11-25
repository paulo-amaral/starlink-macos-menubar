import Darwin
import StarPulseCore
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
    static func localAddresses() -> Set<String> { Set(interfaces().map(\.address)) }

    /// This Mac's IPv4 interfaces with their addresses.
    static func interfaces() -> [DishDiagnosis.LocalInterface] {
        var result: [DishDiagnosis.LocalInterface] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return result }
        defer { freeifaddrs(list) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr, address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(.init(name: String(cString: entry.pointee.ifa_name), address: String(cString: host)))
            }
        }
        return result
    }

    /// The interface the kernel would use to reach `host`. Connecting a UDP socket only picks the
    /// route and source address; no packet is sent.
    static func routeInterface(toward host: String) -> String? {
        var target = sockaddr_in()
        target.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = in_port_t(9201).bigEndian
        guard inet_pton(AF_INET, host, &target.sin_addr) == 1 else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &target) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return nil }
        var source = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &source, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }) == 0
        else { return nil }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &source.sin_addr, &text, socklen_t(text.count)) != nil else { return nil }
        let address = String(cString: text)
        return interfaces().first { $0.address == address }?.name
    }
}
