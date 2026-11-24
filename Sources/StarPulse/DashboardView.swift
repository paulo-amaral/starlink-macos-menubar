import StarPulseCore
import SwiftUI

struct DashboardView: View {
    var store: TelemetryStore
    var account: AccountStore
    @State private var panel: DashboardPanel?
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    TopBar(store: store)
                    if case .offline(let message) = store.connection {
                        Card { Text("Cannot reach the dish: \(message). Connect to the Starlink network and check the dish address in Settings.").font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary) }
                    }
                    tiles
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 12) {
                            ThroughputChart(samples: store.samples)
                            LatencyCard(store: store) { panel = .latency }
                            PowerCard(samples: store.samples)
                        }
                        VStack(spacing: 12) {
                            ObstructionsCard(store: store) { panel = .satellites }
                            EventsCard(events: store.events)
                        }
                        .frame(width: 380)
                    }
                }
                .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 84)
            }
            DashboardDock(open: { panel = $0 }, openSettings: { openSettings(); NSApp.activate(ignoringOtherApps: true) })
                .padding(.bottom, 14)
        }
        .appChrome()
        .background(DotGridBackground())
        .frame(minWidth: 1040, minHeight: 700)
        .sheet(item: $panel) { panel in PanelSheet(title: panel.title) { content(panel) } }
    }

    private var tiles: some View {
        let samples = store.samples, status = store.status
        let down = status.map { Format.rate($0.downlinkBps) } ?? ("--", "")
        let up = status.map { Format.rate($0.uplinkBps) } ?? ("--", "")
        return HStack(spacing: 10) {
            CompactTile(title: "Download", value: down.0, unit: down.1, caption: "current traffic", series: thinned(samples.map { Double($0.downlinkBps) }, every: 8), color: Theme.down, help: "Current downlink throughput reported by the dish", action: nil)
            CompactTile(title: "Upload", value: up.0, unit: up.1, caption: "current traffic", series: thinned(samples.map { Double($0.uplinkBps) }, every: 8), color: Theme.up, help: "Current uplink throughput reported by the dish", action: nil)
            CompactTile(title: "Latency", value: status.map { $0.latencyMs > 0 ? String(Int($0.latencyMs.rounded())) : "--" } ?? "--", unit: "ms", caption: "pop ping, live", series: thinned(samples.compactMap { $0.latencyMs.map(Double.init) }, every: 8), color: Theme.warm, help: "Round-trip ping to the Starlink point of presence", action: { panel = .latency })
            CompactTile(title: "Power draw", value: store.latestPower.map { String(format: "%.0f", $0) } ?? "--", unit: "W", caption: "current draw", series: thinned(samples.map { Double($0.powerW) }, every: 8), color: Theme.accent, help: "Terminal power draw, from the dish history buffer", action: nil)
            CompactTile(title: "Ping success", value: store.pingSuccessPercent.map { String(format: "%.1f", $0) } ?? "--", unit: "%", caption: "last minute", series: [], color: Theme.good, help: "Share of pings answered over the last 60 seconds", action: nil)
            CompactTile(title: "Sky obstructed", value: status.map { String(format: "%.2f", Double($0.fractionObstructed) * 100) } ?? "--", unit: "%", caption: store.obstructionMap.map { "\($0.cells.filter { $0 >= 0 }.count) patches mapped" } ?? "obstruction map", series: [], color: Theme.critical, help: "Fraction of the sky view blocked, as reported by the dish", action: nil)
        }
    }

    @ViewBuilder private func content(_ panel: DashboardPanel) -> some View {
        switch panel {
        case .latency: LatencyDetail(store: store)
        case .statistics: StatisticsPanel(store: store)
        case .network: NetworkPanel(store: store, account: account)
        case .alignment: AlignmentDetail(reading: store.alignment)
        case .satellites: SatelliteView(store: store, account: account)
        case .speedTest: SpeedTestView(model: store.speedTest, store: store).frame(maxWidth: 420).frame(maxWidth: .infinity)
        case .account: AccountCard(account: account)
        }
    }
}

/// A sheet with a title and a Done button, per the macOS HIG for short scoped tasks.
struct PanelSheet<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: title) { dismiss() }.padding(20)
            ScrollView { content.padding(.horizontal, 20).padding(.bottom, 20) }
        }
        .appChrome()
        .frame(width: 760, height: 700)
        .background(Theme.page)
    }
}
