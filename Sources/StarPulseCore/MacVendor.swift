import Foundation

/// Device manufacturer from the IEEE OUI registry, as compiled by Dishylink (public/oui.json, MIT).
/// A MAC with the locally administered bit set is a randomized "private" address: phones and
/// laptops use them on purpose, so no manufacturer can be named.
public enum MacVendor {
    private static let table: [String: String] = {
        // Bundle.main first: see Theme.registerFonts for why the packaged app cannot rely on Bundle.module.
        guard let url = Bundle.main.url(forResource: "oui", withExtension: "json")
                ?? Bundle.module.url(forResource: "oui", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let table = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return table
    }()

    public static func isPrivate(_ mac: String) -> Bool {
        guard let first = mac.split(separator: ":").first, let octet = UInt8(first, radix: 16) else { return false }
        return octet & 0x02 != 0
    }

    /// "Private", the manufacturer name, or nil when the address is not in the registry.
    public static func label(for mac: String) -> String? {
        if isPrivate(mac) { return "Private" }
        let octets = mac.lowercased().split(separator: ":").prefix(3).map { $0.count == 1 ? "0\($0)" : String($0) }
        guard octets.count == 3 else { return nil }
        return table[octets.joined()]
    }
}
