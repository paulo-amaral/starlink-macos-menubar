import Foundation

public enum Format {
    /// Compact bitrate for the narrow menu bar: "1.2Mb/s", "340Kb/s", "2.0Gb/s".
    /// Same SI thresholds as Dishylink electron/menuBarThroughput.ts (MIT).
    public static func menuBarRate(_ bitsPerSecond: Float) -> String {
        let bps = Double(bitsPerSecond)
        if bps >= 1e9 { return String(format: "%.1fGb/s", bps / 1e9) }
        if bps >= 1e6 { return String(format: "%.1fMb/s", bps / 1e6) }
        return "\(Int((bps / 1e3).rounded()))Kb/s"
    }

    /// Dashboard tile spelling: value and unit apart, e.g. ("1.2", "Mbps").
    public static func rate(_ bitsPerSecond: Float) -> (value: String, unit: String) {
        let bps = Double(bitsPerSecond)
        if bps >= 1e9 { return (String(format: "%.2f", bps / 1e9), "Gbps") }
        if bps >= 1e6 { return (String(format: "%.1f", bps / 1e6), "Mbps") }
        return (String(Int((bps / 1e3).rounded())), "Kbps")
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "<1s" }
        if seconds < 60 { return "\(Int(seconds.rounded()))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m \(Int(seconds) % 60)s" }
        return "\(Int(seconds / 3600))h \(Int(seconds) % 3600 / 60)m"
    }
}

extension TelemetrySample {
    /// Contiguous runs where every ping was lost; drawn as red bands on the latency chart.
    public static func outageRanges(_ samples: [TelemetrySample]) -> [ClosedRange<Date>] {
        var ranges: [ClosedRange<Date>] = []
        var runStart: Date?
        var previous: Date?
        for sample in samples {
            if sample.dropRate >= 1 {
                runStart = runStart ?? sample.timestamp
            } else if let start = runStart, let end = previous {
                ranges.append(start...end)
                runStart = nil
            }
            previous = sample.timestamp
        }
        if let start = runStart, let end = previous { ranges.append(start...end) }
        return ranges
    }
}
