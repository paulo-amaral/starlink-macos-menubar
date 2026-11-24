import Foundation
import Testing
@testable import StarPulseCore

private func config(_ id: UInt32, mac: String, name: String? = nil, schedules: [(group: String, end: UInt64)] = [], extra: Bool = false) -> [UInt8] {
    var w = ProtoWriter()
    w.writeVarint(1, UInt64(id)); w.writeString(2, mac)
    if let name { w.writeString(3, name) }
    for schedule in schedules { w.writeMessage(5) { s in s.writeMessage(1) { $0.writeVarint(1, 60); $0.writeVarint(2, schedule.end) }; s.writeString(2, schedule.group) } }
    if extra { w.writeString(6, "kids") } // a field this code never touches
    return w.bytes
}

private func configResponse(_ configs: [[UInt8]]) -> [UInt8] {
    var wifi = ProtoWriter(); wifi.writeString(3, "TL")
    for c in configs { wifi.writeBytes(74, c) }
    var outer = ProtoWriter(); outer.writeBytes(1, wifi.bytes)
    var envelope = ProtoWriter(); envelope.writeBytes(3009, outer.bytes)
    return envelope.bytes
}

/// Pulls the client configs back out of a built request.
private func sentConfigs(_ request: [UInt8]) throws -> (target: String, configs: [[UInt8]], apply: Bool) {
    var target = "", configs: [[UInt8]] = [], apply = false
    for field in try ProtoReader.rawFields(request) {
        var r = field.reader
        if field.number == 13 { target = String(decoding: try r.readLengthDelimited(), as: UTF8.self) }
        if field.number == 3001 {
            let wifi = try #require(try DishDecoder.submessage(1, in: try r.readLengthDelimited()))
            for f in try ProtoReader.rawFields(wifi) {
                var fr = f.reader
                if f.number == 74 { configs.append(try fr.readLengthDelimited()) }
                if f.number == 1089 { apply = try fr.readVarint() == 1 }
            }
        }
    }
    return (target, configs, apply)
}

@Test func pauseAddsOnlyThePermanentScheduleAndKeepsEveryOtherEntryByteForByte() throws {
    let others = [config(7, mac: "aa:bb:cc:00:00:00", name: "TV", schedules: [("bedtime", 300)], extra: true), config(9, mac: "aa:bb:cc:00:00:00")]
    let target = config(8, mac: "11:22:33:00:00:00", name: "Phone", schedules: [("bedtime", 300)])
    let existing = try DevicePause.rawClientConfigs(configResponse: configResponse([others[0], target, others[1]]))
    #expect(existing.count == 3)
    let request = try DevicePause.request(targetId: "Router-0100abc", existing: existing, clientId: 8, macAddress: "11:22:33:00:00:00", paused: true)
    let sent = try sentConfigs(request)
    #expect(sent.target == "Router-0100abc" && sent.apply)
    #expect(sent.configs[0] == others[0] && sent.configs[2] == others[1])   // untouched devices, identical bytes
    let edited = sent.configs[1]
    #expect(edited.starts(with: target))                                   // its own fields and bedtime schedule kept
    #expect(try DevicePause.isPermanentSchedule(try DishDecoder.submessage(5, in: Array(edited.dropFirst(target.count)))!))

    // Resume removes only the permanent schedule and gives back the original entry.
    let resumed = try sentConfigs(try DevicePause.request(targetId: "Router-0100abc", existing: sent.configs, clientId: 8, macAddress: "", paused: false))
    #expect(resumed.configs == [others[0], target, others[1]])
}

@Test func deviceWithoutAnEntryGetsOneKeyedByClientId() throws {
    let request = try DevicePause.request(targetId: "Router-1", existing: [config(1, mac: "aa:00:00:00:00:00")], clientId: 5, macAddress: "bb:00:00:00:00:00", paused: true)
    let sent = try sentConfigs(request)
    #expect(sent.configs.count == 2)
    #expect(try DevicePause.clientId(of: sent.configs[1]) == 5)
    #expect(throws: PauseError.unknownClient) { try DevicePause.request(targetId: "Router-1", existing: [], clientId: 5, macAddress: "", paused: true) }
    #expect(throws: PauseError.invalidTarget) { try DevicePause.request(targetId: "ut123", existing: [], clientId: 5, macAddress: "x", paused: true) }
}

