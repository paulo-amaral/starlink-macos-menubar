import Foundation

public enum HistoryRange: CaseIterable, Sendable {
    case m15, h1, h6
    public var label: String { switch self { case .m15: "15M"; case .h1: "1H"; case .h6: "6H" } }
    public var seconds: Int { switch self { case .m15: 900; case .h1: 3600; case .h6: 21_600 } }
}

public struct LatencyPoint: Sendable, Equatable { public var date: Date; public var ms: Double }

public struct LatencyWindow: Sendable, Equatable {
    public var starlink: [LatencyPoint] = []
    public var router: [LatencyPoint] = []
    public var average: Double?
    public var current: Double?
    /// Share of the window's minutes that hold data. Below 1 right after launch: history lives in memory only.
    public var coverage: Double = 0
    /// Percent of samples per 5 ms bin, 0-5 ms up to a final "100+" bin; each sums to 100.
    public var starlinkHistogram: [Double] = []
    public var routerHistogram: [Double] = []
}

/// Latency kept in memory only, bounded to six hours of one-minute buckets. The dish
/// supplies its own 15 minute ring, the router has no buffer, so anything longer than
/// 15 minutes starts filling when the app opens; nothing is written to disk.
public struct LatencyHistory: Sendable {
    static let binCount = 21
    static let binWidthMs = 5.0
    static let retainMinutes = 360

    struct Bucket: Sendable {
        var sum = 0.0
        var count = 0
        var bins = [UInt32](repeating: 0, count: LatencyHistory.binCount)
        mutating func add(_ ms: Double) {
            sum += ms; count += 1
            bins[min(LatencyHistory.binCount - 1, Int(ms / LatencyHistory.binWidthMs))] += 1
        }
    }

    private var dish: [Int: Bucket] = [:]
    private var router: [Int: Bucket] = [:]
    private var routerRecent: [LatencyPoint] = []
    private var lastCounter: UInt64?
    public init() {}

    /// Adds only samples not seen before, found by the ring's absolute counter.
    public mutating func ingestDish(_ history: DishHistory) {
        let newest = history.newestCounter
        let count = UInt64(history.samples.count)
        guard count > 0, newest > 0 else { return }
        var last = lastCounter ?? (newest > count ? newest - count : 0)
        if newest < last { last = newest > count ? newest - count : 0 } // dish rebooted
        guard newest > last else { return }
        let fresh = Int(min(newest - last, count))
        lastCounter = newest
        for sample in history.samples.suffix(fresh) {
            guard let ms = sample.latencyMs else { continue } // an outage second is not a latency
            dish[Int(sample.timestamp.timeIntervalSince1970 / 60), default: Bucket()].add(Double(ms))
        }
        prune(&dish, newestMinute: Int((history.samples.last?.timestamp ?? Date()).timeIntervalSince1970 / 60))
    }

    public mutating func recordRouter(_ ms: Float, at date: Date) {
        guard ms.isFinite, ms > 0 else { return }
        router[Int(date.timeIntervalSince1970 / 60), default: Bucket()].add(Double(ms))
        routerRecent.append(LatencyPoint(date: date, ms: Double(ms)))
        if routerRecent.count > 900 { routerRecent.removeFirst(routerRecent.count - 900) }
        prune(&router, newestMinute: Int(date.timeIntervalSince1970 / 60))
    }

    private func prune(_ buckets: inout [Int: Bucket], newestMinute: Int) {
        for minute in buckets.keys where minute < newestMinute - Self.retainMinutes { buckets[minute] = nil }
    }

    public func window(_ range: HistoryRange, dishSamples: [TelemetrySample], now: Date) -> LatencyWindow {
        let nowMinute = Int(now.timeIntervalSince1970 / 60)
        let firstMinute = nowMinute - range.seconds / 60 + 1
        var window = LatencyWindow()

        func points(_ buckets: [Int: Bucket]) -> [LatencyPoint] {
            (firstMinute...nowMinute).compactMap { minute in
                buckets[minute].flatMap { $0.count > 0 ? LatencyPoint(date: Date(timeIntervalSince1970: Double(minute * 60 + 30)), ms: $0.sum / Double($0.count)) : nil }
            }
        }
        func histogram(_ buckets: [Int: Bucket]) -> [Double] {
            var bins = [UInt32](repeating: 0, count: Self.binCount)
            for minute in firstMinute...nowMinute { if let bucket = buckets[minute] { for i in bins.indices { bins[i] += bucket.bins[i] } } }
            let total = Double(bins.reduce(0, +))
            return total == 0 ? [] : bins.map { 100 * Double($0) / total }
        }

        if range == .m15 {
            window.starlink = dishSamples.compactMap { sample in sample.latencyMs.map { LatencyPoint(date: sample.timestamp, ms: Double($0)) } }
            window.router = routerRecent.filter { $0.date >= now.addingTimeInterval(-900) }
        } else {
            window.starlink = points(dish)
            window.router = points(router)
        }
        let minutesWithData = (firstMinute...nowMinute).filter { (dish[$0]?.count ?? 0) > 0 }.count
        window.coverage = Double(minutesWithData) / Double(range.seconds / 60)
        let (sum, count) = (firstMinute...nowMinute).reduce((0.0, 0)) { acc, minute in
            guard let bucket = dish[minute] else { return acc }
            return (acc.0 + bucket.sum, acc.1 + bucket.count)
        }
        window.average = count > 0 ? sum / Double(count) : nil
        window.current = dishSamples.last(where: { $0.latencyMs != nil })?.latencyMs.map(Double.init)
        window.starlinkHistogram = histogram(dish)
        window.routerHistogram = histogram(router)
        return window
    }
}
