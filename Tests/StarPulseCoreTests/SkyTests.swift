import Foundation
import Testing
@testable import StarPulseCore

@Test func gmstAtJ2000MatchesTheKnownValue() {
    let j2000 = Date(timeIntervalSince1970: 946_728_000) // 2000-01-01 12:00:00 UTC
    #expect(abs(SkyMath.gmst(j2000) * 180 / .pi - 280.46061837) < 1e-6)
}

@Test func overheadSatelliteReadsNinetyDegreesAtItsAltitude() {
    let observer = Observer(latitudeDeg: 0, longitudeDeg: 0, altitudeKm: 0)
    let date = Date(timeIntervalSince1970: 946_728_000)
    // Put a point 550 km straight above the observer in the rotating frame, then turn it into TEME.
    let theta = SkyMath.gmst(date)
    let radius = 6378.137 + 550
    let ecef = SIMD3(radius, 0.0, 0.0)
    let teme = SIMD3(ecef.x * cos(theta) - ecef.y * sin(theta), ecef.x * sin(theta) + ecef.y * cos(theta), ecef.z)
    let look = SkyMath.lookAngles(teme: teme, at: date, observer: observer)
    #expect(abs(look.elevationDeg - 90) < 1e-6)
    #expect(abs(look.rangeKm - 550) < 1e-6)
    // Directions are built in the rotating frame and turned into TEME the same way: +z is north, +y is east.
    func toTEME(_ e: SIMD3<Double>) -> SIMD3<Double> { SIMD3(e.x * cos(theta) - e.y * sin(theta), e.x * sin(theta) + e.y * cos(theta), e.z) }
    let north = SkyMath.lookAngles(teme: toTEME(SIMD3(radius, 0, 3000)), at: date, observer: observer)
    let east = SkyMath.lookAngles(teme: toTEME(SIMD3(radius, 3000, 0)), at: date, observer: observer)
    #expect(abs(north.azimuthDeg) < 1e-6 || abs(north.azimuthDeg - 360) < 1e-6)
    #expect(abs(east.azimuthDeg - 90) < 1e-6)
}

@Test func servingChoiceHoldsWithinASlotAndSkipsObstructed() {
    func sat(_ name: String, _ el: Double) -> SatelliteSky { SatelliteSky(name: name, azimuthDeg: 0, elevationDeg: el, rangeKm: 600) }
    var chooser = ServingChooser()
    let slotStart = Date(timeIntervalSince1970: 15_000)
    // The highest is blocked, so the next clear one above 25 degrees wins.
    let first = chooser.choose(inView: [sat("A", 70), sat("B", 50), sat("C", 20)], at: slotStart) { $0.name != "A" }
    #expect(first?.name == "B")
    // Same slot: held, even though A is now the better pick.
    let held = chooser.choose(inView: [sat("A", 70), sat("B", 49), sat("C", 20)], at: slotStart.addingTimeInterval(5)) { _ in true }
    #expect(held?.name == "B")
    // Next slot: re-picked.
    let next = chooser.choose(inView: [sat("A", 70), sat("B", 49)], at: slotStart.addingTimeInterval(16)) { _ in true }
    #expect(next?.name == "A")
    // Nothing above the service floor: no candidate.
    #expect(chooser.choose(inView: [sat("D", 24)], at: slotStart.addingTimeInterval(40)) { _ in true } == nil)
}

@Test func obstructionGridMapsDirectionsInBothFrames() {
    // 5x5 grid, everything clear except the cell NE of centre (row 1, col 3) which is fully blocked.
    var cells = [Float](repeating: 1, count: 25)
    cells[1 * 5 + 3] = 0
    var map = ObstructionMap(rows: 5, cols: 5, cells: cells)
    map.maxThetaDeg = 80
    // Earth frame: north up, east right. Cell (1,3) is half way out toward the north-east.
    let (east, north) = map.eastNorth(row: 1, col: 3, boresightAzimuthDeg: 0)
    #expect(east == 0.5 && north == 0.5)
    // Direction az 45 deg at fraction ~0.707 lands on that cell; zenith = 0.707 * 80 = 56.6 deg => elevation 33.4.
    #expect(!map.isClear(azimuthDeg: 45, elevationDeg: 90 - 0.7071 * 80, boresightAzimuthDeg: 0))
    #expect(map.isClear(azimuthDeg: 225, elevationDeg: 90 - 0.7071 * 80, boresightAzimuthDeg: 0))
    // Terminal frame with the boresight at 90 deg: the same cell is found by rotating the direction.
    var rotated = map; rotated.frame = 2
    let toCell = rotated.eastNorth(row: 1, col: 3, boresightAzimuthDeg: 90)
    let azimuth = atan2(toCell.east, toCell.north) * 180 / .pi
    #expect(!rotated.isClear(azimuthDeg: azimuth, elevationDeg: 90 - hypot(toCell.east, toCell.north) * 80, boresightAzimuthDeg: 90))
}

@Test func accountExposesServiceAddressCoordinates() throws {
    let json = #"{"content":{"results":[{"serviceLineNumber":"SL-1","accountReferenceId":"A","serviceAddress":{"locality":"X","geoLocation":{"latitude":47.61,"longitude":-122.33}}}]}}"#
    let account = try CloudAccount.parse(identity: nil, serviceLines: JSONSerialization.jsonObject(with: Data(json.utf8)))
    #expect(account.latitude == 47.61 && account.longitude == -122.33)
}

