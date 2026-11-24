import Foundation

public struct ClientRate: Sendable, Equatable {
    public var downMbps: Double
    public var upMbps: Double
    public static let zero = ClientRate(downMbps: 0, upMbps: 0)
}

/// Per-device throughput from the router's byte counters, ported from Dishylink
/// core/throughputTracker.ts (MIT). The router recomputes a client's counters about
/// once a second on its own clock and never says when, so the counter is a staircase.
/// Polling several times per step finds each edge; one edge is one refresh period of
/// traffic, so dividing by that period gives an exact rate with no smoothing. The
/// router's own 15 s and 1 min averages lag and do not match a speed test.
public struct ThroughputTracker: Sendable {
    /// Measured by Dishylink on Gen 3 firmware: median 1005 ms between counter updates.
    static let refreshPeriodMs = 1_005.0
    /// A counter still for two periods means idle, not "between edges".
    static let idleAfterMs = 2 * refreshPeriodMs
    /// A longer gap in our own polling (sleep, restart) cannot be called a moment's throughput.
    static let maxPollGapMs = 15_000.0

    public struct Reading: Sendable, Equatable {
        public var rate: ClientRate
        /// Bytes that moved since the previous poll, for volume totals. Zero on a seed, a reset or a gap.
        public var rxDelta: UInt64
        public var txDelta: UInt64
    }

    private struct State {
        var rx: UInt64, tx: UInt64
        var lastPollMs: Double
        var lastChangeMs: Double
        var latest: ClientRate?
    }

    private var devices: [String: State] = [:]
    public init() {}

    /// Call on every poll, several times per refresh period. `fallback` is used when a
    /// delta would lie: first reading, counters gone backwards (device rejoined), or a polling gap.
    public mutating func read(key: String, rx: UInt64?, tx: UInt64?, atMs: Double, fallback: ClientRate) -> Reading {
        guard let rx, let tx else { return Reading(rate: fallback, rxDelta: 0, txDelta: 0) }
        func seed() -> Reading {
            devices[key] = State(rx: rx, tx: tx, lastPollMs: atMs, lastChangeMs: atMs, latest: nil)
            return Reading(rate: fallback, rxDelta: 0, txDelta: 0)
        }
        guard var state = devices[key] else { return seed() }
        if rx < state.rx || tx < state.tx { return seed() }
        let gap = atMs - state.lastPollMs
        if gap > Self.maxPollGapMs { return seed() }

        let rxDelta = rx - state.rx, txDelta = tx - state.tx
        if rxDelta != 0 || txDelta != 0 {
            // One interval per edge; more than one only when our polling stalled and missed some.
            // Never divide by time since the last change: a burst after eight idle seconds would read an eighth.
            let intervals = max(1, (gap / Self.refreshPeriodMs).rounded())
            let elapsedMs = intervals * Self.refreshPeriodMs
            state.latest = ClientRate(downMbps: Double(rxDelta) * 8 / 1e6 / (elapsedMs / 1000), upMbps: Double(txDelta) * 8 / 1e6 / (elapsedMs / 1000))
            state.lastChangeMs = atMs
        } else if atMs - state.lastChangeMs >= Self.idleAfterMs {
            state.latest = .zero
        }
        state.rx = rx; state.tx = tx; state.lastPollMs = atMs
        devices[key] = state
        return Reading(rate: state.latest ?? fallback, rxDelta: rxDelta, txDelta: txDelta)
    }

    /// Drops state for devices no longer present so the map cannot grow forever.
    public mutating func retain(_ keys: Set<String>) { devices = devices.filter { keys.contains($0.key) } }
}
