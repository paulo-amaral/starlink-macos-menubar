import Foundation

/// Field numbers from the dish's reflection dump (Dishylink schema/dish.protoset).
/// Reflection gives names and types but not which fields the firmware fills;
/// see Dishylink LOCAL-API.md: status lacks power_in, history has it.
public enum DishDecoder {
    enum Request { static let getStatus = 1004, getHistory = 1007, obstructionMap = 2008 }
    enum Response { static let dishGetHistory = 2006, dishGetStatus = 2004, obstructionMap = 2008 }

    public static func requestBytes(getHistory: Bool) -> [UInt8] {
        requestBytes(field: getHistory ? Request.getHistory : Request.getStatus)
    }

    /// Empty submessage selects the RPC; the field number is the method.
    public static func requestBytes(field: Int) -> [UInt8] {
        var writer = ProtoWriter()
        writer.writeBytes(field, [])
        return writer.bytes
    }

    static let alertNames: [Int: String] = [
        1: "motorsStuck", 2: "thermalShutdown", 3: "thermalThrottle", 4: "unexpectedLocation",
        5: "mastNotNearVertical", 6: "slowEthernetSpeeds", 7: "roaming", 8: "installPending",
        9: "isHeating", 10: "powerSupplyThermalThrottle", 11: "isPowerSaveIdle", 14: "dbfTelemStale",
        16: "lowMotorCurrent", 17: "lowerSignalThanPredicted", 18: "slowEthernetSpeeds100",
        19: "obstructionMapReset", 20: "dishWaterDetected", 21: "routerWaterDetected",
        22: "upsuRouterPortSlow", 23: "noEthernetLink",
    ]

    /// Pulls one nested message out of a top-level Response.
    static func submessage(_ number: Int, in response: [UInt8]) throws -> [UInt8]? {
        var reader = ProtoReader(response)
        var found: [UInt8]?
        while let (field, wire) = try reader.nextField() {
            if field == number, wire == .lengthDelimited { found = try reader.readLengthDelimited() }
            else { try reader.skip(wire) }
        }
        return found
    }

    public static func decodeStatus(response: [UInt8]) throws -> DishStatus {
        var status = DishStatus()
        guard let body = try submessage(Response.dishGetStatus, in: response) else { return status }
        var reader = ProtoReader(body)
        while let (field, wire) = try reader.nextField() {
            switch (field, wire) {
            case (1, .lengthDelimited): try decodeDeviceInfo(try reader.readLengthDelimited(), into: &status)
            case (2, .lengthDelimited):
                var state = ProtoReader(try reader.readLengthDelimited())
                while let (f, w) = try state.nextField() {
                    if f == 1, w == .varint { status.uptimeSeconds = try state.readVarint() } else { try state.skip(w) }
                }
            case (1003, .fixed32): status.dropRate = try reader.readFloat()
            case (1004, .lengthDelimited): try decodeObstruction(try reader.readLengthDelimited(), into: &status)
            case (1005, .lengthDelimited): status.activeAlerts = try decodeAlerts(try reader.readLengthDelimited())
            case (1007, .fixed32): status.downlinkBps = try reader.readFloat()
            case (1008, .fixed32): status.uplinkBps = try reader.readFloat()
            case (1009, .fixed32): status.latencyMs = try reader.readFloat()
            case (1011, .fixed32): status.boresightAzimuthDeg = try reader.readFloat()
            case (1012, .fixed32): status.boresightElevationDeg = try reader.readFloat()
            case (1017, .varint): status.mobilityClass = try reader.readInt()
            case (1027, .lengthDelimited): try decodeAlignment(try reader.readLengthDelimited(), into: &status)
            case (1016, .varint): status.ethSpeedMbps = Int32(truncatingIfNeeded: try reader.readVarint())
            default: try reader.skip(wire)
            }
        }
        return status
    }

    private static func decodeDeviceInfo(_ bytes: [UInt8], into status: inout DishStatus) throws {
        var reader = ProtoReader(bytes)
        while let (field, wire) = try reader.nextField() {
            guard wire == .lengthDelimited else { try reader.skip(wire); continue }
            let text = String(decoding: try reader.readLengthDelimited(), as: UTF8.self)
            switch field {
            case 1: status.deviceId = text
            case 2: status.hardwareVersion = text
            case 3: status.softwareVersion = text
            case 4: status.countryCode = text
            default: break
            }
        }
    }

    private static func decodeAlignment(_ bytes: [UInt8], into status: inout DishStatus) throws {
        var reader = ProtoReader(bytes)
        while let (field, wire) = try reader.nextField() {
            switch (field, wire) {
            case (3, .fixed32): status.tiltAngleDeg = try reader.readFloat()
            case (6, .varint): status.attitudeState = try reader.readInt()
            case (8, .fixed32): status.desiredAzimuthDeg = try reader.readFloat()
            case (9, .fixed32): status.desiredElevationDeg = try reader.readFloat()
            default: try reader.skip(wire)
            }
        }
    }

