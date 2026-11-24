import Foundation

public struct RouterStatus: Sendable, Equatable {
    public var popLatencyMs: Float?
    public var popDropRate5m: Float?
    public var deviceId = ""
    public var hardwareVersion = ""
    public var firmware = ""
    public var wanIPv4 = ""
    public var wanIPv6: [String] = []
    public init() {}

    /// 100.64.0.0/10: an address shared by many customers, not reachable from the internet.
    public static func isCarrierGradeNAT(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { UInt8($0) }
        return parts.count == 4 && parts[0] == 100 && (64...127).contains(parts[1])
    }
}

public struct WifiClient: Sendable, Equatable, Identifiable {
    public enum Band: Int, Sendable {
        case unknown = 0, wired, ghz24, ghz5, ghz5High
        public var label: String {
            switch self {
            case .unknown: "--"
            case .wired: "Wired"
            case .ghz24: "2.4 GHz"
            case .ghz5: "5 GHz"
            case .ghz5High: "5 GHz high"
            }
        }
    }
    public enum Role: Int, Sendable { case unknown = 0, client, repeater, controller }

    public var id: String { clientId.map(String.init) ?? "\(mac)|\(ip)" }
    public var clientId: UInt32?
    public var name = ""
    public var givenName = ""
    public var mac = ""
    public var ip = ""
    public var band = Band.unknown
    public var role = Role.unknown
    public var signalDbm: Float?
    public var associatedSeconds: UInt32 = 0
    /// Cumulative per-client totals in megabytes, as the router reports them.
    public var uploadMB: UInt32 = 0
    public var downloadMB: UInt32 = 0
    /// Current activity, rx plus tx 15 s averages. Which direction is which is not
    /// established by Dishylink's source, so it is shown as one combined rate.
    public var throughputMbps: Double = 0
    /// Router byte counters for this association; rx is download, tx is upload
    /// (Dishylink core/throughputTracker.ts). nil when the firmware sends none, e.g. wired clients.
    /// The router's own 15 s averages, kept only as a fallback when counters are missing (wired clients).
    public var downAvgMbps: Double = 0
    public var upAvgMbps: Double = 0
    /// True while the router is blocking this device's internet (a pause set in the Starlink app or StarPulse).
    public var blocked = false
    public var rxBytes: UInt64?
    public var txBytes: UInt64?
    public var displayName: String { givenName.isEmpty ? (name.isEmpty ? "(unnamed)" : name) : givenName }
    public init() {}
}

public enum RouterDecoder {
    enum Request { static let getClients = 3002, getStatus = 1004 }
    enum Response { static let wifiGetClients = 3002, wifiGetStatus = 3004 }

    /// The router's own ping to the point of presence. Read from get_status only: Dishylink warns
    /// that get_ping (1009) reboots the router.
    public static func decodeStatus(response: [UInt8]) throws -> RouterStatus {
        var status = RouterStatus()
        guard let body = try DishDecoder.submessage(Response.wifiGetStatus, in: response) else { return status }
        var reader = ProtoReader(body)
        while let (field, wire) = try reader.nextField() {
            switch (field, wire) {
            case (1015, .fixed32): status.popLatencyMs = try reader.readFloat()
            case (1020, .fixed32): status.popDropRate5m = try reader.readFloat()
            case (1003, .lengthDelimited): status.wanIPv4 = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            case (1017, .lengthDelimited): status.wanIPv6.append(String(decoding: try reader.readLengthDelimited(), as: UTF8.self))
            case (3, .lengthDelimited): // DeviceInfo
                var info = ProtoReader(try reader.readLengthDelimited())
                while let (f, w) = try info.nextField() {
                    guard w == .lengthDelimited else { try info.skip(w); continue }
                    let text = String(decoding: try info.readLengthDelimited(), as: UTF8.self)
                    switch f {
                    case 1: status.deviceId = text
                    case 2: status.hardwareVersion = text
                    case 3: status.firmware = text
                    default: break
                    }
                }
            default: try reader.skip(wire)
            }
        }
        return status
    }

    /// Field numbers from the router's reflection dump (Dishylink schema/router.protoset).
    public static func decodeClients(response: [UInt8]) throws -> [WifiClient] {
        guard let body = try DishDecoder.submessage(Response.wifiGetClients, in: response) else { return [] }
        var reader = ProtoReader(body)
        var clients: [WifiClient] = []
        while let (field, wire) = try reader.nextField() {
            guard field == 1, wire == .lengthDelimited else { try reader.skip(wire); continue }
            clients.append(try decodeClient(try reader.readLengthDelimited()))
        }
        return clients
    }

