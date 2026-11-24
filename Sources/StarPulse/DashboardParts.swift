import Charts
import StarPulseCore
import SwiftUI

enum DashboardPanel: String, Identifiable {
    case latency, statistics, network, alignment, speedTest, satellites, account
    var id: String { rawValue }
    var title: String {
        switch self {
        case .latency: "Latency"
        case .statistics: "Statistics"
        case .network: "Network"
        case .alignment: "Alignment"
        case .speedTest: "Speed test"
        case .satellites: "Satellites"
        case .account: "Starlink account"
        }
    }
}

func uptimeText(_ seconds: UInt64) -> String {
    let days = seconds / 86_400, hours = seconds % 86_400 / 3_600, minutes = seconds % 3_600 / 60
    return days > 0 ? "\(days)d \(hours)h" : "\(hours)h \(minutes)m"
}

struct TopBar: View {
    var store: TelemetryStore
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceChoice.dark.rawValue
    @State private var showAlerts = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "circle.dotted.circle").font(.title2).foregroundStyle(Theme.ink)
            Text("StarPulse").font(Theme.ui(15, .bold)).tracking(1.5).foregroundStyle(Theme.ink)
            Spacer()
            HStack(spacing: 0) {
                chip { HStack(spacing: 6) { Circle().fill(dotColor).frame(width: 7, height: 7); Text(statusText) } }
                if let code = store.status?.countryCode, !code.isEmpty { divider; chip { Text(code) } }
                if let up = store.status?.uptimeSeconds, up > 0 { divider; chip { Text("up \(uptimeText(up))") } }
            }
            .font(Theme.mono(11)).foregroundStyle(Theme.inkSecondary)
            Button { store.isPaused.toggle() } label: {
                Image(systemName: store.isPaused ? "play.fill" : "pause.fill").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain).foregroundStyle(store.isPaused ? Theme.warm : Theme.ink)
            .help(store.isPaused ? "Resume live updates" : "Pause live updates so the screen holds still")
            .accessibilityLabel(store.isPaused ? "Resume live updates" : "Pause live updates")
            Button { showAlerts.toggle() } label: {
                Image(systemName: "bell").frame(width: 28, height: 28)
                    .overlay(alignment: .topTrailing) { if alertCount > 0 { Circle().fill(Theme.warm).frame(width: 8, height: 8) } }
            }
            .buttonStyle(.plain).foregroundStyle(Theme.ink)
            .help(alertCount == 0 ? "No active alerts" : "\(alertCount) active alert\(alertCount == 1 ? "" : "s")").accessibilityLabel("Alerts")
            .popover(isPresented: $showAlerts) { alertsList }
            Button { appearance = (appearance == AppearanceChoice.light.rawValue ? AppearanceChoice.dark : AppearanceChoice.light).rawValue
                (AppearanceChoice(rawValue: appearance) ?? .dark).apply() } label: {
                Image(systemName: appearance == AppearanceChoice.light.rawValue ? "moon" : "sun.max").frame(width: 28, height: 28)
            }
            .buttonStyle(.plain).foregroundStyle(Theme.ink).help("Switch between the dark and light theme").accessibilityLabel("Theme")
        }
    }

    private var alertCount: Int { store.status?.activeAlerts.count ?? 0 }
    private var statusText: String {
        switch store.connection { case .connecting: "connecting"; case .offline: "offline"; case .live: store.isPaused ? "paused" : (store.isOutage ? "no connection" : "online") }
    }
    private var dotColor: Color {
        switch store.connection { case .connecting: Theme.inkMuted; case .offline: Theme.critical; case .live: store.isOutage ? Theme.critical : Theme.good }
    }
    private var divider: some View { Rectangle().fill(Theme.hairline).frame(width: 1, height: 16) }
    private func chip<C: View>(@ViewBuilder _ content: () -> C) -> some View { content().padding(.horizontal, 10) }

    private var alertsList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Alerts").font(Theme.ui(13, .semibold))
            if let alerts = store.status?.activeAlerts, !alerts.isEmpty {
                ForEach(alerts, id: \.self) { Text($0).font(Theme.ui(12)) }
            } else { Text("Nothing is wrong right now.").foregroundStyle(Theme.inkSecondary) }
        }
        .padding(14).frame(minWidth: 220, alignment: .leading)
    }
}

struct CompactTile: View {
    var title: String
    var value: String
    var unit: String
    var caption: String
    var series: [Double]
    var color: Color
    var help: String
    var action: (() -> Void)?

