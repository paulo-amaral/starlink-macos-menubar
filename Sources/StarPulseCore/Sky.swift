import Foundation

public struct Observer: Sendable, Equatable {
    public var latitudeDeg: Double
    public var longitudeDeg: Double
    public var altitudeKm: Double
    public init(latitudeDeg: Double, longitudeDeg: Double, altitudeKm: Double = 0) {
        self.latitudeDeg = latitudeDeg; self.longitudeDeg = longitudeDeg; self.altitudeKm = altitudeKm
    }
}

public struct SatelliteSky: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public var name: String
    public var azimuthDeg: Double
    public var elevationDeg: Double
    public var rangeKm: Double
}

public enum SkyMath {
    private static let wgs84A = 6378.137
    private static let wgs84F = 1 / 298.257223563

    /// Greenwich mean sidereal time in radians (Vallado), taking UTC as UT1.
    public static func gmst(_ date: Date) -> Double {
        let julian = date.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let t = (julian - 2_451_545.0) / 36_525
        let seconds = 67_310.54841 + (876_600 * 3_600 + 8_640_184.812866) * t + 0.093104 * t * t - 6.2e-6 * t * t * t
        let radians = (seconds * 2 * .pi / 86_400).truncatingRemainder(dividingBy: 2 * .pi)
        return radians < 0 ? radians + 2 * .pi : radians
    }

    public static func ecef(of observer: Observer) -> SIMD3<Double> {
        let phi = observer.latitudeDeg * .pi / 180, lambda = observer.longitudeDeg * .pi / 180
        let e2 = wgs84F * (2 - wgs84F)
        let n = wgs84A / (1 - e2 * sin(phi) * sin(phi)).squareRoot()
        return SIMD3((n + observer.altitudeKm) * cos(phi) * cos(lambda),
                     (n + observer.altitudeKm) * cos(phi) * sin(lambda),
                     (n * (1 - e2) + observer.altitudeKm) * sin(phi))
    }

    /// Azimuth (from north, clockwise), elevation and range of a TEME position as seen from the observer.
    /// Precession, nutation and polar motion are ignored: worth tens of metres, well under a TLE's own error.
    public static func lookAngles(teme: SIMD3<Double>, at date: Date, observer: Observer, observerECEF: SIMD3<Double>? = nil, gmst: Double? = nil) -> (azimuthDeg: Double, elevationDeg: Double, rangeKm: Double) {
        let theta = gmst ?? Self.gmst(date)
        let satellite = SIMD3(teme.x * cos(theta) + teme.y * sin(theta), -teme.x * sin(theta) + teme.y * cos(theta), teme.z)
        let delta = satellite - (observerECEF ?? ecef(of: observer))
        let phi = observer.latitudeDeg * .pi / 180, lambda = observer.longitudeDeg * .pi / 180
        let east = -sin(lambda) * delta.x + cos(lambda) * delta.y
        let north = -sin(phi) * cos(lambda) * delta.x - sin(phi) * sin(lambda) * delta.y + cos(phi) * delta.z
        let up = cos(phi) * cos(lambda) * delta.x + cos(phi) * sin(lambda) * delta.y + sin(phi) * delta.z
        let range = (delta * delta).sum().squareRoot()
        var azimuth = atan2(east, north) * 180 / .pi
        if azimuth < 0 { azimuth += 360 }
        return (azimuth, asin(up / range) * 180 / .pi, range)
    }
}

/// Starlink reassigns terminals on 15 second boundaries against a clock every terminal shares, so the
/// serving guess is made when the slot turns over and held until the next (Dishylink src/lib/servingSlot.ts, MIT).
/// This is an inference: the dish does not report which satellite it uses.
public struct ServingChooser: Sendable {
    public static let slotSeconds = 15.0
    /// Starlink's approximate minimum service elevation.
    public static let elevationFloorDeg = 25.0

    private var hold: (slot: Int, name: String)?
    public init() {}

    /// `inView` must be sorted by elevation, highest first.
    public mutating func choose(inView: [SatelliteSky], at date: Date, isClear: (SatelliteSky) -> Bool) -> SatelliteSky? {
        let slot = Int((date.timeIntervalSince1970 / Self.slotSeconds).rounded(.down))
        if let hold, hold.slot == slot, let held = inView.first(where: { $0.name == hold.name }), held.elevationDeg >= Self.elevationFloorDeg, isClear(held) {
            return held
        }
        var best: SatelliteSky?
        for sat in inView {
            if sat.elevationDeg < Self.elevationFloorDeg { break }
            if isClear(sat) { best = sat; break }
        }
        if best == nil, let highest = inView.first, highest.elevationDeg >= Self.elevationFloorDeg { best = highest }
        hold = best.map { (slot, $0.name) }
        return best
    }
}

public struct StarlinkTracker: Sendable {
    private struct Entry: Sendable { var name: String; var sgp4: SGP4 }
    private let entries: [Entry]
    public let observer: Observer