    private static func decodeClient(_ bytes: [UInt8]) throws -> WifiClient {
        var client = WifiClient()
        var reader = ProtoReader(bytes)
        var rx = (bytes: UInt64?.none, mbps: 0.0), tx = (bytes: UInt64?.none, mbps: 0.0)
        while let (field, wire) = try reader.nextField() {
            switch (field, wire) {
            case (1, .lengthDelimited): client.name = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            case (2, .lengthDelimited): client.mac = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            case (3, .lengthDelimited): client.ip = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            case (4, .fixed32): client.signalDbm = try reader.readFloat()
            case (5, .lengthDelimited): rx = try stats(try reader.readLengthDelimited(), field15s: 18, field1m: 17)
            case (6, .lengthDelimited): tx = try stats(try reader.readLengthDelimited(), field15s: 13, field1m: nil)
            case (7, .varint): client.associatedSeconds = UInt32(truncatingIfNeeded: try reader.readVarint())
            case (9, .varint): client.band = .init(rawValue: try reader.readInt()) ?? .unknown
            case (14, .varint): client.role = .init(rawValue: try reader.readInt()) ?? .unknown
            case (31, .lengthDelimited): client.givenName = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            case (42, .varint): client.blocked = try reader.readVarint() != 0
            case (43, .varint): client.clientId = UInt32(truncatingIfNeeded: try reader.readVarint())
            case (54, .varint): client.uploadMB = UInt32(truncatingIfNeeded: try reader.readVarint())
            case (55, .varint): client.downloadMB = UInt32(truncatingIfNeeded: try reader.readVarint())
            default: try reader.skip(wire)
            }
        }
        client.throughputMbps = max(0, rx.mbps + tx.mbps)
        client.downAvgMbps = max(0, rx.mbps)
        client.upAvgMbps = max(0, tx.mbps)
        client.rxBytes = rx.bytes
        client.txBytes = tx.bytes
        return client
    }

    /// Byte counter (field 1) and the router's own average: 15 s preferred, 1 min as fallback, NaN rejected.
    private static func stats(_ bytes: [UInt8], field15s: Int, field1m: Int?) throws -> (bytes: UInt64?, mbps: Double) {
        var reader = ProtoReader(bytes)
        var counter: UInt64?
        var short: Float?, long: Float?
        while let (field, wire) = try reader.nextField() {
            if wire == .varint, field == 1 { counter = try reader.readVarint() }
            else if wire == .fixed32, field == field15s { short = try reader.readFloat() }
            else if wire == .fixed32, field == field1m { long = try reader.readFloat() }
            else { try reader.skip(wire) }
        }
        for value in [short, long] { if let value, value.isFinite { return (counter, Double(value)) } }
        return (counter, 0)
    }
}

/// The router answers on port 9001 of its own address. Dishylink's default is
/// 192.168.1.1; many setups differ, so the host is always supplied by the caller.
public struct RouterAPI: Sendable {
    private let url: URL
    private let transport: HTTPTransport

    public init?(host: String, transport: HTTPTransport = .live) {
        guard let url = URL(string: "http://\(host):9001/SpaceX.API.Device.Device/Handle"), !host.isEmpty else { return nil }
        self.url = url
        self.transport = transport
    }

    public func status() async throws -> RouterStatus {
        try RouterDecoder.decodeStatus(response: try await LocalGrpc.call(url: url, field: RouterDecoder.Request.getStatus, transport: transport))
    }

    /// The raw wifi_get_config reply, for building a client-list write from exactly what the router holds.
    public func rawConfigResponse() async throws -> [UInt8] {
        try await LocalGrpc.call(url: url, field: RouterDecoder.ConfigRequest.wifiGetConfig, transport: transport)
    }

    public func config() async throws -> RouterConfig {
        try RouterDecoder.decodeConfig(response: try await LocalGrpc.call(url: url, field: RouterDecoder.ConfigRequest.wifiGetConfig, transport: transport))
    }

    public func clients() async throws -> [WifiClient] {
        try RouterDecoder.decodeClients(response: try await LocalGrpc.call(url: url, field: RouterDecoder.Request.getClients, transport: transport))
    }
}
