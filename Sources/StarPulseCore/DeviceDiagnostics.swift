import Foundation

/// get_diagnostics (request 6000), read when Settings opens. The dish answers in field 6001 and the
/// router in 6000. Field numbers from the devices' own reflection (dish 2026.11.12, router 2026.11.09).
public enum DeviceDiagnostics {
    static let request = 6000
    enum Response { static let router = 6000, dish = 6001 }

    /// DishGetDiagnosticsResponse.TestResult.
    public enum SelfTest: UInt64, Sendable {
        case noResult = 0, passed, failed
        public var label: String {
            switch self {
            case .noResult: "No result yet"
            case .passed: "Passed"
            case .failed: "Failed"
            }
        }
    }

    /// Connected devices as the router counts them, summed over its networks.
    public struct ClientCounts: Sendable, Equatable {
        public var ethernet = 0, band2GHz = 0, band5GHz = 0
        public init(ethernet: Int = 0, band2GHz: Int = 0, band5GHz: Int = 0) {
            self.ethernet = ethernet
            self.band2GHz = band2GHz
            self.band5GHz = band5GHz
        }
    }

    public static func selfTest(response: [UInt8]) throws -> SelfTest? {
        guard let body = try DishDecoder.submessage(Response.dish, in: response) else { return nil }
        var reader = ProtoReader(body)
        var result = SelfTest.noResult
        while let (field, wire) = try reader.nextField() {
            if field == 7, wire == .varint { result = SelfTest(rawValue: try reader.readVarint()) ?? .noResult } else { try reader.skip(wire) }
        }
        return result
    }

    public static func clientCounts(response: [UInt8]) throws -> ClientCounts? {
        guard let body = try DishDecoder.submessage(Response.router, in: response) else { return nil }
        var counts = ClientCounts()
        var reader = ProtoReader(body)
        while let (field, wire) = try reader.nextField() {
            guard field == 4, wire == .lengthDelimited else { try reader.skip(wire); continue }
            var network = ProtoReader(try reader.readLengthDelimited())
            while let (f, w) = try network.nextField() {
                guard w == .varint else { try network.skip(w); continue }
                // Capped so a malformed reply cannot overflow the sums and trap.
                let value = Int(min(try network.readVarint(), 10_000))
                switch f {
                case 10: counts.ethernet += value
                case 11: counts.band2GHz += value
                case 12: counts.band5GHz += value
                default: break
                }
            }
        }
        return counts
    }
}
