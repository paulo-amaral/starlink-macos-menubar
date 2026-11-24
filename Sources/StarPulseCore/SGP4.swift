import Foundation

public enum TLEError: Error, Equatable { case badFormat, deepSpace }

/// A two line element set. Column positions follow the NORAD format.
public struct TLE: Sendable, Equatable {
    public var name: String
    public var epoch: Date
    public var bstar: Double
    public var inclination: Double   // radians
    public var raan: Double          // radians
    public var eccentricity: Double
    public var argumentOfPerigee: Double // radians
    public var meanAnomaly: Double   // radians
    public var meanMotion: Double    // radians per minute (Kozai mean motion)

    public init(name: String, line1: String, line2: String) throws {
        func field(_ line: String, _ range: Range<Int>) throws -> String {
            let chars = Array(line)
            guard chars.count >= range.upperBound else { throw TLEError.badFormat }
            return String(chars[range]).trimmingCharacters(in: .whitespaces)
        }
        func number(_ text: String) throws -> Double {
            guard let value = Double(text) else { throw TLEError.badFormat }
            return value
        }
        guard line1.hasPrefix("1 "), line2.hasPrefix("2 ") else { throw TLEError.badFormat }
        let year = try number(try field(line1, 18..<20))
        let day = try number(try field(line1, 20..<32))
        // The bstar drag term is stored as a mantissa with an implied decimal point and an exponent: " 15280-4".
        let bstarText = try field(line1, 53..<61)
        guard let split = bstarText.dropFirst().lastIndex(where: { $0 == "-" || $0 == "+" }) else { throw TLEError.badFormat }
        let mantissa = try number("0." + bstarText[..<split].filter { $0.isNumber })
        let exponent = try number(String(bstarText[split...]))
        let sign: Double = bstarText.hasPrefix("-") ? -1 : 1

        let fullYear = year < 57 ? 2000 + year : 1900 + year
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let jan1 = calendar.date(from: DateComponents(year: Int(fullYear), month: 1, day: 1)) else { throw TLEError.badFormat }

        self.name = name
        self.epoch = jan1.addingTimeInterval((day - 1) * 86_400)
        self.bstar = sign * mantissa * pow(10, exponent)
        let toRadians = Double.pi / 180
        self.inclination = try number(try field(line2, 8..<16)) * toRadians
        self.raan = try number(try field(line2, 17..<25)) * toRadians
        self.eccentricity = try number("0." + (try field(line2, 26..<33)))
        self.argumentOfPerigee = try number(try field(line2, 34..<42)) * toRadians
        self.meanAnomaly = try number(try field(line2, 43..<51)) * toRadians
        self.meanMotion = try number(try field(line2, 52..<63)) * 2 * .pi / 1440
    }

    /// Reads a CelesTrak three line file: a name line, then lines 1 and 2. Bad entries are skipped.
    public static func parse(_ text: String) -> [TLE] {
        let lines = text.split(whereSeparator: \.isNewline).map { String($0) }
        var result: [TLE] = []
        var index = 0
        while index + 2 < lines.count {
            if let tle = try? TLE(name: lines[index].trimmingCharacters(in: .whitespaces), line1: lines[index + 1], line2: lines[index + 2]) {
                result.append(tle); index += 3
            } else { index += 1 }
        }
        return result
    }
}

/// SGP4 for near-earth orbits (period under 225 minutes, which covers every Starlink satellite),
/// after Spacetrack Report #3 as revised by Vallado et al. (WGS-72 constants). Deep-space
/// orbits need the SDP4 extension and are rejected. Position in km and velocity in km/s, in the TEME frame.
public struct SGP4: Sendable {
    private static let radiusEarthKm = 6378.135
    private static let mu = 398_600.8
    private static let xke = 60 / sqrt(pow(radiusEarthKm, 3) / mu)
    private static let j2 = 0.001082616
    private static let j3 = -0.00000253881
    private static let j4 = -0.00000165597
    private static let j3oj2 = j3 / j2
    private static let x2o3 = 2.0 / 3.0
    private static let twoPi = 2 * Double.pi

