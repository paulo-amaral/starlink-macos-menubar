import Foundation

/// Whether an address belongs to SpaceX's network (AS14593), to label a speed test as run over
/// Starlink or not (Dishylink issue #71). The prefix list comes from RIPEstat, which is asked only
/// about the AS; the address itself is checked on this Mac.
public struct StarlinkNetwork: Sendable {
    public static let prefixesURL = URL(string: "https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS14593")!

    private let prefixes: [(network: [UInt8], length: Int)]

    public init(ripeStatJSON: Data) throws {
        struct Body: Decodable { struct Inner: Decodable { struct Prefix: Decodable { let prefix: String }; let prefixes: [Prefix] }; let data: Inner }
        prefixes = try JSONDecoder().decode(Body.self, from: ripeStatJSON).data.prefixes.compactMap { entry in
            let parts = entry.prefix.split(separator: "/")
            guard parts.count == 2, let length = Int(parts[1]), let network = Self.bytes(String(parts[0])) else { return nil }
            return (network, length)
        }
    }

    public func contains(_ address: String) -> Bool {
        guard let ip = Self.bytes(address) else { return false }
        return prefixes.contains { prefix in
            guard prefix.network.count == ip.count, prefix.length <= ip.count * 8 else { return false }
            let whole = prefix.length / 8, rest = prefix.length % 8
            guard ip[..<whole] == prefix.network[..<whole] else { return false }
            guard rest > 0 else { return true }
            let mask = UInt8(0xFF) << (8 - rest)
            return ip[whole] & mask == prefix.network[whole] & mask
        }
    }

    /// Downloads the prefix list (about 400 KB) and checks the public address Cloudflare reports for
    /// this Mac. nil when either lookup fails, so the UI says nothing rather than guess.
    public static func isThisMacOnStarlink(session: URLSession = .shared) async -> Bool? {
        guard let address = await publicAddress(session: session),
              let (data, response) = try? await session.data(from: prefixesURL),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let network = try? StarlinkNetwork(ripeStatJSON: data) else { return nil }
        return network.contains(address)
    }

    /// The address Cloudflare's speed-test endpoint saw, from its cf-meta-ip header.
    static func publicAddress(session: URLSession) async -> String? {
        guard let (_, response) = try? await session.data(from: URL(string: "https://speed.cloudflare.com/__down?bytes=0")!) else { return nil }
        return (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "cf-meta-ip")
    }

    static func bytes(_ address: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }
}
