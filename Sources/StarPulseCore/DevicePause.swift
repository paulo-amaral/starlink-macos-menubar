import Foundation

public enum PauseError: Error, Equatable, LocalizedError {
    case unknownClient
    case invalidTarget
    case unsafeRequest(String)
    case noController

    public var errorDescription: String? {
        switch self {
        case .unknownClient: "The router does not list this device right now."
        case .invalidTarget: "The router to change could not be identified."
        case .unsafeRequest(let reason): "The change was not sent because it would have altered more than this device (\(reason))."
        case .noController: "Starlink has not reported your router yet. Try again once it checks in."
        }
    }
}

/// Builds the router write that pauses or resumes one device, after Dishylink core/routerClientUpdate.ts (MIT).
/// The router only accepts the WHOLE client list, so every other device's entry is resent byte for byte as the
/// router served it, and only the chosen client's "_permanent" block schedule is added or removed.
public enum DevicePause {
    static let permanentGroup = "_permanent"
    static let weekMinutes: UInt64 = 7 * 24 * 60

    enum Field {
        static let targetId = 13, wifiSetConfig = 3001, wifiConfig = 1, clientConfigs = 74, applyClientConfigs = 1089
        static let clientId = 1, macAddress = 2, schedules = 5
        static let scheduleRanges = 1, scheduleGroup = 2, rangeEnd = 2
    }

    /// The raw client config entries (WifiConfig.client_configs) from a LAN wifi_get_config reply.
    public static func rawClientConfigs(configResponse: [UInt8]) throws -> [[UInt8]] {
        guard let outer = try DishDecoder.submessage(RouterDecoder.ConfigResponse.wifiGetConfig, in: configResponse),
              let wifiConfig = try DishDecoder.submessage(1, in: outer) else { return [] }
        return try ProtoReader.rawFields(wifiConfig).filter { $0.number == Field.clientConfigs && $0.wire == .lengthDelimited }
            .map { field in var reader = field.reader; return try reader.readLengthDelimited() }
    }

    static func clientId(of config: [UInt8]) throws -> UInt32? {
        for field in try ProtoReader.rawFields(config) where field.number == Field.clientId && field.wire == .varint {
            var reader = field.reader
            return UInt32(truncatingIfNeeded: try reader.readVarint())
        }
        return nil
    }

    static func isPermanentSchedule(_ schedule: [UInt8]) throws -> Bool {
        for field in try ProtoReader.rawFields(schedule) where field.number == Field.scheduleGroup && field.wire == .lengthDelimited {
            var reader = field.reader
            return String(decoding: try reader.readLengthDelimited(), as: UTF8.self) == permanentGroup
        }
        return false
    }

    static func permanentSchedule() -> [UInt8] {
        var schedule = ProtoWriter()
        schedule.writeMessage(Field.scheduleRanges) { $0.writeVarint(Field.rangeEnd, weekMinutes) } // start 0 is the proto3 default
        schedule.writeString(Field.scheduleGroup, permanentGroup)
        return schedule.bytes
    }

    /// One client's entry with its "_permanent" schedule removed, and added back when pausing. Every other field stays as it was.
    static func edit(_ config: [UInt8], paused: Bool) throws -> [UInt8] {
        var writer = ProtoWriter()
        for field in try ProtoReader.rawFields(config) {
            if field.number == Field.schedules, field.wire == .lengthDelimited {
                var reader = field.reader
                if try isPermanentSchedule(try reader.readLengthDelimited()) { continue }
            }
            writer.writeRaw(field.raw)
        }
        if paused { writer.writeBytes(Field.schedules, permanentSchedule()) }
        return writer.bytes
    }

    /// The full Device/Handle request for the cloud gateway.
    public static func request(targetId: String, existing: [[UInt8]], clientId: UInt32, macAddress: String, paused: Bool) throws -> [UInt8] {
        guard targetId.hasPrefix("Router-") else { throw PauseError.invalidTarget }
        var configs: [[UInt8]] = []
        var found = false
        for config in existing {
            if try Self.clientId(of: config) == clientId {
                found = true
                configs.append(try edit(config, paused: paused))
            } else {
                configs.append(config)
            }
        }
        if !found {
            // A device the router lists live but has no entry for yet gets one, keyed by clientId:
            // this firmware masks MACs, and a MAC-keyed write once renamed four devices at once.
            guard !macAddress.isEmpty else { throw PauseError.unknownClient }
            var entry = ProtoWriter()
            entry.writeVarint(Field.clientId, UInt64(clientId))
            entry.writeString(Field.macAddress, macAddress)
            configs.append(try edit(entry.bytes, paused: paused))
        }
        try verify(original: existing, updated: configs, clientId: clientId)
        var request = ProtoWriter()
        request.writeString(Field.targetId, targetId)
        request.writeMessage(Field.wifiSetConfig) { set in
            set.writeMessage(Field.wifiConfig) { wifi in
                for config in configs { wifi.writeBytes(Field.clientConfigs, config) }
                wifi.writeBool(Field.applyClientConfigs, true)
            }
        }
        return request.bytes
    }