    private let bstar, ecco, argpo, inclo, mo, nodeo, no: Double
    private let isimp: Bool
    private let cc1, cc4, cc5, d2, d3, d4, t2cof, t3cof, t4cof, t5cof: Double
    private let omgcof, xmcof, nodecf, eta, delmo, sinmao, aycof, xlcof: Double
    private let con41, x1mth2, x7thm1, mdot, argpdot, nodedot: Double

    public let epoch: Date

    public init(_ tle: TLE) throws {
        let (xke, j2, j3oj2, j4, radius) = (Self.xke, Self.j2, Self.j3oj2, Self.j4, Self.radiusEarthKm)
        bstar = tle.bstar; ecco = tle.eccentricity; argpo = tle.argumentOfPerigee
        inclo = tle.inclination; mo = tle.meanAnomaly; nodeo = tle.raan; epoch = tle.epoch

        // initl: recover the original (un-Kozai) mean motion and semi-major axis.
        let eccsq = ecco * ecco, omeosq = 1 - eccsq, rteosq = omeosq.squareRoot()
        let cosio = cos(inclo), cosio2 = cosio * cosio
        var ak = pow(xke / tle.meanMotion, Self.x2o3)
        let d1 = 0.75 * j2 * (3 * cosio2 - 1) / (rteosq * omeosq)
        var del = d1 / (ak * ak)
        let adel = ak * (1 - del * del - del * (1.0 / 3.0 + 134 * del * del / 81))
        del = d1 / (adel * adel)
        no = tle.meanMotion / (1 + del)
        ak = pow(xke / no, Self.x2o3)
        let ao = ak
        guard Self.twoPi / no < 225 else { throw TLEError.deepSpace }
        let sinio = sin(inclo)
        let po = ao * omeosq
        let con42 = 1 - 5 * cosio2
        con41 = -con42 - cosio2 - cosio2
        let posq = po * po
        let rp = ao * (1 - ecco)

        // Atmospheric drag model: the "s" parameter depends on the perigee height.
        let ss = 78.0 / radius + 1
        let qzms2t = pow((120 - 78) / radius, 4)
        let perige = (rp - 1) * radius
        var sfour = ss, qzms24 = qzms2t
        if perige < 156 {
            sfour = perige - 78
            if perige < 98 { sfour = 20 }
            qzms24 = pow((120 - sfour) / radius, 4)
            sfour = sfour / radius + 1
        }
        let pinvsq = 1 / posq
        let tsi = 1 / (ao - sfour)
        eta = ao * ecco * tsi
        let etasq = eta * eta, eeta = ecco * eta, psisq = abs(1 - etasq)
        let coef = qzms24 * pow(tsi, 4)
        let coef1 = coef / pow(psisq, 3.5)
        let cc2 = coef1 * no * (ao * (1 + 1.5 * etasq + eeta * (4 + etasq)) + 0.375 * j2 * tsi / psisq * con41 * (8 + 3 * etasq * (8 + etasq)))
        cc1 = bstar * cc2
        let cc3 = ecco > 1e-4 ? -2 * coef * tsi * j3oj2 * no * sinio / ecco : 0
        x1mth2 = 1 - cosio2
        cc4 = 2 * no * coef1 * ao * omeosq * (eta * (2 + 0.5 * etasq) + ecco * (0.5 + 2 * etasq)
            - j2 * tsi / (ao * psisq) * (-3 * con41 * (1 - 2 * eeta + etasq * (1.5 - 0.5 * eeta))
            + 0.75 * x1mth2 * (2 * etasq - eeta * (1 + etasq)) * cos(2 * argpo)))
        cc5 = 2 * coef1 * ao * omeosq * (1 + 2.75 * (etasq + eeta) + eeta * etasq)

        let cosio4 = cosio2 * cosio2
        let temp1 = 1.5 * j2 * pinvsq * no
        let temp2 = 0.5 * temp1 * j2 * pinvsq
        let temp3 = -0.46875 * j4 * pinvsq * pinvsq * no
        mdot = no + 0.5 * temp1 * rteosq * con41 + 0.0625 * temp2 * rteosq * (13 - 78 * cosio2 + 137 * cosio4)
        argpdot = -0.5 * temp1 * con42 + 0.0625 * temp2 * (7 - 114 * cosio2 + 395 * cosio4) + temp3 * (3 - 36 * cosio2 + 49 * cosio4)
        let xhdot1 = -temp1 * cosio
        nodedot = xhdot1 + (0.5 * temp2 * (4 - 19 * cosio2) + 2 * temp3 * (3 - 7 * cosio2)) * cosio
        omgcof = bstar * cc3 * cos(argpo)
        xmcof = ecco > 1e-4 ? -Self.x2o3 * coef * bstar / eeta : 0
        nodecf = 3.5 * omeosq * xhdot1 * cc1
        t2cof = 1.5 * cc1
        xlcof = abs(cosio + 1) > 1.5e-12 ? -0.25 * j3oj2 * sinio * (3 + 5 * cosio) / (1 + cosio) : -0.25 * j3oj2 * sinio * (3 + 5 * cosio) / 1.5e-12
        aycof = -0.5 * j3oj2 * sinio
        delmo = pow(1 + eta * cos(mo), 3)
        sinmao = sin(mo)
        x7thm1 = 7 * cosio2 - 1

        // Orbits that pass below 220 km use the simplified drag expansion.
        isimp = rp < 220 / radius + 1
        if !isimp {
            let cc1sq = cc1 * cc1
            d2 = 4 * ao * tsi * cc1sq
            let temp = d2 * tsi * cc1 / 3
            d3 = (17 * ao + sfour) * temp
            d4 = 0.5 * temp * ao * tsi * (221 * ao + 31 * sfour) * cc1
            t3cof = d2 + 2 * cc1sq
            t4cof = 0.25 * (3 * d3 + cc1 * (12 * d2 + 10 * cc1sq))
            t5cof = 0.2 * (3 * d4 + 12 * cc1 * d3 + 6 * d2 * d2 + 15 * cc1sq * (2 * d2 + cc1sq))
        } else {
            d2 = 0; d3 = 0; d4 = 0; t3cof = 0; t4cof = 0; t5cof = 0
        }
    }

