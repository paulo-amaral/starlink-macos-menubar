import Charts
import StarPulseCore
import SwiftUI

/// Statistics card: bold title, big value, window caption and an area sparkline
/// fading in behind the figure.
struct StatisticsCard: View {
    var title: String
    var value: String
    var unit: String
    var caption: String
    var series: [Double] = []
    var secondary: [Double] = []

    var body: some View {
        ZStack(alignment: .bottom) {
            if !series.isEmpty {
                SparkArea(series: series, secondary: secondary)
                    .frame(height: 74)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0.12), .init(color: .black, location: 0.5)], startPoint: .leading, endPoint: .trailing))
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).font(Theme.ui(15, .semibold)).foregroundStyle(Theme.ink)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Theme.inkSecondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(value).font(Theme.ui(22, .bold)).foregroundStyle(Theme.ink)
                    Text(unit).font(Theme.ui(15, .semibold)).foregroundStyle(Theme.inkSecondary)
                }
                Text(caption).font(Theme.ui(13)).foregroundStyle(Theme.inkSecondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct SparkArea: View {
    var series: [Double]
    var secondary: [Double]

    var body: some View {
        Chart {
            ForEach(Array(series.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("t", index), y: .value("v", value), series: .value("s", "a"))
                    .foregroundStyle(LinearGradient(colors: [Theme.ink.opacity(0.4), Theme.ink.opacity(0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("t", index), y: .value("v", value), series: .value("s", "a"))
                    .foregroundStyle(Theme.ink).lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(Array(secondary.enumerated()), id: \.offset) { index, value in
                LineMark(x: .value("t", index), y: .value("v", value), series: .value("s", "b"))
                    .foregroundStyle(Theme.ink.opacity(0.55)).lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXAxis(.hidden).chartYAxis(.hidden)
        .chartYScale(domain: scale)
    }

    private var scale: ClosedRange<Double> {
        let all = series + secondary
        let low = all.min() ?? 0, high = all.max() ?? 1
        let pad = max((high - low) * 0.15, 0.0001)
        return (low - pad)...(high + pad)
    }
}

/// Every Nth point keeps cards light while the model holds all 900 samples.
func thinned(_ values: [Double], every step: Int = 6) -> [Double] {
    values.enumerated().filter { $0.offset % step == 0 }.map(\.element)
}

struct StatisticsCards: View {
    var store: TelemetryStore
    var onSelect: (Metric) -> Void

    enum Metric: Hashable { case ping, latency, power, throughput, events }

    var body: some View {
        let stats = store.stats
        let samples = store.samples
        let down = Format.rate(Float(stats.averageDownlinkBps))
        VStack(spacing: 10) {
            card(.ping, StatisticsCard(title: "Ping success", value: stats.pingSuccessPercent.map { String(format: "%.1f", $0) } ?? "--", unit: "%", caption: "last 15 minutes",
                                       series: thinned(samples.map { 100 * (1 - Double($0.dropRate)) })))
            card(.latency, StatisticsCard(title: "Latency", value: stats.medianLatencyMs.map { String(Int($0.rounded())) } ?? "--", unit: "ms", caption: "median, last 15 minutes",
                                          series: thinned(samples.compactMap { $0.latencyMs.map(Double.init) }, every: 5)))
            card(.power, StatisticsCard(title: "Power", value: stats.averagePowerW.map { String(Int($0.rounded())) } ?? "--", unit: "W", caption: "average, last 15 minutes",
                                        series: thinned(samples.map { Double($0.powerW) })))
            card(.throughput, StatisticsCard(title: "Throughput", value: down.value, unit: down.unit, caption: "download, 15 minute average",
                                             series: thinned(samples.map { Double($0.downlinkBps) }, every: 4), secondary: thinned(samples.map { Double($0.uplinkBps) }, every: 4)))
            card(.events, StatisticsCard(title: "Events & outages", value: String(stats.eventsLastDay), unit: stats.eventsLastDay == 1 ? "event" : "events", caption: "last 1 day"))
        }
    }

    private func card(_ metric: Metric, _ view: StatisticsCard) -> some View {
        Button { onSelect(metric) } label: { view }.buttonStyle(.plain)
    }
}

struct ObstructionMapView: View {
    var map: ObstructionMap

    var body: some View {
        Canvas { context, size in
            guard !map.isEmpty else { return }
            let cell = min(size.width, size.height) / CGFloat(map.cols)
            let radius = Double(map.cols) / 2
            for row in 0..<map.rows { for col in 0..<map.cols {
                // Only the polar disc is meaningful; the corners hold no directions.
                guard hypot(Double(col) + 0.5 - radius, Double(row) + 0.5 - radius) <= radius else { continue }
                let color: Color = switch map.kind(row: row, col: col) {
                case .clear: Theme.skyClear
                case .partial: Theme.skyPartial
                case .obstructed: Theme.skyObstructed
                case .unmapped: Theme.skyUnmapped.opacity(0.35)
                }
                context.fill(Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell + 0.3, height: cell + 0.3)), with: .color(color))
            } }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel("Obstruction map")
    }
}

struct ObstructionDetail: View {
    var store: TelemetryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let map = store.obstructionMap, !map.isEmpty {
                ObstructionMapView(map: map).frame(maxWidth: 300).frame(maxWidth: .infinity)
                HStack(spacing: 14) {
                    legend("Clear", Theme.skyClear); legend("Partial", Theme.skyPartial)
                    legend("Obstructed", Theme.skyObstructed); legend("Not seen", Theme.skyUnmapped)
                }
                figure("Reported by the dish", store.status.map { String(format: "%.1f %%", Double($0.fractionObstructed) * 100) } ?? "--",
                       "The dish's own obstruction fraction")
                figure("Mapped sky blocked", String(format: "%.1f %%", map.obstructedShareOfMapped * 100),
                       "Share of cells the dish has observed that are partly or fully blocked")
            } else {
                Text("Waiting for the obstruction map from the dish.").font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
        }
    }

    private func figure(_ label: String, _ value: String, _ help: String) -> some View {
        HStack {
            Text(label).font(Theme.ui(13)).foregroundStyle(Theme.ink)
            Spacer()
            Text(value).font(Theme.mono(12, .medium)).foregroundStyle(Theme.ink)
        }
        .help(help)
    }
}

struct AlignmentDetail: View {
    var reading: AlignmentReading?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let reading {
                Text(summary(reading)).font(Theme.ui(17, .bold)).foregroundStyle(reading.isAligned ? Theme.good : Theme.warm)
                row("Azimuth", "\(deg(reading.currentAzimuthDeg)) now, \(deg(reading.desiredAzimuthDeg)) wanted", "error \(signed(reading.azimuthErrorDeg))")
                row("Elevation", "\(deg(reading.currentElevationDeg)) now, \(deg(reading.desiredElevationDeg)) wanted", "error \(signed(reading.elevationErrorDeg))")
                row("Pointing error", deg(reading.boresightErrorDeg), "Angle between where the dish points and where it wants to point")
                row("Tilt", deg(reading.tiltAngleDeg), "Plate tilt reported by the dish")
                Text("Uses the dish web app's own test: aligned when the pointing error stays under 5° against the 70° to 75° elevation band.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.inkMuted)
            } else {
                Text("Waiting for dish status.").font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    private func summary(_ reading: AlignmentReading) -> String {
        reading.isValid ? (reading.isAligned ? "Starlink is aligned" : "Starlink is misaligned") : "Alignment unavailable"
    }
    private func deg(_ value: Double) -> String { String(format: "%.1f°", value) }
    private func signed(_ value: Double) -> String { String(format: "%+.1f°", value) }

    private func row(_ label: String, _ value: String, _ help: String) -> some View {
        HStack {
            Text(label).font(Theme.ui(13)).foregroundStyle(Theme.ink)
            Spacer()
            Text(value).font(Theme.mono(11)).foregroundStyle(Theme.inkSecondary)
        }
        .help(help)
    }
}

/// Statistics cards that open their detail in place, with a way back. Used where there is no page stack (dashboard panel).
struct StatisticsPanel: View {
    var store: TelemetryStore
    @State private var metric: StatisticsCards.Metric?

    var body: some View {
        if let metric {
            VStack(alignment: .leading, spacing: 12) {
                Button { self.metric = nil } label: { Label("Statistics", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(Theme.ink).font(Theme.ui(13, .semibold))
                    .help("Back to all statistics")
                switch metric {
                case .ping, .latency: LatencyDetail(store: store)
                case .power: PowerChart(samples: store.samples)
                case .throughput: ThroughputChart(samples: store.samples)
                case .events: EventsList(events: store.events, limit: 60)
                }
            }
        } else {
            StatisticsCards(store: store) { metric = $0 }
            #if DEBUG
                .onAppear {
                    switch UserDefaults.standard.string(forKey: "debugStatisticsMetric") {
                    case "throughput": metric = .throughput
                    case "latency": metric = .latency
                    default: break
                    }
                }
            #endif
        }
    }
}
