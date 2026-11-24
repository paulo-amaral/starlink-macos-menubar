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

struct AlignmentDetail: View {
    var reading: AlignmentReading?

    var body: some View {
        VStack(spacing: 12) {
            if let reading {
                VStack(spacing: 4) {
                    Text(title(reading)).font(Theme.ui(20, .bold)).foregroundStyle(Theme.ink)
                    Text(subtitle(reading)).font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                SkySceneView(mode: .alignment, map: nil,
                             boresightAzimuthDeg: reading.currentAzimuthDeg, boresightElevationDeg: reading.currentElevationDeg,
                             target: reading.isValid ? (reading.desiredAzimuthDeg, reading.desiredElevationDeg) : nil,
                             aligned: reading.isAligned, rotating: false)
                    .frame(height: 260).clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(reading.isAligned ? "Dish inside its target outline" : "Dish and the outline of where it should point")
                Text("The outline shows where your Starlink wants to point. Drag to look around.")
                    .font(Theme.ui(10)).foregroundStyle(Theme.inkMuted)
                if reading.isValid, !reading.isAligned { advice(reading) }
                VStack(spacing: 8) {
                    row("Azimuth", "\(deg(reading.currentAzimuthDeg)) now, \(deg(reading.desiredAzimuthDeg)) wanted", "Compass direction the dish faces")
                    row("Elevation", "\(deg(reading.currentElevationDeg)) now, \(deg(reading.desiredElevationDeg)) wanted", "Angle of the dish's aim above the horizon")
                    row("Pointing error", deg(reading.boresightErrorDeg), "Angle between where the dish points and where it wants to point")
                    row("Tilt", deg(reading.tiltAngleDeg), "Plate tilt reported by the dish")
                }
                Text("Uses the dish web app's own test: aligned when the pointing error stays under 5° against the 70° to 75° elevation band.")
                    .font(Theme.ui(10)).foregroundStyle(Theme.inkMuted).frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Waiting for dish status.").font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    private func title(_ reading: AlignmentReading) -> String {
        reading.isValid ? (reading.isAligned ? "Starlink is aligned" : "Starlink needs adjusting") : "Alignment unavailable"
    }

    private func subtitle(_ reading: AlignmentReading) -> String {
        if !reading.isValid { return "The dish has not settled on a position yet. Try again in a few minutes." }
        return reading.isAligned ? "Your Starlink is pointed in the correct direction." : "Move it into the outline for the best signal."
    }

    /// Plain steps for a manually mounted dish; motorised kits move on their own.
    private func advice(_ reading: AlignmentReading) -> some View {
        let turn = reading.turnClockwiseDeg, raise = reading.raiseFaceDeg
        return VStack(alignment: .leading, spacing: 6) {
            if abs(turn) >= 1 {
                Label(String(format: "Turn it %.0f° %@, seen from above.", abs(turn), turn > 0 ? "clockwise" : "counterclockwise"),
                      systemImage: turn > 0 ? "arrow.clockwise" : "arrow.counterclockwise")
            }
            if abs(raise) >= 1 {
                Label(String(format: "Tilt the face %.0f° %@.", abs(raise), raise > 0 ? "toward the sky" : "toward the horizon"),
                      systemImage: raise > 0 ? "arrow.up" : "arrow.down")
            }
        }
        .font(Theme.ui(12, .medium)).foregroundStyle(Theme.warm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
    }

    private func deg(_ value: Double) -> String { String(format: "%.1f°", value) }

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
