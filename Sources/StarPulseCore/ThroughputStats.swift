import Foundation

/// Peak and average throughput per day (Dishylink issue #104): one small entry per day while StarPulse
/// runs, the newest 62 kept. The dish's sample counter makes each second count once, although the
/// ring buffer is read again every few seconds.
public struct ThroughputLedger: Codable, Sendable, Equatable {
    public static let dayLimit = 62

    struct Day: Codable, Sendable, Equatable {
        var maxDown = 0.0, maxUp = 0.0, sumDown = 0.0, sumUp = 0.0, seconds = 0
    }

    public enum Period: String, CaseIterable, Sendable {
        case today = "Today", week = "7 days", month = "This month", days30 = "30 days"
    }

    public struct Summary: Sendable, Equatable {
        public var maxDownBps: Double, averageDownBps: Double, maxUpBps: Double, averageUpBps: Double, seconds: Int
    }

    private var days: [String: Day] = [:]
    /// Dish counter of the newest sample already counted.
    private var lastSequence: UInt64?

    public init() {}

    public var dayCount: Int { days.count }

    public mutating func ingest(_ samples: [TelemetrySample], calendar: Calendar = .current) {
        if let last = lastSequence, let newest = samples.last?.sequence, newest < last { lastSequence = nil } // dish restarted
        for sample in samples where lastSequence.map({ sample.sequence > $0 }) ?? true {
            let key = Self.key(sample.timestamp, calendar)
            var day = days[key] ?? Day()
            let down = Double(sample.downlinkBps), up = Double(sample.uplinkBps)
            day.maxDown = max(day.maxDown, down); day.maxUp = max(day.maxUp, up)
            day.sumDown += down; day.sumUp += up; day.seconds += 1
            days[key] = day
            lastSequence = sample.sequence
        }
        if days.count > Self.dayLimit {
            for key in days.keys.sorted().prefix(days.count - Self.dayLimit) { days[key] = nil }
        }
    }

    public func summary(_ period: Period, now: Date, calendar: Calendar = .current) -> Summary? {
        let keys: Set<String>
        switch period {
        case .today: keys = [Self.key(now, calendar)]
        case .week, .days30:
            let count = period == .week ? 7 : 30
            keys = Set((0..<count).compactMap { calendar.date(byAdding: .day, value: -$0, to: now).map { Self.key($0, calendar) } })
        case .month:
            let prefix = String(Self.key(now, calendar).prefix(7))
            keys = Set(days.keys.filter { $0.hasPrefix(prefix) })
        }
        let chosen = days.filter { keys.contains($0.key) }.map(\.value)
        let seconds = chosen.reduce(0) { $0 + $1.seconds }
        guard seconds > 0 else { return nil }
        return Summary(maxDownBps: chosen.map(\.maxDown).max() ?? 0, averageDownBps: chosen.reduce(0) { $0 + $1.sumDown } / Double(seconds),
                       maxUpBps: chosen.map(\.maxUp).max() ?? 0, averageUpBps: chosen.reduce(0) { $0 + $1.sumUp } / Double(seconds),
                       seconds: seconds)
    }

    static func key(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// One file, rewritten in place; under 10 KB at the 62-day limit.
public struct ThroughputLedgerStore: Sendable {
    public let file: URL

    public init(file: URL) { self.file = file }

    public static var standard: ThroughputLedgerStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ThroughputLedgerStore(file: support.appending(path: "app.starpulse.mac/throughput-stats.json"))
    }

    public func load() -> ThroughputLedger {
        guard let data = try? Data(contentsOf: file), let ledger = try? JSONDecoder().decode(ThroughputLedger.self, from: data) else { return ThroughputLedger() }
        return ledger
    }

    public func save(_ ledger: ThroughputLedger) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(ledger) { try? data.write(to: file, options: .atomic) }
    }
}
