import Foundation
import Testing
@testable import StarPulseCore

private func fixture(_ name: String) throws -> [String: Any] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
}

private func floats(_ value: Any?) -> [Float] {
    (value as? [Any] ?? []).map { item in
        if let string = item as? String { return Float(string) ?? .nan }
        return Float((item as? NSNumber)?.doubleValue ?? .nan)
    }
}

/// Wraps an encoded body as Response{ field: body }.
private func response(field: Int, _ build: (inout ProtoWriter) -> Void) -> [UInt8] {
    var writer = ProtoWriter()
    writer.writeMessage(field, build)
    return writer.bytes
}

@Test func requestSelectsMethodByFieldNumber() {
    #expect(DishDecoder.requestBytes(getHistory: false) == [0xE2, 0x3E, 0x00]) // field 1004, len 0
    #expect(DishDecoder.requestBytes(getHistory: true) == [0xFA, 0x3E, 0x00])  // field 1007, len 0
}

@Test func framingRoundTrip() throws {
    let frame = GrpcWeb.encodeFrame([1, 2, 3])
    #expect([UInt8](frame) == [0, 0, 0, 0, 3, 1, 2, 3])
    var body = frame
    let trailer = Array("grpc-status: 0\r\n".utf8)
    body.append(contentsOf: [0x80, 0, 0, 0, UInt8(trailer.count)] + trailer)
    #expect(try GrpcWeb.decodeResponse(body: body, headerStatus: nil, headerMessage: nil) == [1, 2, 3])
}

@Test func trailersWithErrorStatusThrow() {
    let trailer = Array("grpc-status: 7\r\ngrpc-message: denied\r\n".utf8)
    var body = Data([0x80, 0, 0, 0, UInt8(trailer.count)])
    body.append(contentsOf: trailer)
    #expect(throws: GrpcWebError(status: 7, message: "denied")) {
        try GrpcWeb.decodeResponse(body: body, headerStatus: nil, headerMessage: nil)
    }
}

@Test func headerOnlyStatusThrows() {
    #expect(throws: GrpcWebError(status: 7, message: "nope")) {
        try GrpcWeb.decodeResponse(body: Data(), headerStatus: 7, headerMessage: "nope")
    }
}

@Test func statusDecodesFromSampleValues() throws {
    let sample = try #require(try fixture("sample-status")["dishGetStatus"] as? [String: Any])
    let bytes = response(field: DishDecoder.Response.dishGetStatus) { w in
        w.writeMessage(1) { $0.writeString(1, "ut-test"); $0.writeString(2, "rev4_panda_prod2"); $0.writeString(3, "2026.07.06.mr81950"); $0.writeString(4, "NG") }
        w.writeMessage(2) { $0.writeVarint(1, 15065) }
        w.writeMessage(1004) { $0.writeFloat(1, 0.00061099796); $0.writeBool(5, false) }
        w.writeMessage(1005) { $0.writeBool(23, true); $0.writeBool(9, true) }
        w.writeFloat(1007, Float(truncating: sample["downlinkThroughputBps"] as! NSNumber))
        w.writeFloat(1008, Float(truncating: sample["uplinkThroughputBps"] as! NSNumber))
        w.writeFloat(1009, Float(truncating: sample["popPingLatencyMs"] as! NSNumber))
        w.writeVarint(1016, 1000)
    }
    let status = try DishDecoder.decodeStatus(response: bytes)
    #expect(status.deviceId == "ut-test")
    #expect(status.hardwareVersion == "rev4_panda_prod2")
    #expect(status.uptimeSeconds == 15065)
    #expect(abs(status.latencyMs - 18.070942) < 0.001)
    #expect(abs(status.downlinkBps - 898134.7) < 1)
    #expect(status.ethSpeedMbps == 1000)
    #expect(status.activeAlerts == ["isHeating", "noEthernetLink"])
    #expect(status.fractionObstructed < 0.001)
}

