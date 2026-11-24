import Foundation

public struct DishConfig: Sendable, Equatable {
    public enum SnowMelt: Int, Sendable { case automatic = 0, alwaysOn, alwaysOff
        public var label: String { switch self { case .automatic: "Automatic"; case .alwaysOn: "Always on"; case .alwaysOff: "Off" } }
    }
    public var snowMelt = SnowMelt.automatic
    public var sleepEnabled = false
    /// Minutes after midnight UTC, as the dish stores them.
    public var sleepStartUTCMinutes = 0
    public var sleepDurationMinutes = 0
    /// Hour written to swupdate_reboot_hour; the dish treats it as a six hour window.
    public var updateRebootHour = 3
    public var deferUpdates = false
    public init() {}
}

/// Firmware-update windows exactly as the official app offers them (Dishylink
/// src/components/settings/updateWindow.ts, MIT): four six hour windows, each named by its middle hour.
public struct UpdateWindow: Sendable, Equatable {
    public var hour: Int
    public var label: String
    public var range: String
    public static let all = [
        UpdateWindow(hour: 3, label: "Overnight, around 3 AM", range: "Between 12 AM and 6 AM"),
        UpdateWindow(hour: 9, label: "Morning, around 9 AM", range: "Between 6 AM and 12 PM"),
        UpdateWindow(hour: 15, label: "Afternoon, around 3 PM", range: "Between 12 PM and 6 PM"),
        UpdateWindow(hour: 21, label: "Evening, around 9 PM", range: "Between 6 PM and 12 AM"),
    ]
    /// An off-grid hour is shown as the window it falls in, as the official app does.
    public static func containing(hour: Int) -> UpdateWindow { all[max(0, min(3, hour / 6))] }
}

public enum SleepSchedule {
    /// The dish stores the sleep window in UTC; people read it in their own clock.
    public static func localMinutes(fromUTC utcMinutes: Int, in zone: TimeZone = .current, on date: Date = Date()) -> Int {
        let offsetMinutes = zone.secondsFromGMT(for: date) / 60
        return ((utcMinutes + offsetMinutes) % 1440 + 1440) % 1440
    }
}

public struct RouterNetwork: Sendable, Equatable {
    public var ssid: String
    public var bands: [String]
    public var security: String
    public var hidden: Bool
}

public struct MeshNode: Sendable, Equatable {
    public var name: String
    public var trusted: Bool
    public var hardware: String
}

/// Router settings that are safe to show. Passwords live in the same message and are
/// deliberately never read: only the name, band, security kind and flags are taken.
public struct RouterConfig: Sendable, Equatable {
    public var networks: [RouterNetwork] = []
    public var meshNodes: [MeshNode] = []
    public var country = ""
    public var nameservers: [String] = []
    public var bypassMode = false
    public init() {}
}

extension DishDecoder {
    enum ConfigRequest { static let dishGetConfig = 2011 }
    enum ConfigResponse { static let dishGetConfig = 2011 }

    public static func decodeConfig(response: [UInt8]) throws -> DishConfig {
        var config = DishConfig()
        guard let outer = try submessage(ConfigResponse.dishGetConfig, in: response) else { return config }
        var reader = ProtoReader(outer)
        while let (field, wire) = try reader.nextField() {
            guard field == 1, wire == .lengthDelimited else { try reader.skip(wire); continue }
            var inner = ProtoReader(try reader.readLengthDelimited())
            while let (f, w) = try inner.nextField() {
                switch (f, w) {
                case (1, .varint): config.snowMelt = .init(rawValue: try inner.readInt()) ?? .automatic
                case (4, .varint): config.sleepStartUTCMinutes = try inner.readInt()
                case (5, .varint): config.sleepDurationMinutes = try inner.readInt()
                case (6, .varint): config.sleepEnabled = try inner.readVarint() != 0
                case (7, .varint): config.deferUpdates = try inner.readVarint() != 0
                case (9, .varint): config.updateRebootHour = try inner.readInt()
                default: try inner.skip(w)
                }
            }
        }
        return config
    }
}

extension RouterDecoder {
    enum ConfigRequest { static let wifiGetConfig = 3009 }
    enum ConfigResponse { static let wifiGetConfig = 3009 }