    /// Element sets that cannot be propagated (deep space, malformed) are skipped.
    public init(tles: [TLE], observer: Observer) {
        self.observer = observer
        entries = tles.compactMap { tle in (try? SGP4(tle)).map { Entry(name: tle.name, sgp4: $0) } }
    }

    public var constellationSize: Int { entries.count }

    /// Satellites above `minElevationDeg`, highest first.
    public func inView(at date: Date, minElevationDeg: Double = 0) -> [SatelliteSky] {
        let theta = SkyMath.gmst(date)
        let observerECEF = SkyMath.ecef(of: observer)
        var visible: [SatelliteSky] = []
        for entry in entries {
            guard let state = entry.sgp4.propagate(at: date) else { continue }
            let look = SkyMath.lookAngles(teme: state.position, at: date, observer: observer, observerECEF: observerECEF, gmst: theta)
            if look.elevationDeg >= minElevationDeg {
                visible.append(SatelliteSky(name: entry.name, azimuthDeg: look.azimuthDeg, elevationDeg: look.elevationDeg, rangeKm: look.rangeKm))
            }
        }
        return visible.sorted { $0.elevationDeg > $1.elevationDeg }
    }
}

public struct CelesTrakLimited: Error, LocalizedError, Equatable {
    public var serverMessage: String
    public var errorDescription: String? {
        "CelesTrak allows one download of each data set every 2 hours, and both were used recently. \(serverMessage)"
    }
}

/// Element sets for the Starlink constellation. CelesTrak's supplemental set (supplied by SpaceX, the one
/// Dishylink uses) is tried first, then the standard GP group. CelesTrak answers 403 when the same data set
/// is requested again before it updates (every 2 hours). Held in memory only; the requests carry no location.
public enum TLELoader {
    public static let sources = [
        URL(string: "https://celestrak.org/NORAD/elements/supplemental/sup-gp.php?FILE=starlink&FORMAT=tle")!,
        URL(string: "https://celestrak.org/NORAD/elements/gp.php?GROUP=starlink&FORMAT=tle")!,
    ]

    public static func load(transport: HTTPTransport = .live) async throws -> [TLE] {
        TLE.parse(try await download(transport: transport))
    }

    /// Raw three line text from the first source that answers with element sets.
    static func download(transport: HTTPTransport) async throws -> String {
        var limitedMessage: String?
        for url in sources {
            var request = URLRequest(url: url, timeoutInterval: 60)
            request.setValue("StarPulse", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await transport.send(request)
            let text = String(decoding: data, as: UTF8.self)
            if (200..<300).contains(response.statusCode) {
                if !TLE.parse(text).isEmpty { return text }
            } else if response.statusCode == 403 {
                limitedMessage = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            }
        }
        if let limitedMessage { throw CelesTrakLimited(serverMessage: limitedMessage) }
        throw URLError(.badServerResponse)
    }
}

public struct TLECache: Sendable {
    public let file: URL
    /// CelesTrak updates the sets every 2 hours; a newer download is refused, so nothing fresher exists.
    public static let freshFor: TimeInterval = 2 * 3600
    /// Elements drift by roughly a kilometre a day; past three days the sky view would mislead.
    public static let usableFor: TimeInterval = 3 * 86_400

    public init(file: URL) { self.file = file }

    public static var standard: TLECache {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return TLECache(file: caches.appending(path: "app.starpulse.mac/starlink-elements.txt"))
    }

    func read(maxAge: TimeInterval, now: Date) -> (text: String, savedAt: Date)? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              let saved = attributes[.modificationDate] as? Date, now.timeIntervalSince(saved) <= maxAge,
              let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return (text, saved)
    }

    func write(_ text: String) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: file, options: .atomic)
    }
}

public struct ElementLoad: Sendable {
    public var tles: [TLE]
    /// When these elements were downloaded from CelesTrak.
    public var downloadedAt: Date
    public var fromCache: Bool
}

extension TLELoader {
    /// Uses the cache while it is newer than CelesTrak's update cycle, downloads otherwise, and falls back to
    /// an older cached copy (up to three days) when CelesTrak refuses or the network fails.
    public static func load(cache: TLECache, transport: HTTPTransport = .live, now: Date = Date()) async throws -> ElementLoad {
        if let fresh = cache.read(maxAge: TLECache.freshFor, now: now) {
            let tles = TLE.parse(fresh.text)
            if !tles.isEmpty { return ElementLoad(tles: tles, downloadedAt: fresh.savedAt, fromCache: true) }
        }
        do {
            let text = try await download(transport: transport)
            cache.write(text)
            return ElementLoad(tles: TLE.parse(text), downloadedAt: now, fromCache: false)
        } catch {
            if let old = cache.read(maxAge: TLECache.usableFor, now: now) {
                let tles = TLE.parse(old.text)
                if !tles.isEmpty { return ElementLoad(tles: tles, downloadedAt: old.savedAt, fromCache: true) }
            }
            throw error
        }
    }
}