    /// State `minutes` after the element epoch, or nil if the orbit has decayed or the elements diverge.
    public func propagate(minutes t: Double) -> (position: SIMD3<Double>, velocity: SIMD3<Double>)? {
        let (xke, j2, radius) = (Self.xke, Self.j2, Self.radiusEarthKm)
        let vkmpersec = radius * xke / 60

        // Secular gravity and atmospheric drag.
        let xmdf = mo + mdot * t
        let argpdf = argpo + argpdot * t
        let nodedf = nodeo + nodedot * t
        var argpm = argpdf, mm = xmdf
        let t2 = t * t
        var nodem = nodedf + nodecf * t2
        var tempa = 1 - cc1 * t
        var tempe = bstar * cc4 * t
        var templ = t2cof * t2
        if !isimp {
            let delomg = omgcof * t
            let delm = xmcof * (pow(1 + eta * cos(xmdf), 3) - delmo)
            let temp = delomg + delm
            mm = xmdf + temp
            argpm = argpdf - temp
            let t3 = t2 * t, t4 = t3 * t
            tempa = tempa - d2 * t2 - d3 * t3 - d4 * t4
            tempe += bstar * cc5 * (sin(mm) - sinmao)
            templ += t3cof * t3 + t4 * (t4cof + t * t5cof)
        }
        var nm = no
        var em = ecco
        guard nm > 0 else { return nil }
        let am = pow(xke / nm, Self.x2o3) * tempa * tempa
        nm = xke / pow(am, 1.5)
        em -= tempe
        guard em < 1, em >= -0.001 else { return nil }
        if em < 1e-6 { em = 1e-6 }
        mm += no * templ
        var xlm = mm + argpm + nodem
        nodem = nodem.truncatingRemainder(dividingBy: Self.twoPi)
        argpm = argpm.truncatingRemainder(dividingBy: Self.twoPi)
        xlm = xlm.truncatingRemainder(dividingBy: Self.twoPi)
        mm = (xlm - argpm - nodem).truncatingRemainder(dividingBy: Self.twoPi)

        let sinip = sin(inclo), cosip = cos(inclo)
        let ep = em, nodep = nodem, argpp = argpm, mp = mm

        // Long-period periodics, then Kepler's equation.
        let axnl = ep * cos(argpp)
        var temp = 1 / (am * (1 - ep * ep))
        let aynl = ep * sin(argpp) + temp * aycof
        let xl = mp + argpp + nodep + temp * xlcof * axnl
        let u = (xl - nodep).truncatingRemainder(dividingBy: Self.twoPi)
        var eo1 = u, tem5 = 9999.9, ktr = 1
        var sineo1 = 0.0, coseo1 = 0.0
        while abs(tem5) >= 1e-12, ktr <= 10 {
            sineo1 = sin(eo1); coseo1 = cos(eo1)
            tem5 = 1 - coseo1 * axnl - sineo1 * aynl
            tem5 = (u - aynl * coseo1 + axnl * sineo1 - eo1) / tem5
            if abs(tem5) >= 0.95 { tem5 = tem5 > 0 ? 0.95 : -0.95 }
            eo1 += tem5
            ktr += 1
        }

        // Short-period preliminary quantities.
        let ecose = axnl * coseo1 + aynl * sineo1
        let esine = axnl * sineo1 - aynl * coseo1
        let el2 = axnl * axnl + aynl * aynl
        let pl = am * (1 - el2)
        guard pl >= 0 else { return nil }
        let rl = am * (1 - ecose)
        let rdotl = am.squareRoot() * esine / rl
        let rvdotl = pl.squareRoot() / rl
        let betal = (1 - el2).squareRoot()
        temp = esine / (1 + betal)
        let sinu = am / rl * (sineo1 - aynl - axnl * temp)
        let cosu = am / rl * (coseo1 - axnl + aynl * temp)
        var su = atan2(sinu, cosu)
        let sin2u = (cosu + cosu) * sinu
        let cos2u = 1 - 2 * sinu * sinu
        temp = 1 / pl
        let temp1 = 0.5 * j2 * temp
        let temp2 = temp1 * temp

        // Short-period periodics.
        let mrt = rl * (1 - 1.5 * temp2 * betal * con41) + 0.5 * temp1 * x1mth2 * cos2u
        su -= 0.25 * temp2 * x7thm1 * sin2u
        let xnode = nodep + 1.5 * temp2 * cosip * sin2u
        let xinc = inclo + 1.5 * temp2 * cosip * sinip * cos2u
        let mvt = rdotl - nm * temp1 * x1mth2 * sin2u / xke
        let rvdot = rvdotl + nm * temp1 * (x1mth2 * cos2u + 1.5 * con41) / xke

        // Orientation vectors.
        let sinsu = sin(su), cossu = cos(su), snod = sin(xnode), cnod = cos(xnode)
        let sini = sin(xinc), cosi = cos(xinc)
        let xmx = -snod * cosi, xmy = cnod * cosi
        let ux = xmx * sinsu + cnod * cossu, uy = xmy * sinsu + snod * cossu, uz = sini * sinsu
        let vx = xmx * cossu - cnod * sinsu, vy = xmy * cossu - snod * sinsu, vz = sini * cossu
        guard mrt >= 1 else { return nil } // below the Earth's surface: decayed
        let position = SIMD3(mrt * ux, mrt * uy, mrt * uz) * radius
        let velocity = SIMD3(mvt * ux + rvdot * vx, mvt * uy + rvdot * vy, mvt * uz + rvdot * vz) * vkmpersec
        return (position, velocity)
    }

    public func propagate(at date: Date) -> (position: SIMD3<Double>, velocity: SIMD3<Double>)? {
        propagate(minutes: date.timeIntervalSince(epoch) / 60)
    }
}