    /// Refuses to send unless every other device's entry is byte-identical and the chosen one differs only in its "_permanent" schedule.
    static func verify(original: [[UInt8]], updated: [[UInt8]], clientId: UInt32) throws {
        let others = try original.filter { try Self.clientId(of: $0) != clientId }
        let updatedOthers = try updated.filter { try Self.clientId(of: $0) != clientId }
        guard others == updatedOthers else { throw PauseError.unsafeRequest("another device's entry changed") }
        guard try updated.filter({ try Self.clientId(of: $0) == clientId }).count == 1 else { throw PauseError.unsafeRequest("the device appears more than once") }
        if let before = try original.first(where: { try Self.clientId(of: $0) == clientId }),
           let after = try updated.first(where: { try Self.clientId(of: $0) == clientId }) {
            guard try edit(before, paused: false) == edit(after, paused: false) else { throw PauseError.unsafeRequest("fields other than the pause changed") }
        }
    }
}

extension StarlinkCloud {
    /// The router to change: the one zero hops from the controller in the account's telemetry
    /// (Dishylink cloud/starlinkCloudHandler.ts). Never cached, because a write must not act on a stale answer.
    public func controllerRouterId() async throws -> String {
        let account = try await account()
        guard let accountNumber = account.accountReference else { throw CloudError.noServiceLine }
        let cookie = try await sessionCookie()
        var request = URLRequest(url: URL(string: Self.apiBase + "/device-data/cache/v1/telemetry")!)
        request.httpMethod = "POST"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["accountNumber": accountNumber])
        let data = try await sendChecked(request, label: "telemetry")
        guard let id = Self.controllerId(fromTelemetry: try JSONSerialization.jsonObject(with: data)) else { throw PauseError.noController }
        return id
    }

    static func controllerId(fromTelemetry telemetry: Any) -> String? {
        guard let data = (telemetry as? [String: Any])?["data"] as? [String: Any],
              let legends = data["columnNamesByDeviceType"] as? [String: [String]],
              let rows = data["values"] as? [[Any]], let legend = legends["r"],
              let idColumn = legend.firstIndex(of: "DeviceId") else { return nil }
        let hopsColumn = legend.firstIndex(of: "WifiHopsFromController")
        let routers: [(id: String, hops: Double?)] = rows.compactMap { row in
            guard row.first as? String == "r", row.indices.contains(idColumn), let id = row[idColumn] as? String, !id.isEmpty else { return nil }
            let hops = hopsColumn.flatMap { row.indices.contains($0) ? (row[$0] as? NSNumber)?.doubleValue : nil }
            return (id, hops)
        }
        // A write is about to happen, so a lone router is taken as the controller, as Dishylink does.
        return routers.first(where: { $0.hops == 0 })?.id ?? (routers.count == 1 ? routers[0].id : nil)
    }

    /// Sends a Device/Handle request through Starlink's authenticated grpc-web gateway.
    public func sendDeviceRequest(_ body: [UInt8]) async throws {
        let cookie = try await sessionCookie()
        var request = URLRequest(url: URL(string: Self.apiBase + "/SpaceX.API.Device.Device/Handle")!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue("application/grpc-web+proto", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "X-Grpc-Web")
        request.httpBody = GrpcWeb.encodeFrame(body)
        let (data, response) = try await transportSend(request)
        if response.statusCode == 401 || response.statusCode == 403 { throw CloudError.sessionExpired }
        let headerStatus = response.value(forHTTPHeaderField: "grpc-status").flatMap(Int.init)
        do {
            _ = try GrpcWeb.decodeResponse(body: data, headerStatus: headerStatus, headerMessage: response.value(forHTTPHeaderField: "grpc-message"))
        } catch let error as GrpcWebError where error.status == 16 {
            throw CloudError.sessionExpired
        }
    }
}