@Test func historyUnrollsRingNewestLast() throws {
    let sample = try #require(try fixture("sample-history")["dishGetHistory"] as? [String: Any])
    let latency = floats(sample["popPingLatencyMs"])
    let current = UInt64(try #require(sample["current"] as? String))!
    #expect(latency.count == 900)
    let bytes = response(field: DishDecoder.Response.dishGetHistory) { w in
        w.writeVarint(1, current)
        w.writePackedFloats(1001, floats(sample["popPingDropRate"]))
        w.writePackedFloats(1002, latency)
        w.writePackedFloats(1003, floats(sample["downlinkThroughputBps"]))
        w.writePackedFloats(1004, floats(sample["uplinkThroughputBps"]))
        w.writePackedFloats(1010, floats(sample["powerIn"]))
        w.writeMessage(1011) { log in
            log.writeMessage(1) { $0.writeVarint(1, 3); $0.writeVarint(2, 9); $0.writeVarint(3, 1_784_081_517_040_148_603); $0.writeVarint(4, 920_024_910) }
        }
    }
    let now = Date(timeIntervalSince1970: 1_784_090_000)
    let history = try DishDecoder.decodeHistory(response: bytes, now: now)
    #expect(history.samples.count == 900)
    #expect(history.newestCounter == current)
    #expect(history.samples.last?.timestamp == now)
    #expect(history.samples.first?.timestamp == now.addingTimeInterval(-899))
    let newestIndex = Int(current - 1) % 900
    #expect(history.samples.last?.latencyMs == (latency[newestIndex] > 0 ? latency[newestIndex] : nil))
    #expect(history.events.count == 1)
    #expect(history.events[0].title == "No pings")
    #expect(abs(history.events[0].duration - 0.920) < 0.001)
}

@Test func zeroLatencyIsOutageNotZeroMs() {
    let samples = DishDecoder.unrollRing(current: 2, drop: [1, 0], latency: [0, 25], down: [], up: [], power: [], now: Date())
    #expect(samples[0].latencyMs == nil)
    #expect(samples[1].latencyMs == 25)
    #expect(samples[1].downlinkBps == 0)
}

@Test func clientMapsHTTPErrorsAndDecodesBody() async throws {
    let url = DishClient.defaultURL
    let body = GrpcWeb.encodeFrame(response(field: DishDecoder.Response.dishGetStatus) { $0.writeFloat(1009, 31) })
    let ok = DishClient(transport: HTTPTransport { request in
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/grpc-web+proto")
        return (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    })
    #expect(try await ok.status().latencyMs == 31)

    let denied = DishClient(transport: HTTPTransport { _ in
        (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["grpc-status": "7", "grpc-message": "blocked"])!)
    })
    await #expect(throws: GrpcWebError(status: 7, message: "blocked")) { try await denied.status() }
}

@Test func menuBarRateUsesSIThresholds() {
    #expect(Format.menuBarRate(340_000) == "340Kb/s")
    #expect(Format.menuBarRate(1_200_000) == "1.2Mb/s")
    #expect(Format.menuBarRate(2_000_000_000) == "2.0Gb/s")
    #expect(Format.rate(1_200_000) == ("1.2", "Mbps"))
}

@Test func outageRangesGroupContiguousLoss() {
    func sample(_ second: Double, _ drop: Float) -> TelemetrySample {
        TelemetrySample(timestamp: Date(timeIntervalSince1970: second), latencyMs: nil, dropRate: drop, downlinkBps: 0, uplinkBps: 0, powerW: 0)
    }
    let ranges = TelemetrySample.outageRanges([sample(0, 0), sample(1, 1), sample(2, 1), sample(3, 0), sample(4, 1)])
    #expect(ranges.count == 2)
    #expect(ranges[0] == Date(timeIntervalSince1970: 1)...Date(timeIntervalSince1970: 2))
    #expect(ranges[1] == Date(timeIntervalSince1970: 4)...Date(timeIntervalSince1970: 4))
}

@Test func routerRequestAndClientsDecode() throws {
    #expect(DishDecoder.requestBytes(field: 3002) == [0xD2, 0xBB, 0x01, 0x00])
    var body = ProtoWriter()
    body.writeMessage(1) { client in
        client.writeString(1, "phone-raw"); client.writeString(31, "Jane's phone"); client.writeString(2, "aa:bb:cc:00:00:01"); client.writeString(3, "10.0.1.2")
        client.writeFloat(4, -61); client.writeVarint(7, 7200); client.writeVarint(9, 3); client.writeVarint(14, 1)
        client.writeVarint(43, 9); client.writeBool(42, true); client.writeVarint(54, 12); client.writeVarint(55, 345)
        client.writeMessage(5) { $0.writeFloat(18, 4.5) }
        client.writeMessage(6) { $0.writeFloat(13, .nan) }
    }
    body.writeMessage(1) { $0.writeString(1, "Controller"); $0.writeVarint(9, 1); $0.writeVarint(14, 3) }
    var envelope = ProtoWriter()
    envelope.writeBytes(3002, body.bytes)
    let clients = try RouterDecoder.decodeClients(response: envelope.bytes)
    #expect(clients.count == 2)
    #expect(clients[0].displayName == "Jane's phone")
    #expect(clients[0].band == .ghz5 && clients[0].role == .client)
    #expect(clients[0].signalDbm == -61 && clients[0].clientId == 9)
    #expect(clients[0].blocked && !clients[1].blocked)
    #expect(clients[0].downloadMB == 345 && clients[0].uploadMB == 12)
    #expect(clients[0].throughputMbps == 4.5) // NaN tx is ignored, not propagated
    #expect(clients[1].role == .controller && clients[1].band == .wired && clients[1].signalDbm == nil)
}

@Test func alignmentOnRealDishNumbers() throws {
    // Values read from a real Starlink Mini on 2026-11-23.
    var status = DishStatus()
    status.boresightAzimuthDeg = 174.44; status.boresightElevationDeg = 73.42
    status.desiredAzimuthDeg = -179.9457; status.desiredElevationDeg = 75.99; status.attitudeState = 2
    let reading = AlignmentMath.compute(status)
    #expect(reading.isValid)
    #expect(abs(reading.azimuthErrorDeg + 5.61) < 0.05) // wraps across 180°, not 354°
    #expect(abs(reading.elevationErrorDeg + 2.57) < 0.01)
    #expect(reading.boresightErrorDeg > 2.5 && reading.boresightErrorDeg < 3.5)
    #expect(reading.isAligned) // separation at the 70° band floor is under 5°
    status.boresightAzimuthDeg = 120
    #expect(!AlignmentMath.compute(status).isAligned)
    status.attitudeState = 3
    status.boresightAzimuthDeg = 180
    #expect(!AlignmentMath.compute(status).isValid)
}

@Test func obstructionMapDecodesAndClassifies() throws {
    var inner = ProtoWriter()
    inner.writeVarint(1, 2); inner.writeVarint(2, 2)
    inner.writePackedFloats(3, [-1, 1, 0.9, 0.5])
    var envelope = ProtoWriter()
    envelope.writeBytes(2008, inner.bytes)
    let map = try DishDecoder.decodeObstructionMap(response: envelope.bytes)
    #expect(map.kind(row: 0, col: 0) == .unmapped)
    #expect(map.kind(row: 0, col: 1) == .clear)
    #expect(map.kind(row: 1, col: 0) == .partial)
    #expect(map.kind(row: 1, col: 1) == .obstructed)
    #expect(abs(map.obstructedShareOfMapped - 2.0 / 3.0) < 1e-9)
}

@Test func statsMedianAveragesAndEventWindow() {
    func sample(_ latency: Float?, drop: Float = 0, power: Float = 0, down: Float = 0) -> TelemetrySample {
        TelemetrySample(timestamp: Date(), latencyMs: latency, dropRate: drop, downlinkBps: down, uplinkBps: 0, powerW: power)
    }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let events = [
        DishEvent(severity: .warning, reason: 9, startTimestampNs: Int64((now.timeIntervalSince1970 - 3600) * 1e9), durationNs: 1),
        DishEvent(severity: .warning, reason: 9, startTimestampNs: Int64((now.timeIntervalSince1970 - 90_000) * 1e9), durationNs: 1),
    ]
    let stats = TelemetryStats.compute(samples: [sample(10, power: 30, down: 4e6), sample(nil, drop: 1, down: 0), sample(30, power: 20, down: 8e6), sample(20, power: 0)], events: events, now: now)
    #expect(stats.medianLatencyMs == 20)           // nil (outage) excluded from the median
    #expect(stats.pingSuccessPercent == 75)
    #expect(stats.averagePowerW == 25)            // zero power ignored
    #expect(stats.averageDownlinkBps == 3e6)
    #expect(stats.eventsLastDay == 1)
    #expect(TelemetryStats.compute(samples: [], events: [], now: now).medianLatencyMs == nil)
}

// Anything on the LAN can answer at the dish's address, so out-of-range numbers must not trap.
@Test func hostileSizesAndCountersDoNotCrash() throws {
    var inner = ProtoWriter()
    inner.writeVarint(1, UInt64.max); inner.writeVarint(2, UInt64.max); inner.writeVarint(6, UInt64.max)
    var envelope = ProtoWriter()
    envelope.writeBytes(2008, inner.bytes)
    let map = try DishDecoder.decodeObstructionMap(response: envelope.bytes)
    #expect(map.isEmpty)

    let samples = DishDecoder.unrollRing(current: UInt64.max, drop: [0, 0], latency: [20, 30], down: [], up: [], power: [], now: Date())
    #expect(samples.count == 2)
}
