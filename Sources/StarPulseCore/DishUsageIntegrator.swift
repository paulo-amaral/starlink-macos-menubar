import Foundation

/// One minute of the dish's volume, in bytes.
public struct DishUsageBucket: Codable, Sendable, Equatable {
    public var minute: Int      // minutes since the Unix epoch, UTC
    public var down: Double
    public var up: Double
    /// How many of the 60 seconds were actually observed; the rest is a gap, not zero traffic.
    public var seconds: Int
}

/// Turns the dish's 1 Hz history ring into per-minute volume. Each call returns only
/// samples not seen before, found by the ring's absolute counter, so polling every
/// 5 s counts every second exactly once. Counting starts when the first reading
/// arrives: this is the traffic seen on this Mac, not Starlink's billing meter.
public struct DishUsageIntegrator: Sendable {
    private var lastCounter: UInt64?
    public init() {}

    public mutating func ingest(_ history: DishHistory) -> [DishUsageBucket] {
        let newest = history.newestCounter
        let count = UInt64(history.samples.count)
        guard count > 0, newest > 0 else { return [] }
        guard var last = lastCounter else { lastCounter = newest; return [] }
        // Counter went backwards: the dish rebooted and the ring restarted.
        if newest < last { last = newest > count ? newest - count : 0 }
        guard newest > last else { return [] }
        let fresh = min(newest - last, count) // samples older than the ring are lost, not guessed
        lastCounter = newest

        var buckets: [Int: DishUsageBucket] = [:]
        for sample in history.samples.suffix(Int(fresh)) {
            let minute = Int(sample.timestamp.timeIntervalSince1970 / 60)
            var bucket = buckets[minute] ?? DishUsageBucket(minute: minute, down: 0, up: 0, seconds: 0)
            bucket.down += Double(sample.downlinkBps) / 8
            bucket.up += Double(sample.uplinkBps) / 8
            bucket.seconds += 1
            buckets[minute] = bucket
        }
        return buckets.values.sorted { $0.minute < $1.minute }
    }
}
