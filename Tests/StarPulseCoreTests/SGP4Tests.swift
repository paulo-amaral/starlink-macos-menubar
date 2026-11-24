import Foundation
import Testing
@testable import StarPulseCore

/// Vectors produced by the independent python `sgp4` package (WGS-72) for the classic test case 88888 and four
/// real Starlink element sets at several minutes after epoch.
private struct Vector: Decodable { var name: String; var l1: String; var l2: String; var t: Double; var r: [Double]; var v: [Double] }

@Test func sgp4MatchesTheReferenceImplementation() throws {
    let url = try #require(Bundle.module.url(forResource: "sgp4_reference", withExtension: "json", subdirectory: "Fixtures"))
    let vectors = try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
    #expect(vectors.count == 25)
    var worstPosition = 0.0, worstVelocity = 0.0
    for vector in vectors {
        let tle = try TLE(name: vector.name, line1: vector.l1, line2: vector.l2)
        let state = try #require(try SGP4(tle).propagate(minutes: vector.t), "decayed: \(vector.name) \(vector.t)")
        let dr = (state.position - SIMD3(vector.r[0], vector.r[1], vector.r[2]))
        let dv = (state.velocity - SIMD3(vector.v[0], vector.v[1], vector.v[2]))
        worstPosition = max(worstPosition, (dr * dr).sum().squareRoot())
        worstVelocity = max(worstVelocity, (dv * dv).sum().squareRoot())
    }
    print("SGP4 worst position error \(worstPosition) km, velocity \(worstVelocity) km/s")
    #expect(worstPosition < 1e-6)
    #expect(worstVelocity < 1e-9)
}

@Test func tleParsingAndEpoch() throws {
    let tle = try TLE(name: "STARLINK-1008", line1: "1 44714C 19074B   26327.34284722  .00001968  00000+0  15280-4 0  3271",
                      line2: "2 44714  53.1441  13.0854 0003533  22.8589  75.5200 15.71113710    16")
    #expect(abs(tle.bstar - 0.1528e-4) < 1e-12)
    #expect(abs(tle.eccentricity - 0.0003533) < 1e-12)
    #expect(abs(tle.inclination * 180 / .pi - 53.1441) < 1e-9)
    let utc = Calendar(identifier: .gregorian)
    var calendar = utc; calendar.timeZone = TimeZone(identifier: "UTC")!
    let parts = calendar.dateComponents([.year, .month, .day, .hour], from: tle.epoch)
    #expect(parts.year == 2026 && parts.month == 11 && parts.day == 23 && parts.hour == 8) // day 327.34 of 2026
    #expect(throws: TLEError.badFormat) { try TLE(name: "x", line1: "garbage", line2: "garbage") }
    #expect(TLE.parse("A\n1 bad\n2 bad\n").isEmpty)
}

@Test func deepSpaceOrbitsAreRejected() throws {
    // A geosynchronous element set (about 1 rev/day): SDP4 territory, which this port does not cover.
    let tle = try TLE(name: "GEO", line1: "1 99999U 20001A   26327.50000000  .00000000  00000-0  00000-0 0  9990",
                      line2: "2 99999   0.0500  90.0000 0001000  45.0000 315.0000  1.00270000    10")
    #expect(throws: TLEError.deepSpace) { try SGP4(tle) }
}