@Test func verificationRefusesAnythingBeyondThePause() throws {
    let a = config(1, mac: "aa:00:00:00:00:00"), b = config(2, mac: "bb:00:00:00:00:00", name: "B")
    #expect(throws: PauseError.unsafeRequest("another device's entry changed")) {
        try DevicePause.verify(original: [a, b], updated: [a, config(2, mac: "bb:00:00:00:00:00", name: "Changed")], clientId: 1)
    }
    #expect(throws: PauseError.unsafeRequest("the device appears more than once")) { try DevicePause.verify(original: [a], updated: [a, a], clientId: 1) }
}

@Test func controllerIsTheRouterZeroHopsAway() {
    let telemetry: [String: Any] = ["data": [
        "columnNamesByDeviceType": ["r": ["DeviceType", "DeviceId", "WifiHopsFromController"], "u": ["DeviceType", "DeviceId"]],
        "values": [["u", "ut-dish"], ["r", "Router-node", 1], ["r", "Router-main", 0]],
    ]]
    #expect(StarlinkCloud.controllerId(fromTelemetry: telemetry) == "Router-main")
    let lone: [String: Any] = ["data": ["columnNamesByDeviceType": ["r": ["DeviceType", "DeviceId"]], "values": [["r", "Router-only"]]]]
    #expect(StarlinkCloud.controllerId(fromTelemetry: lone) == "Router-only")
    #expect(StarlinkCloud.controllerId(fromTelemetry: ["data": [:]]) == nil)
}

@Test func routerStatusCarriesItsDeviceId() throws {
    var info = ProtoWriter()
    info.writeBytes(1, Array("Router-010000000000000001B31340".utf8))
    var status = ProtoWriter()
    status.writeBytes(3, info.bytes)
    var envelope = ProtoWriter()
    envelope.writeBytes(3004, status.bytes)
    #expect(try RouterDecoder.decodeStatus(response: envelope.bytes).deviceId == "Router-010000000000000001B31340")
}

// A write is built from LAN reads, so the router on the LAN must be the account's router.
@Test func writesRequireTheLanRouterToBeTheAccountRouter() throws {
    try StarlinkCloud.requireSameRouter(lan: "Router-010000000000000001b31340", account: "Router-010000000000000001B31340")
    #expect(throws: PauseError.otherRouter) {
        try StarlinkCloud.requireSameRouter(lan: "Router-01000000000000000049375B", account: "Router-010000000000000001B31340")
    }
    #expect(throws: PauseError.otherRouter) { try StarlinkCloud.requireSameRouter(lan: "", account: "Router-010000000000000001B31340") }
}

// Dishylink #105: the router's WAN addresses. Starlink hands out IPv4 behind CGNAT (100.64.0.0/10).
@Test func routerStatusCarriesWanAddresses() throws {
    var status = ProtoWriter()
    status.writeBytes(1003, Array("100.72.1.2".utf8))
    status.writeBytes(1017, Array("2001:db8:1::1/64".utf8))
    status.writeBytes(1017, Array("fe80::1/64".utf8))
    var envelope = ProtoWriter()
    envelope.writeBytes(3004, status.bytes)
    let decoded = try RouterDecoder.decodeStatus(response: envelope.bytes)
    #expect(decoded.wanIPv4 == "100.72.1.2")
    #expect(decoded.wanIPv6 == ["2001:db8:1::1/64", "fe80::1/64"])
    #expect(RouterStatus.isCarrierGradeNAT("100.72.1.2"))
    #expect(!RouterStatus.isCarrierGradeNAT("203.0.113.5"))
}