    var body: some View {
        // Only tiles with a detail panel are buttons; a disabled button would dim the figures.
        if let action {
            Button(action: action) { content }.buttonStyle(.plain).help(help).accessibilityElement(children: .combine)
        } else {
            content.help(help).accessibilityElement(children: .combine)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(Theme.ui(13, .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                if action != nil { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.inkSecondary) }
            }
            HStack(alignment: .center, spacing: 6) {
                Text(value).font(Theme.ui(22, .bold)).foregroundStyle(Theme.ink).lineLimit(1).minimumScaleFactor(0.6).fixedSize(horizontal: true, vertical: false)
                Text(unit).font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary).baselineOffset(-6).lineLimit(1).fixedSize()
                // The sparkline takes whatever width is left, and yields first when the tile is narrow.
                if !series.isEmpty { SparkArea(series: series, secondary: []).frame(minWidth: 24, maxWidth: .infinity).frame(height: 26).opacity(0.9).layoutPriority(-1) }
            }
            Text(caption).font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
        .contentShape(Rectangle())
    }
}

struct ChartCard<Content: View, Trailing: View>: View {
    var title: String
    var subtitle: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(Theme.ui(15, .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Text(subtitle).font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
                trailing
            }
            content
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
    }
}

struct LatencyCard: View {
    var store: TelemetryStore
    var onDetails: () -> Void
    @State private var range = HistoryRange.m15

