import Charts
import StarPulseCore
import SwiftUI

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(Theme.ui(15, .semibold)).foregroundStyle(Theme.ink)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
    }
}

struct ThroughputChart: View {
    var samples: [TelemetrySample]
    /// 0 scales to the data; otherwise a fixed top in Mbps, so spikes compare across time (Dishylink issue #50).
    @AppStorage(SettingsKey.throughputAxisMax) private var axisMax = 0.0

    var body: some View {
        Card(title: "Throughput · last 15 min") {
            Chart {
                ForEach(samples.filter { $0.sequence % 3 == 0 }, id: \.sequence) { sample in
                    LineMark(x: .value("Time", sample.timestamp), y: .value("Mbps", Double(sample.downlinkBps) / 1e6), series: .value("s", "Download")).foregroundStyle(Theme.down)
                    LineMark(x: .value("Time", sample.timestamp), y: .value("Mbps", Double(sample.uplinkBps) / 1e6), series: .value("s", "Upload")).foregroundStyle(Theme.up)
                }
            }
            .chartForegroundStyleScale(["Download": Theme.down, "Upload": Theme.up])
            .chartYScale(domain: 0...(axisMax > 0 ? axisMax : max(1, (samples.map { Double($0.downlinkBps) }.max() ?? 0) / 1e6 * 1.1)))
            .chartYAxisLabel("Mbps").frame(height: 160).clipped()
        }
    }
}

struct LatencyChart: View {
    var samples: [TelemetrySample]
    var height: CGFloat = 160

    var body: some View {
        Card(title: "Latency · outages in red") {
            Chart {
                ForEach(Array(TelemetrySample.outageRanges(samples).enumerated()), id: \.offset) { _, range in
                    RectangleMark(xStart: .value("s", range.lowerBound), xEnd: .value("e", range.upperBound.addingTimeInterval(1))).foregroundStyle(Theme.critical.opacity(0.35))
                }
                ForEach(samples.filter { $0.sequence % 3 == 0 && $0.latencyMs != nil }, id: \.sequence) { sample in
                    LineMark(x: .value("Time", sample.timestamp), y: .value("ms", Double(sample.latencyMs ?? 0))).foregroundStyle(Theme.warm)
                }
            }
            .chartYScale(domain: 0...(max(10, Double(samples.compactMap(\.latencyMs).max() ?? 0) * 1.1)))
            .chartYAxisLabel("ms").frame(height: height)
        }
    }
}

struct EventsList: View {
    var events: [DishEvent]
    var limit = 8

    var body: some View {
        Card(title: "Events") {
            if events.isEmpty {
                Text("No events in the dish history.").font(Theme.ui(12)).foregroundStyle(Theme.inkMuted)
            }
            ForEach(events.prefix(limit)) { event in
                HStack(spacing: 8) {
                    Circle().fill(color(event.severity)).frame(width: 7, height: 7)
                    Text(event.title).font(Theme.ui(12, .medium)).foregroundStyle(Theme.ink)
                    Spacer()
                    Text(Format.duration(event.duration)).font(Theme.mono(11)).foregroundStyle(Theme.inkSecondary)
                    Text(event.start, style: .relative).font(Theme.ui(11)).foregroundStyle(Theme.inkMuted).frame(width: 90, alignment: .trailing)
                }
            }
        }
    }

    private func color(_ severity: DishEvent.Severity) -> Color {
        switch severity {
        case .warning: Theme.critical
        case .caution: Theme.warm
        default: Theme.inkMuted
        }
    }
}

struct ConnectionChip: View {
    var connection: Connection

    var body: some View {
        let (text, color): (String, Color) = switch connection {
        case .connecting: ("Connecting", Theme.inkMuted)
        case .live: ("Live", Theme.good)
        case .offline: ("Offline", Theme.critical)
        }
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(Theme.ui(11, .medium)).foregroundStyle(Theme.inkSecondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Theme.surfaceRaised, in: Capsule())
        .help(offlineDetail)
    }

    private var offlineDetail: String {
        if case .offline(let message) = connection { return message }
        return "Connection state of the Starlink dish"
    }
}

struct PowerChart: View {
    var samples: [TelemetrySample]

    var body: some View {
        Card(title: "Power · last 15 min") {
            Chart(samples.filter { $0.sequence % 3 == 0 && $0.powerW > 0 }, id: \.sequence) { sample in
                LineMark(x: .value("Time", sample.timestamp), y: .value("W", Double(sample.powerW))).foregroundStyle(Theme.accent)
            }
            .chartYAxisLabel("W").frame(height: 160)
        }
    }
}