    private static func decodeObstruction(_ bytes: [UInt8], into status: inout DishStatus) throws {
        var reader = ProtoReader(bytes)
        while let (field, wire) = try reader.nextField() {
            switch (field, wire) {
            case (1, .fixed32): status.fractionObstructed = try reader.readFloat()
            case (5, .varint): status.currentlyObstructed = try reader.readVarint() != 0
            case (4, .fixed32): status.obstructionObservedSeconds = try reader.readFloat()
            default: try reader.skip(wire)
            }
        }
    }

    private static func decodeAlerts(_ bytes: [UInt8]) throws -> [String] {
        var reader = ProtoReader(bytes)
        var active: [String] = []
        while let (field, wire) = try reader.nextField() {
            if wire == .varint, try reader.readVarint() != 0, let name = alertNames[field] { active.append(name) }
            else if wire != .varint { try reader.skip(wire) }
        }
        return active.sorted()
    }

    public static func decodeObstructionMap(response: [UInt8]) throws -> ObstructionMap {
        guard let body = try submessage(Response.obstructionMap, in: response) else { return ObstructionMap(rows: 0, cols: 0, cells: []) }
        var rows = 0, cols = 0
        var cells: [Float] = []
        var maxTheta: Float = 80
        var frame = 1
        var reader = ProtoReader(body)
        while let (field, wire) = try reader.nextField() {
            switch field {
            // The dish sends 123 x 123; the cap keeps rows * cols from overflowing.
            case 1: rows = Int(min(try reader.readVarint(), 4096))
            case 2: cols = Int(min(try reader.readVarint(), 4096))
            case 3: try reader.appendFloats(wire: wire, to: &cells)
            case 5 where wire == .fixed32: maxTheta = try reader.readFloat()
            case 6 where wire == .varint: frame = try reader.readInt()
            default: try reader.skip(wire)
            }
        }
        var map = ObstructionMap(rows: rows, cols: cols, cells: cells)
        map.maxThetaDeg = maxTheta
        map.frame = frame
        return map
    }

    /// `now` pins the newest sample, as the dish's own clock is not synchronised.
    public static func decodeHistory(response: [UInt8], now: Date) throws -> DishHistory {
        guard let body = try submessage(Response.dishGetHistory, in: response) else {
            return DishHistory(samples: [], events: [], newestCounter: 0)
        }
        var current: UInt64 = 0
        var drop: [Float] = [], latency: [Float] = [], down: [Float] = [], up: [Float] = [], power: [Float] = []
        var events: [DishEvent] = []
        var reader = ProtoReader(body)
        while let (field, wire) = try reader.nextField() {
            switch field {
            case 1: current = try reader.readVarint()
            case 1001: try reader.appendFloats(wire: wire, to: &drop)
            case 1002: try reader.appendFloats(wire: wire, to: &latency)
            case 1003: try reader.appendFloats(wire: wire, to: &down)
            case 1004: try reader.appendFloats(wire: wire, to: &up)
            case 1010: try reader.appendFloats(wire: wire, to: &power)
            case 1011: events = try decodeEventLog(try reader.readLengthDelimited())
            default: try reader.skip(wire)
            }
        }
        return DishHistory(
            samples: unrollRing(current: current, drop: drop, latency: latency, down: down, up: up, power: power, now: now),
            events: events,
            newestCounter: current
        )
    }

    /// `current` counts samples since boot; absolute counter `c` lives at
    /// index `c % arrayLength`. Ported from Dishylink core/telemetry.ts.
    static func unrollRing(current: UInt64, drop: [Float], latency: [Float], down: [Float], up: [Float], power: [Float], now: Date) -> [TelemetrySample] {
        let length = latency.count
        guard length > 0, current > 0 else { return [] }
        let count = Int(min(current, UInt64(length)))
        return (0..<count).map { offset in
            let ring = Int((current - UInt64(count) + UInt64(offset)) % UInt64(length))
            let ping = latency[ring]
            return TelemetrySample(
                timestamp: now.addingTimeInterval(-Double(count - 1 - offset)),
                latencyMs: ping.isFinite && ping > 0 ? ping : nil,
                dropRate: drop.indices.contains(ring) ? drop[ring] : 0,
                downlinkBps: down.indices.contains(ring) ? down[ring] : 0,
                uplinkBps: up.indices.contains(ring) ? up[ring] : 0,
                powerW: power.indices.contains(ring) ? power[ring] : 0
            )
        }
    }

    private static func decodeEventLog(_ bytes: [UInt8]) throws -> [DishEvent] {
        var reader = ProtoReader(bytes)
        var events: [DishEvent] = []
        while let (field, wire) = try reader.nextField() {
            guard field == 1, wire == .lengthDelimited else { try reader.skip(wire); continue }
            var event = ProtoReader(try reader.readLengthDelimited())
            var severity = 0, reason = 0
            var start: Int64 = 0, duration: UInt64 = 0
            while let (f, w) = try event.nextField() {
                switch (f, w) {
                case (1, .varint): severity = try event.readInt()
                case (2, .varint): reason = try event.readInt()
                case (3, .varint): start = Int64(bitPattern: try event.readVarint())
                case (4, .varint): duration = try event.readVarint()
                default: try event.skip(w)
                }
            }
            events.append(DishEvent(severity: .init(rawValue: severity) ?? .unknown, reason: reason, startTimestampNs: start, durationNs: duration))
        }
        return events
    }
}