    public static func decodeConfig(response: [UInt8]) throws -> RouterConfig {
        var config = RouterConfig()
        guard let outer = try DishDecoder.submessage(ConfigResponse.wifiGetConfig, in: response) else { return config }
        var reader = ProtoReader(outer)
        while let (field, wire) = try reader.nextField() {
            guard field == 1, wire == .lengthDelimited else { try reader.skip(wire); continue }
            var inner = ProtoReader(try reader.readLengthDelimited())
            var found: [RouterNetwork] = []
            while let (f, w) = try inner.nextField() {
                switch (f, w) {
                case (3, .lengthDelimited): config.country = String(decoding: try inner.readLengthDelimited(), as: UTF8.self)
                case (30, .lengthDelimited): config.nameservers.append(String(decoding: try inner.readLengthDelimited(), as: UTF8.self))
                case (31, .varint): config.bypassMode = try inner.readVarint() != 0
                case (33, .lengthDelimited): if let node = try meshNode(try inner.readLengthDelimited()) { config.meshNodes.append(node) }
                case (1100, .lengthDelimited): collectNetworks(try inner.readLengthDelimited(), depth: 0, into: &found)
                default: try inner.skip(w)
                }
            }
            config.networks = merge(found)
        }
        return config
    }

    private static func meshNode(_ entry: [UInt8]) throws -> MeshNode? {
        var reader = ProtoReader(entry)
        while let (field, wire) = try reader.nextField() {
            guard field == 2, wire == .lengthDelimited else { try reader.skip(wire); continue }
            var node = ProtoReader(try reader.readLengthDelimited())
            var name = "", hardware = "", auth = 0
            while let (f, w) = try node.nextField() {
                switch (f, w) {
                case (1, .lengthDelimited): name = String(decoding: try node.readLengthDelimited(), as: UTF8.self)
                case (3, .varint): auth = try node.readInt()
                case (9, .lengthDelimited): hardware = String(decoding: try node.readLengthDelimited(), as: UTF8.self)
                default: try node.skip(w)
                }
            }
            return MeshNode(name: name, trusted: auth == 2, hardware: hardware)
        }
        return nil
    }

    private static let securityNames = [2001: "Open", 2002: "WPA2", 2003: "WPA3", 2004: "WPA2/WPA3", 2005: "RADIUS", 2006: "Open (encrypted)", 2007: "RADIUS onboarding"]
    private static let bandNames = [2: "2.4 GHz", 5: "5 GHz", 6: "5 GHz high"]

    /// A network entry nests its basic service sets; find every message that carries an SSID (field 1005).
    private static func collectNetworks(_ bytes: [UInt8], depth: Int, into found: inout [RouterNetwork]) {
        guard depth < 4, var probe = Optional(ProtoReader(bytes)) else { return }
        var ssid: String?, band = 0, security = "", hidden = false
        var children: [[UInt8]] = []
        do {
            while let (field, wire) = try probe.nextField() {
                switch (field, wire) {
                case (1005, .lengthDelimited): ssid = String(decoding: try probe.readLengthDelimited(), as: UTF8.self)
                case (1011, .varint): band = try probe.readInt()
                case (1015, .varint): hidden = try probe.readVarint() != 0
                case (let f, .lengthDelimited) where securityNames[f] != nil:
                    security = securityNames[f] ?? ""
                    _ = try probe.readLengthDelimited() // the credential itself is never inspected or kept
                case (_, .lengthDelimited): children.append(try probe.readLengthDelimited())
                default: try probe.skip(wire)
                }
            }
        } catch { return }
        if let ssid, !ssid.isEmpty {
            found.append(RouterNetwork(ssid: ssid, bands: [bandNames[band] ?? "--"], security: security, hidden: hidden))
        } else {
            for child in children { collectNetworks(child, depth: depth + 1, into: &found) }
        }
    }

    /// One row per name, with every band it is broadcast on.
    private static func merge(_ networks: [RouterNetwork]) -> [RouterNetwork] {
        var merged: [RouterNetwork] = []
        for network in networks {
            if let index = merged.firstIndex(where: { $0.ssid == network.ssid }) {
                merged[index].bands = Array(Set(merged[index].bands + network.bands)).sorted()
            } else { merged.append(network) }
        }
        return merged
    }
}
