import Foundation

/// Turns a per-second flag (outage, high loss, high latency) into at most one "started" and one
/// "ended" event per episode. Short episodes are routine on Starlink (handoffs, brief
/// obstructions), so "started" waits until the condition has lasted `threshold` seconds, and
/// "ended" follows only an announced episode.
public struct ConditionWatch: Sendable {
    public enum Event: Equatable, Sendable {
        case started(since: Date)
        case ended(duration: TimeInterval)
    }

    public var threshold: TimeInterval
    private var activeSince: Date?
    private var announced = false

    public init(threshold: TimeInterval) { self.threshold = threshold }

    public mutating func update(isActive: Bool, at now: Date) -> Event? {
        if isActive {
            let since = activeSince ?? now
            activeSince = since
            guard !announced, now.timeIntervalSince(since) >= threshold else { return nil }
            announced = true
            return .started(since: since)
        }
        defer { activeSince = nil; announced = false }
        guard announced, let since = activeSince else { return nil }
        return .ended(duration: now.timeIntervalSince(since))
    }
}

/// The dish's last minute of pings, for the packet loss and latency notifications. Seconds in
/// which every ping was lost are left out: those are outages, with their own notification.
public enum LinkCheck {
    public static let lossPercent = 10.0
    public static let latencyMs = 150.0
    static let window: TimeInterval = 60
    /// Fewer live seconds than this in the window give no reading; mostly-outage minutes are too noisy.
    static let minimumSamples = 30

    public static func recent(_ samples: [TelemetrySample]) -> LinkQuality {
        guard let end = samples.last?.timestamp else { return LinkQuality() }
        let start = end.addingTimeInterval(-window)
        let live = samples.filter { $0.dropRate < 1 && $0.timestamp >= start }
        guard live.count >= minimumSamples else { return LinkQuality() }
        return LinkQuality.over(live, from: start, to: end)
    }

    public static func isLossy(_ quality: LinkQuality, atLeast percent: Double = lossPercent) -> Bool { (quality.lossPercent ?? 0) >= percent }
    public static func isSlow(_ quality: LinkQuality, atLeast ms: Double = latencyMs) -> Bool { (quality.latencyMs ?? 0) >= ms }
}
