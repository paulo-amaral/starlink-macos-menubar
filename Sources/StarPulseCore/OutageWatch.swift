import Foundation

/// Turns the dish's per-second outage flag into at most one "down" and one "back" event per outage.
/// Drops of a few seconds are routine on Starlink (handoffs, brief obstructions), so "down" waits
/// until the outage has lasted `threshold` seconds, and "back" follows only an announced outage.
public struct OutageWatch: Sendable {
    public enum Event: Equatable, Sendable {
        case down(since: Date)
        case restored(duration: TimeInterval)
    }

    public var threshold: TimeInterval
    private var downSince: Date?
    private var announced = false

    public init(threshold: TimeInterval = 30) { self.threshold = threshold }

    public mutating func update(isDown: Bool, at now: Date) -> Event? {
        if isDown {
            let since = downSince ?? now
            downSince = since
            guard !announced, now.timeIntervalSince(since) >= threshold else { return nil }
            announced = true
            return .down(since: since)
        }
        defer { downSince = nil; announced = false }
        guard announced, let since = downSince else { return nil }
        return .restored(duration: now.timeIntervalSince(since))
    }
}
