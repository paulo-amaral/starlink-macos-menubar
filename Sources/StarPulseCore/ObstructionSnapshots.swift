import Foundation

/// One hourly frame of the obstruction map for the time-lapse. Each cell is quantized to 2 bits
/// (unmapped, clear, partial, obstructed) and packed four to a byte, as Dishylink's historian does
/// (collector/obstructionStore.mts, MIT), so a 123x123 grid takes under 4 KB.
public struct ObstructionSnapshot: Codable, Sendable, Equatable {
    public var takenAt: Date
    public var rows: Int
    public var cols: Int
    public var maxThetaDeg: Float
    public var frame: Int
    public var packed: Data

    public init(map: ObstructionMap, at date: Date) {
        takenAt = date; rows = map.rows; cols = map.cols; maxThetaDeg = map.maxThetaDeg; frame = map.frame
        var bytes = [UInt8](repeating: 0, count: (map.rows * map.cols + 3) / 4)
        for row in 0..<map.rows { for col in 0..<map.cols {
            let code: UInt8 = switch map.kind(row: row, col: col) { case .unmapped: 0; case .clear: 1; case .partial: 2; case .obstructed: 3 }
            let index = row * map.cols + col
            bytes[index / 4] |= code << UInt8((index % 4) * 2)
        } }
        packed = Data(bytes)
    }

    /// Back to a map whose cells classify exactly as the stored kinds did.
    public var map: ObstructionMap {
        let bytes = [UInt8](packed)
        let usable: [Float] = (0..<(rows * cols)).map { index in
            switch (bytes[index / 4] >> UInt8((index % 4) * 2)) & 0b11 {
            case 1: 1       // clear
            case 2: 0.9     // partial: 10% blocked
            case 3: 0       // obstructed
            default: -1     // never observed
            }
        }
        var map = ObstructionMap(rows: rows, cols: cols, cells: usable)
        map.maxThetaDeg = maxThetaDeg
        map.frame = frame
        return map
    }
}

/// The time-lapse frames: at most one per hour, the newest 48 kept, in a single file that is
/// rewritten in place and never grows past about 250 KB. This is history the dish does not keep.
public struct SnapshotStore: Sendable {
    public static let limit = 48
    public let file: URL

    public init(file: URL) { self.file = file }

    public static var standard: SnapshotStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return SnapshotStore(file: support.appending(path: "app.starpulse.mac/obstruction-snapshots.json"))
    }

    public func load() -> [ObstructionSnapshot] {
        guard let data = try? Data(contentsOf: file),
              let snapshots = try? JSONDecoder().decode([ObstructionSnapshot].self, from: data) else { return [] }
        return snapshots.sorted { $0.takenAt < $1.takenAt }
    }

    /// Adds a frame unless one was already taken this clock hour. Returns the frames now stored.
    @discardableResult
    public func record(_ map: ObstructionMap, at date: Date, into existing: [ObstructionSnapshot]) -> [ObstructionSnapshot] {
        guard !map.isEmpty else { return existing }
        let hour = Int(date.timeIntervalSince1970 / 3600)
        if let last = existing.last, Int(last.takenAt.timeIntervalSince1970 / 3600) == hour { return existing }
        let updated = Array((existing + [ObstructionSnapshot(map: map, at: date)]).suffix(Self.limit))
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(updated) { try? data.write(to: file, options: .atomic) }
        return updated
    }
}
