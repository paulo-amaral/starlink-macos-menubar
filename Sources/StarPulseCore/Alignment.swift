import Foundation

public struct AlignmentReading: Sendable, Equatable {
    public var isValid: Bool
    public var isAligned: Bool
    public var currentAzimuthDeg: Double
    public var currentElevationDeg: Double
    public var desiredAzimuthDeg: Double
    /// The dish's own target, unclamped (the band check uses a clamped floor).
    public var desiredElevationDeg: Double
    public var azimuthErrorDeg: Double
    public var elevationErrorDeg: Double
    /// Great-circle angle between where the dish points and where it wants to point.
    public var boresightErrorDeg: Double
    public var tiltAngleDeg: Double
}

/// The dish web app's own alignment test, ported from Dishylink
/// src/components/alignment/alignmentMath.ts (MIT). Not an interpretation: "aligned"
/// is one of three conditions on great-circle separation against a 70°..band-top
/// elevation band. Band top is 75°, or 90° for mobile installs; flat Performance
/// kits (also 90° upstream) are not detected here because the hardware table is not ported.
public enum AlignmentMath {
    static let separationLimitDeg = 5.0
    private static let rad = Double.pi / 180

    public static func separationDeg(_ azA: Double, _ elA: Double, _ azB: Double, _ elB: Double) -> Double {
        let cosine = sin(elA * rad) * sin(elB * rad) + cos(elA * rad) * cos(elB * rad) * cos((azA - azB) * rad)
        let separation = acos(min(1, max(-1, cosine))) / rad
        return separation.isNaN ? 0 : separation
    }

    /// Signed shortest way round, in (-180, 180].
    public static func wrapDegrees(_ angle: Double) -> Double {
        let wrapped = (angle.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return wrapped < 180 ? wrapped : wrapped - 360
    }

    public static func compute(_ status: DishStatus) -> AlignmentReading {
        let maxTarget = status.mobilityClass == 2 ? 90.0 : 75.0
        let desiredEl = Double(status.desiredElevationDeg)
        let targetEl = desiredEl != 0 ? min(70, desiredEl) : 70
        let desiredAz = Double(status.desiredAzimuthDeg)
        let az = Double(status.boresightAzimuthDeg), el = Double(status.boresightElevationDeg)

        let separationAtTarget = separationDeg(desiredAz, targetEl, az, el)
        let separationAtBandTop = separationDeg(desiredAz, maxTarget, az, el)
        let azimuthDiff = wrapDegrees(desiredAz - az)
        let isValid = status.attitudeState == 1 || status.attitudeState == 2
        let bandUsable = targetEl >= 50
        let effectiveAzimuthError = acos(sqrt(pow(cos(azimuthDiff * rad), 2) * pow(cos(el * rad), 2) + pow(sin(el * rad), 2))) / rad

        let alignedAtTarget = isValid && separationAtTarget < separationLimitDeg
        let alignedAtBandTop = isValid && bandUsable && separationAtBandTop < separationLimitDeg
        let alignedInsideBand = isValid && bandUsable && el > targetEl && el < maxTarget
            && abs(azimuthDiff) < 90 && abs(effectiveAzimuthError) < separationLimitDeg

        let reportedEl = desiredEl != 0 ? desiredEl : el
        return AlignmentReading(
            isValid: isValid,
            isAligned: alignedAtTarget || alignedAtBandTop || alignedInsideBand,
            currentAzimuthDeg: az, currentElevationDeg: el,
            desiredAzimuthDeg: desiredAz, desiredElevationDeg: reportedEl,
            azimuthErrorDeg: wrapDegrees(az - desiredAz), elevationErrorDeg: el - reportedEl,
            boresightErrorDeg: separationDeg(az, el, desiredAz, reportedEl),
            tiltAngleDeg: Double(status.tiltAngleDeg)
        )
    }
}
