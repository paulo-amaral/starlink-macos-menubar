import Darwin
import Foundation

/// DNS filtering services the router can use. Addresses from each provider's official page
/// (checked 2026-11-24); the router takes at most four, so two IPv4 and two IPv6 each.
public enum DnsPreset: String, Codable, Sendable, CaseIterable, Identifiable {
    case cloudflareFamilies, cloudflareMalware, quad9, dnsforgeNormal, dnsforgeClean, dnsforgeHard

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .cloudflareFamilies: "Cloudflare for Families"
        case .cloudflareMalware: "Cloudflare Malware"
        case .quad9: "Quad9"
        case .dnsforgeNormal: "dnsforge Normal"
        case .dnsforgeClean: "dnsforge Clean"
        case .dnsforgeHard: "dnsforge Hard"
        }
    }

    public var blocks: String {
        switch self {
        case .cloudflareFamilies: "Malware, phishing and adult content"
        case .cloudflareMalware: "Malware and phishing"
        case .quad9: "Malware only"
        case .dnsforgeNormal: "Ads, trackers and malware"
        case .dnsforgeClean: "Ads, trackers, malware, adult content and gambling, with SafeSearch"
        case .dnsforgeHard: "Strict lists with no exceptions; some sites may break"
        }
    }

    public var servers: [String] {
        switch self {
        case .cloudflareFamilies: ["1.1.1.3", "1.0.0.3", "2606:4700:4700::1113", "2606:4700:4700::1003"]
        case .cloudflareMalware: ["1.1.1.2", "1.0.0.2", "2606:4700:4700::1112", "2606:4700:4700::1002"]
        case .quad9: ["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"]
        case .dnsforgeNormal: ["49.12.67.122", "91.99.154.175", "2a01:4f8:c013:29d::122", "2a01:4f8:c010:8c35::175"]
        case .dnsforgeClean: ["49.12.223.2", "49.12.43.208", "2a01:4f8:c17:4fbc::2", "2a01:4f8:c012:ed89::208"]
        case .dnsforgeHard: ["49.12.222.213", "88.198.122.154", "2a01:4f8:c17:2c61::213", "2a01:4f8:c013:5ec0::154"]
        }
    }

    /// The preset a router's list belongs to, regardless of order or letter case.
    public static func matching(_ nameservers: [String]) -> DnsPreset? {
        let current = Set(nameservers.map { normalized($0) })
        return allCases.first { Set($0.servers.map(normalized)) == current }
    }

    static func normalized(_ address: String) -> String {
        var v6 = in6_addr()
        if inet_pton(AF_INET6, address, &v6) == 1 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &v6, &buffer, socklen_t(buffer.count))
            return String(cString: buffer)
        }
        return address.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

public enum DnsWrite {
    static let maxServers = 4

    static func isAddress(_ text: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, text, &v4) == 1 || inet_pton(AF_INET6, text, &v6) == 1
    }

    /// Request{target_id 13, wifi_set_config 3001{wifi_config 1{nameservers 30..., apply_nameservers 1054}}}.
    /// Only the DNS list is sent, as Dishylink core/routerConfigUpdate.ts does (MIT).
    public static func request(targetId: String, nameservers: [String]) throws -> [UInt8] {
        guard targetId.hasPrefix("Router-") else { throw PauseError.invalidTarget }
        guard (1...maxServers).contains(nameservers.count), nameservers.allSatisfy(isAddress) else {
            throw PauseError.unsafeRequest("the DNS list is not one to four valid addresses")
        }
        return body(targetId: targetId, nameservers: nameservers)
    }

    /// Back to the router's default DNS: the apply flag with no servers. Separate from `request`,
    /// so an empty list can never be sent by accident.
    public static func clear(targetId: String) throws -> [UInt8] {
        guard targetId.hasPrefix("Router-") else { throw PauseError.invalidTarget }
        return body(targetId: targetId, nameservers: [])
    }

    private static func body(targetId: String, nameservers: [String]) -> [UInt8] {
        var request = ProtoWriter()
        request.writeString(13, targetId)
        request.writeMessage(3001) { set in
            set.writeMessage(1) { wifi in
                for server in nameservers { wifi.writeString(30, server) }
                wifi.writeBool(1054, true)
            }
        }
        return request.bytes
    }
}

/// The Starlink app's Content Filtering (Settings › Router). Per Starlink's help center it sets
/// Cloudflare for Families DNS on the router; No Filtering leaves the router's default.
public enum ContentFilter: String, CaseIterable, Sendable {
    case none, malware, malwareAndAdult

    public var title: String {
        switch self {
        case .none: "No filtering"
        case .malware: "Malware"
        case .malwareAndAdult: "Malware and adult content"
        }
    }

    /// Compact name for the menu bar.
    public var shortTitle: String {
        switch self {
        case .none: "Off"
        case .malware: "Malware"
        case .malwareAndAdult: "Adult + malware"
        }
    }

    /// The Starlink app's own wording.
    public var detail: String? {
        switch self {
        case .none: nil
        case .malware: "Filter known malicious content."
        case .malwareAndAdult: "Filter known adult or malicious content."
        }
    }

    public static let helpURL = URL(string: "https://starlink.com/support/article/1542bce8-8fa4-158f-5880-2dd366dec075")!

    public var preset: DnsPreset? {
        switch self {
        case .none: nil
        case .malware: .cloudflareMalware
        case .malwareAndAdult: .cloudflareFamilies
        }
    }

    /// nil when the router uses DNS servers set some other way.
    public static func current(_ nameservers: [String]) -> ContentFilter? {
        if nameservers.isEmpty { return ContentFilter.none }
        return allCases.first { $0.preset.map { DnsPreset.matching(nameservers) == $0 } ?? false }
    }
}

extension DeviceRule.Kind {
    public var isDns: Bool { if case .dnsProfile = self { true } else { false } }
}

public enum DnsPlanner {
    /// The preset the router should use now: the first DNS rule whose window is open, else the home default.
    public static func desired(rules: [DeviceRule], base: DnsPreset, now: Date, calendar: Calendar = .current) -> DnsPreset {
        for rule in rules where rule.autoPause {
            if case let .dnsProfile(preset, weekdays, start, end) = rule.kind,
               RuleEngine.window(weekdays: weekdays, start: start, end: end, now: now, calendar: calendar).open {
                return preset
            }
        }
        return base
    }

    /// Whether StarPulse may change the router's DNS: only when the current list is one it knows,
    /// so a DNS someone set by hand in the Starlink app is never overwritten.
    public static func mayManage(current: [String]) -> Bool { DnsPreset.matching(current) != nil }
}
