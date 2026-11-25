import Foundation

/// The Starlink router's own speed test: start_speedtest (1027) starts it, get_speedtest_status
/// (1028) reports it. It runs from the router to the internet, so Wi-Fi and this Mac are not part of
/// the result. The dish does not implement it (gRPC 12 on firmware 2026.11.12).
public struct RouterSpeedtest: Sendable, Equatable {
    /// Whether a test is under way; it runs about 15 s down, then about 15 s up.
    public var running = false
    /// Changes with every test, so a new run can be told from the last one.
    public var id: UInt64 = 0
    /// Readings in Mbps, about four per second (SpeedtestStatus.Direction.throughputs_mbps).
    public var downloadMbps: [Double] = []
    public var uploadMbps: [Double] = []
    /// A SpeedtestError was set for either direction.
    public var failed = false

    public init() {}

    enum Field { static let start = 1027, status = 1028 }

    public static func decode(response: [UInt8]) throws -> RouterSpeedtest {
        var test = RouterSpeedtest()
        guard let body = try DishDecoder.submessage(Field.status, in: response),
              let status = try DishDecoder.submessage(1, in: body) else { return test }
        var reader = ProtoReader(status)
        while let (field, wire) = try reader.nextField() {
            switch (field, wire) {
            case (1, .varint): test.running = try reader.readVarint() != 0
            case (2, .varint): test.id = try reader.readVarint()
            case (1000, .lengthDelimited): try decodeDirection(try reader.readLengthDelimited(), into: &test.uploadMbps, failed: &test.failed)
            case (1001, .lengthDelimited): try decodeDirection(try reader.readLengthDelimited(), into: &test.downloadMbps, failed: &test.failed)
            default: try reader.skip(wire)
            }
        }
        return test
    }

    private static func decodeDirection(_ bytes: [UInt8], into readings: inout [Double], failed: inout Bool) throws {
        var reader = ProtoReader(bytes)
        while let (field, wire) = try reader.nextField() {
            switch (field, wire) {
            case (1, .lengthDelimited): // packed floats
                var packed = ProtoReader(try reader.readLengthDelimited())
                while !packed.isAtEnd { readings.append(Double(try packed.readFloat())) }
            case (1, .fixed32): readings.append(Double(try reader.readFloat()))
            case (2, .varint): if try reader.readVarint() != 0 { failed = true }
            default: try reader.skip(wire)
            }
        }
    }

    /// The figure shown for one direction: the average of the router's readings. The schema does not
    /// say how the Starlink app reduces them to one number, so this is StarPulse's choice.
    public static func average(_ readings: [Double]) -> Double? {
        readings.isEmpty ? nil : readings.reduce(0, +) / Double(readings.count)
    }
}
