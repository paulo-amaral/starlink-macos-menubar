import Foundation

/// The dish's 123x123 polar grid: one cell per direction, distance from the centre
/// being the zenith angle. A cell holds the usable fraction; negative means never observed.
/// Thresholds from Dishylink src/lib/obstructionSnapshots.ts (MIT).
public struct ObstructionMap: Sendable, Equatable {
    public enum Kind: Sendable { case unmapped, clear, partial, obstructed }
    static let clearFloor: Float = 0.005
    static let partialCeiling: Float = 0.25

    public var rows: Int
    public var cols: Int
    public var cells: [Float]
    /// Furthest zenith angle the grid covers, in degrees (the rim of the disc).
    public var maxThetaDeg: Float = 80
    /// ObstructionMapReferenceFrame: 1 is earth-north up, 2 is the terminal's own frame (rotated by its boresight azimuth).
    public var frame = 1
    public init(rows: Int, cols: Int, cells: [Float]) { self.rows = rows; self.cols = cols; self.cells = cells }

    public var isEmpty: Bool { rows == 0 || cols == 0 || cells.count < rows * cols }

    public func kind(row: Int, col: Int) -> Kind {
        let usable = cells[row * cols + col]
        if usable < 0 || usable.isNaN { return .unmapped }
        let obstructed = 1 - usable
        if obstructed <= Self.clearFloor { return .clear }
        return obstructed <= Self.partialCeiling ? .partial : .obstructed
    }

    /// Share of mapped cells that are partially or fully obstructed. Not the same
    /// number as the dish's own `fraction_obstructed`; both are shown, labelled.
    public var obstructedShareOfMapped: Double {
        guard !isEmpty else { return 0 }
        var mapped = 0, blocked = 0
        for row in 0..<rows { for col in 0..<cols {
            switch kind(row: row, col: col) {
            case .unmapped: break
            case .clear: mapped += 1
            case .partial, .obstructed: mapped += 1; blocked += 1
            }
        } }
        return mapped == 0 ? 0 : Double(blocked) / Double(mapped)
    }

    /// East and north fractions of the disc (each -1...1) for a cell. Ported from Dishylink
    /// src/components/obstruction/obstructionFrame.ts (MIT).
    public func eastNorth(row: Int, col: Int, boresightAzimuthDeg: Double) -> (east: Double, north: Double) {
        let centre = Double(cols - 1) / 2
        let eastGrid = (Double(col) - centre) / centre
        let northGrid = (centre - Double(row)) / centre
        guard frame == 2 else { return (eastGrid, northGrid) }
        // In the terminal's frame the page is flipped vertically; rotate by the boresight azimuth to reach compass bearings.
        let forward = -northGrid, right = eastGrid
        let a = boresightAzimuthDeg * .pi / 180
        return (right * cos(a) + forward * sin(a), -right * sin(a) + forward * cos(a))
    }

    /// Whether the dish has a usable view toward a sky direction. Mirrors Dishylink: a cell the dish
    /// never observed counts as clear, and so does anything with at most 5% obstruction.
    public func isClear(azimuthDeg: Double, elevationDeg: Double, boresightAzimuthDeg: Double) -> Bool {
        guard !isEmpty else { return true }
        let fraction = (90 - elevationDeg) / Double(maxThetaDeg)
        guard fraction <= 1 else { return true }
        let a = azimuthDeg * .pi / 180
        var east = sin(a) * fraction, north = cos(a) * fraction
        if frame == 2 {
            let b = boresightAzimuthDeg * .pi / 180
            let right = east * cos(b) - north * sin(b), forward = east * sin(b) + north * cos(b)
            east = right; north = -forward
        }
        let centre = Double(cols - 1) / 2
        let row = Int((centre - north * centre).rounded()), col = Int((centre + east * centre).rounded())
        guard (0..<rows).contains(row), (0..<cols).contains(col) else { return true }
        let usable = cells[row * cols + col]
        return usable < 0 || usable.isNaN || 1 - usable <= 0.05
    }
}
