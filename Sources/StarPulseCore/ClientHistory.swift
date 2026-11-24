import Foundation

public struct ClientPoint: Sendable, Equatable {
    public var date: Date
    public var downMbps: Double
    public var upMbps: Double
}

/// Per-device rates and history, in memory only and bounded: one point per second for
/// 15 minutes, and per-minute averages for six hours. Rates come from the router's byte
/// counters (see ThroughputTracker); the router keeps no history of its own, so the
/// longer windows fill while the app is open.
public struct ClientHistory: Sendable {
    private struct Minute { var down = 0.0, up = 0.0, count = 0 }
    static let recentLimit = 900
    static let retainMinutes = 360

    private var tracker = ThroughputTracker()
    private var rates: [String: ClientRate] = [:]
    private var recent: [String: [ClientPoint]] = [:]
    private var minutes: [String: [Int: Minute]] = [:]
    private var lastPointAt: [String: Date] = [:]
    public init() {}

    /// Call on every router poll, several times a second. Returns the bytes each device moved since the previous poll.
    @discardableResult
    public mutating func record(_ clients: [WifiClient], at date: Date) -> [UInt32: UInt64] {
        let atMs = date.timeIntervalSince1970 * 1000
        var moved: [UInt32: UInt64] = [:]
        for client in clients {
            let fallback = ClientRate(downMbps: client.downAvgMbps, upMbps: client.upAvgMbps)
            let reading = tracker.read(key: client.id, rx: client.rxBytes, tx: client.txBytes, atMs: atMs, fallback: fallback)
            let rate = reading.rate
            if let id = client.clientId, reading.rxDelta + reading.txDelta > 0 { moved[id, default: 0] += reading.rxDelta + reading.txDelta }
            rates[client.id] = rate
            if let last = lastPointAt[client.id], date.timeIntervalSince(last) < 1 { continue }
            lastPointAt[client.id] = date
            recent[client.id, default: []].append(ClientPoint(date: date, downMbps: rate.downMbps, upMbps: rate.upMbps))
            if recent[client.id]!.count > Self.recentLimit { recent[client.id]!.removeFirst(recent[client.id]!.count - Self.recentLimit) }
            let minute = Int(date.timeIntervalSince1970 / 60)
            var bucket = minutes[client.id, default: [:]][minute] ?? Minute()
            bucket.down += rate.downMbps; bucket.up += rate.upMbps; bucket.count += 1
            minutes[client.id, default: [:]][minute] = bucket
            for old in minutes[client.id]!.keys where old < minute - Self.retainMinutes { minutes[client.id]![old] = nil }
        }
        let present = Set(clients.map(\.id))
        tracker.retain(present)
        rates = rates.filter { present.contains($0.key) }
        // Forget devices not seen for the whole retention window so the maps cannot grow forever.
        for id in recent.keys where !present.contains(id) {
            if (lastPointAt[id] ?? .distantPast) < date.addingTimeInterval(-Double(Self.retainMinutes * 60)) {
                recent[id] = nil; minutes[id] = nil; lastPointAt[id] = nil
            }
        }
        return moved
    }

    public func rate(for id: String) -> ClientRate { rates[id] ?? .zero }

    public func series(for id: String, range: HistoryRange, now: Date) -> [ClientPoint] {
        if range == .m15 { return (recent[id] ?? []).filter { $0.date >= now.addingTimeInterval(-900) } }
        let nowMinute = Int(now.timeIntervalSince1970 / 60)
        let first = nowMinute - range.seconds / 60 + 1
        return (first...nowMinute).compactMap { minute in
            guard let bucket = minutes[id]?[minute], bucket.count > 0 else { return nil }
            return ClientPoint(date: Date(timeIntervalSince1970: Double(minute * 60 + 30)), downMbps: bucket.down / Double(bucket.count), upMbps: bucket.up / Double(bucket.count))
        }
    }
}

public enum SignalQuality {
    /// Labels are this app's own bands, not a Starlink definition.
    public static func label(dbm: Float) -> String {
        switch dbm { case ..<(-70): "weak"; case ..<(-60): "fair"; case ..<(-50): "good"; default: "excellent" }
    }
}