    var body: some View {
        let window = store.latencyHistory.window(range, dishSamples: store.samples, now: Date())
        ChartCard(title: "Latency", subtitle: "pop ping · red bands = outages") {
            RangePicker(range: $range)
        } content: {
            Chart {
                if range == .m15 {
                    ForEach(Array(TelemetrySample.outageRanges(store.samples).enumerated()), id: \.offset) { _, outage in
                        RectangleMark(xStart: .value("s", outage.lowerBound), xEnd: .value("e", outage.upperBound.addingTimeInterval(1))).foregroundStyle(Theme.critical.opacity(0.35))
                    }
                }
                ForEach(Array(window.starlink.enumerated()), id: \.offset) { _, point in
                    AreaMark(x: .value("Time", point.date), y: .value("ms", point.ms)).foregroundStyle(LinearGradient(colors: [Theme.ink.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", point.date), y: .value("ms", point.ms)).foregroundStyle(Theme.ink)
                }
            }
            .chartYScale(domain: 0...max(10, (window.starlink.map(\.ms).max() ?? 0) * 1.15))
            .frame(height: 170)
            if range != .m15 && window.coverage < 0.99 {
                Text("Collected \(Int(window.coverage * 100))% of this window. Longer history builds while the app is open and is kept in memory only.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
            }
            Button("Details…", action: onDetails).buttonStyle(.appCompact).help("Latency average, router comparison and distribution")
        }
    }
}

struct RangePicker: View {
    @Binding var range: HistoryRange

    var body: some View {
        AppSegmented(selection: $range, options: HistoryRange.allCases.map { ($0, $0.label) }, help: "Time window shown")
            .frame(width: 170)
    }
}

struct PowerCard: View {
    var samples: [TelemetrySample]

    var body: some View {
        let watts = samples.map { Double($0.powerW) }.filter { $0 > 0 }
        let average = watts.isEmpty ? nil : watts.reduce(0, +) / Double(watts.count)
        ChartCard(title: "Power draw", subtitle: average.map { String(format: "≈ %.2f kWh/day at recent draw", $0 * 24 / 1000) } ?? "no power data") {
            EmptyView()
        } content: {
            Chart(Array(samples.enumerated().filter { $0.offset % 3 == 0 && $0.element.powerW > 0 }), id: \.offset) { _, sample in
                AreaMark(x: .value("Time", sample.timestamp), y: .value("W", Double(sample.powerW))).foregroundStyle(LinearGradient(colors: [Theme.ink.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", sample.timestamp), y: .value("W", Double(sample.powerW))).foregroundStyle(Theme.ink)
            }
            .chartYAxisLabel("W").frame(height: 150)
        }
    }
}

struct ObstructionsCard: View {
    var store: TelemetryStore
    var onSatellites: () -> Void = {}
    @State private var rotating = true
    /// nil shows the live map; otherwise the index of a stored hourly frame.
    @State private var frameIndex: Int?

    var body: some View {
        let status = store.status
        let percent = Double(status?.fractionObstructed ?? 0) * 100
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Obstructions").font(Theme.ui(15, .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Button("Live satellite view ›", action: onSatellites).buttonStyle(.plain).font(Theme.ui(12, .semibold)).foregroundStyle(Theme.accent)
                    .help("Open the live view of Starlink satellites over your obstruction map")
            }
            if let live = store.obstructionMap, !live.isEmpty {
                let map = frameIndex.flatMap { store.snapshots.indices.contains($0) ? store.snapshots[$0].map : nil } ?? live
                ZStack(alignment: .topTrailing) {
                    SkySceneView(mode: .dome, map: map, boresightAzimuthDeg: Double(status?.boresightAzimuthDeg ?? 0),
                                 boresightElevationDeg: Double(status?.boresightElevationDeg ?? 90), rotating: rotating)
                        .frame(height: 280).clipShape(RoundedRectangle(cornerRadius: 10))
                    Button { rotating.toggle() } label: { Image(systemName: rotating ? "pause.fill" : "play.fill").frame(width: 28, height: 28) }
                        .buttonStyle(.plain).foregroundStyle(Theme.ink).padding(6)
                        .help(rotating ? "Stop the dome turning" : "Turn the dome slowly").accessibilityLabel(rotating ? "Stop rotation" : "Start rotation")
                }
                Text("Drag to orbit, scroll or pinch to zoom.").font(Theme.ui(10)).foregroundStyle(Theme.inkSecondary)
                if !store.snapshots.isEmpty { timeLapse }
            }
            HStack(spacing: 12) {
                legend("Unmapped", Theme.skyUnmapped); legend("Clear view", Theme.skyClear)
                legend("Partial", Theme.skyPartial); legend("Obstructions", Theme.skyObstructed)
            }
            HStack {
                figure("Sky obstructed", String(format: "%.2f%%", percent))
                Spacer()
                figure("Observed for", String(format: "%.1f h", Double(status?.obstructionObservedSeconds ?? 0) / 3600))
            }
            Text(percent < 1 ? "Your Starlink has an unobstructed view of the sky. The map becomes more accurate as the dish collects data."
                             : "Part of your Starlink's view of the sky is blocked. The map shows where.")
                .font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary)
                .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.hairline))
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
    }

    /// Scrubber over the hourly frames with LIVE as the last stop, as in Dishylink's ObstructionTimeLapse.
    private var timeLapse: some View {
        let count = store.snapshots.count
        return HStack(spacing: 10) {
            Slider(value: Binding(get: { Double(frameIndex ?? count) },
                                  set: { frameIndex = Int($0.rounded()) >= count ? nil : Int($0.rounded()) }),
                   in: 0...Double(count), step: 1)
                .help("Scrub back through hourly snapshots of the obstruction map; the last stop is live")
            if let index = frameIndex, store.snapshots.indices.contains(index) {
                Text(store.snapshots[index].takenAt.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                    .font(Theme.mono(10)).foregroundStyle(Theme.inkSecondary).frame(width: 84, alignment: .trailing)
            } else {
                Text("LIVE").font(Theme.mono(10, .medium)).foregroundStyle(Theme.good).frame(width: 84, alignment: .trailing)
            }
        }
    }

    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) { Circle().fill(color).frame(width: 8, height: 8); Text(text).font(Theme.ui(10)).foregroundStyle(Theme.inkSecondary) }
    }
    private func figure(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(label).font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
            Text(value).font(Theme.mono(12, .medium)).foregroundStyle(Theme.ink)
        }
    }
}

struct EventsCard: View {
    var events: [DishEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Events & outages").font(Theme.ui(15, .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                Text("\(events.count) events").font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(events.prefix(60)) { event in
                        HStack(spacing: 8) {
                            Text(event.start.formatted(date: .omitted, time: .shortened)).font(Theme.mono(10)).foregroundStyle(Theme.inkSecondary).frame(width: 64, alignment: .leading)
                            Circle().fill(event.severity == .warning ? Theme.warm : Theme.inkMuted).frame(width: 7, height: 7)
                            Text(event.title).font(Theme.ui(12, .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                            Spacer()
                            if event.duration >= 1 { Text(Format.duration(event.duration)).font(Theme.mono(10)).foregroundStyle(Theme.inkSecondary) }
                        }
                        .padding(.vertical, 7)
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
            .frame(height: 280)
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.hairline))
    }
}

/// Floating dock with the sections that exist today.
struct DashboardDock: View {
    var open: (DashboardPanel) -> Void
    var openSettings: () -> Void

    var body: some View {
        HStack(spacing: 22) {
            button("speedometer", "Speed test") { open(.speedTest) }
            button("location.north.line", "Alignment") { open(.alignment) }
            button("chart.bar", "Statistics") { open(.statistics) }
            button("wifi", "Network") { open(.network) }
            button("globe", "Satellites") { open(.satellites) }
            button("person", "Starlink account") { open(.account) }
            button("gearshape", "Settings") { openSettings() }
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .background(Theme.surfaceRaised.opacity(0.95), in: Capsule())
        .overlay(Capsule().stroke(Theme.hairline))
        .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
    }

    private func button(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 14)).frame(width: 28, height: 28) }
            .buttonStyle(.plain).foregroundStyle(Theme.ink).help(label).accessibilityLabel(label)
    }
}