@Test func trackerFindsSatellitesFromRealElementsAndSortsByElevation() throws {
    let l1 = "1 44714C 19074B   26327.34284722  .00001968  00000+0  15280-4 0  3271"
    let l2 = "2 44714  53.1441  13.0854 0003533  22.8589  75.5200 15.71113710    16"
    let tle = try TLE(name: "STARLINK-1008", line1: l1, line2: l2)
    let tracker = StarlinkTracker(tles: [tle, tle], observer: Observer(latitudeDeg: 0, longitudeDeg: 0))
    #expect(tracker.constellationSize == 2)
    // Over one full orbit the satellite must be above the horizon of an equatorial observer at some minutes, never at all of them.
    var seenAbove = 0, seenBelow = 0
    for minute in stride(from: 0, to: 100, by: 1) {
        let at = tle.epoch.addingTimeInterval(Double(minute) * 60)
        tracker.inView(at: at).isEmpty ? (seenBelow += 1) : (seenAbove += 1)
    }
    #expect(seenBelow > 0)
    #expect(seenAbove + seenBelow == 100)
}

@Test func tleLoaderFallsBackAndReportsTheRateLimit() async throws {
    let tle = "STARLINK-1008\n1 44714C 19074B   26327.34284722  .00001968  00000+0  15280-4 0  3271\n2 44714  53.1441  13.0854 0003533  22.8589  75.5200 15.71113710    16\n"
    @Sendable func reply(_ url: URL, _ status: Int, _ body: String) -> (Data, HTTPURLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    // Supplemental limited, standard group served.
    let fallback = try await TLELoader.load(transport: HTTPTransport { request in
        request.url!.absoluteString.contains("sup-gp") ? reply(request.url!, 403, "SupGP data has not updated\nPlease limit requests to once every 2 hours") : reply(request.url!, 200, tle)
    })
    #expect(fallback.count == 1)
    // Both limited: the server's own words reach the person.
    await #expect(throws: CelesTrakLimited(serverMessage: "Data is updated once every 2 hours.")) {
        try await TLELoader.load(transport: HTTPTransport { request in reply(request.url!, 403, "Data is updated once every 2 hours.") })
    }
}

@Test func elementCacheAvoidsRepeatDownloadsAndCoversTheRateLimit() async throws {
    let tle = "STARLINK-1008\n1 44714C 19074B   26327.34284722  .00001968  00000+0  15280-4 0  3271\n2 44714  53.1441  13.0854 0003533  22.8589  75.5200 15.71113710    16\n"
    let directory = FileManager.default.temporaryDirectory.appending(path: "starpulse-cache-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = TLECache(file: directory.appending(path: "elements.txt"))
    let calls = Counter()
    let serving = HTTPTransport { request in calls.increment(); return (Data(tle.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!) }
    let limited = HTTPTransport { request in (Data("Please limit requests to once every 2 hours".utf8), HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!) }

    let first = try await TLELoader.load(cache: cache, transport: serving)
    #expect(!first.fromCache && first.tles.count == 1 && calls.value == 1)
    let again = try await TLELoader.load(cache: cache, transport: serving)          // within 2 h: no network
    #expect(again.fromCache && calls.value == 1)
    let later = try await TLELoader.load(cache: cache, transport: limited, now: Date().addingTimeInterval(5 * 3600))
    #expect(later.fromCache && later.tles.count == 1)                                // refused, older copy still usable
    await #expect(throws: CelesTrakLimited.self) {                                    // past three days the copy is not used
        try await TLELoader.load(cache: cache, transport: limited, now: Date().addingTimeInterval(4 * 86_400))
    }
    #expect(try Data(contentsOf: cache.file).count == tle.utf8.count)               // one file, overwritten, not grown
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

@Test func snapshotsPackKindsExactlyAndStayBounded() throws {
    var map = ObstructionMap(rows: 3, cols: 3, cells: [-1, 1, 0.9, 0, 1, 0.5, 0.996, -1, 0.7])
    map.maxThetaDeg = 70; map.frame = 2
    let snapshot = ObstructionSnapshot(map: map, at: Date(timeIntervalSince1970: 7200))
    #expect(snapshot.packed.count == 3)                              // 9 cells, 4 per byte
    let back = snapshot.map
    for row in 0..<3 { for col in 0..<3 { #expect(back.kind(row: row, col: col) == map.kind(row: row, col: col)) } }
    #expect(back.maxThetaDeg == 70 && back.frame == 2)

    let directory = FileManager.default.temporaryDirectory.appending(path: "starpulse-snap-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SnapshotStore(file: directory.appending(path: "s.json"))
    var frames: [ObstructionSnapshot] = []
    frames = store.record(map, at: Date(timeIntervalSince1970: 3600 * 10), into: frames)
    frames = store.record(map, at: Date(timeIntervalSince1970: 3600 * 10 + 1800), into: frames) // same hour: skipped
    #expect(frames.count == 1)
    for hour in 11..<70 { frames = store.record(map, at: Date(timeIntervalSince1970: Double(3600 * hour)), into: frames) }
    #expect(frames.count == SnapshotStore.limit)
    #expect(store.load() == frames)                                  // what is on disk is what is in memory
    #expect(frames.first?.takenAt == Date(timeIntervalSince1970: Double(3600 * (70 - SnapshotStore.limit))))
}
