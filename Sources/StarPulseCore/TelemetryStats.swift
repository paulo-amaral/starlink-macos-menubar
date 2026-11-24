import Foundation

/// The figures behind the Statistics cards, over the dish's 15 minute ring.
public struct TelemetryStats: Sendable, Equatable {
    public var pingSuccessPercent: Double?
    public var medianLatencyMs: Double?
    public var averagePowerW: Double?
    public var averageDownlinkBps: Double = 0
    public var averageUplinkBps: Double = 0
    public var eventsLastDay = 0

    public static func compute(samples: [TelemetrySample], events: [DishEvent], now: Date) -> TelemetryStats {
        var stats = TelemetryStats()
        if !samples.isEmpty {
            stats.pingSuccessPercent = 100 * (1 - samples.map { Double($0.dropRate) }.reduce(0, +) / Double(samples.count))
            stats.averageDownlinkBps = samples.map { Double($0.downlinkBps) }.reduce(0, +) / Double(samples.count)
            stats.averageUplinkBps = samples.map { Double($0.uplinkBps) }.reduce(0, +) / Double(samples.count)
        }
        let latencies = samples.compactMap { $0.latencyMs.map(Double.init) }.sorted()
        if !latencies.isEmpty {
            let middle = latencies.count / 2
            stats.medianLatencyMs = latencies.count.isMultiple(of: 2) ? (latencies[middle - 1] + latencies[middle]) / 2 : latencies[middle]
        }
        // Zero power means the firmware reported nothing, not a dish drawing 0 W.
        let power = samples.map { Double($0.powerW) }.filter { $0 > 0 }
        if !power.isEmpty { stats.averagePowerW = power.reduce(0, +) / Double(power.count) }
        let dayAgo = now.addingTimeInterval(-86_400)
        stats.eventsLastDay = events.filter { $0.start >= dayAgo }.count
        return stats
    }
}
