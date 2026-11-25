import StarPulseCore
import SwiftUI

private enum Page: Hashable {
    case statistics, network, contentFilter, obstructions, alignment, speedTest, satellites, menuBar
    case detail(StatisticsCards.Metric)

    var title: String {
        switch self {
        case .statistics: "Statistics"
        case .network: "Network"
        case .contentFilter: "Content filtering"
        case .obstructions: "Obstructions"
        case .alignment: "Alignment"
        case .speedTest: "Speed test"
        case .satellites: "Satellites"
        case .menuBar: "Menu Bar"
        case .detail(let metric):
            switch metric {
            case .ping: "Ping success"
            case .latency: "Latency"
            case .power: "Power"
            case .throughput: "Throughput"
            case .events: "Events & outages"
            }
        }
    }
}

struct PopoverView: View {
    var store: TelemetryStore
    var account: AccountStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var path: [Page] = []

    var body: some View {
        VStack(spacing: 0) {
            if let page = path.last { pageHeader(page) }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let page = path.last { content(page) } else { home }
                }
                .padding(.horizontal, 16).padding(.bottom, 12)
            }
            .scrollIndicators(.hidden)
            footer
        }
        .appChrome()
        .frame(width: 380, height: 640)
        .background(Theme.page)
        #if DEBUG
        .onAppear {
            switch UserDefaults.standard.string(forKey: "debugPopoverPage") {
            case "speedTest": path = [.speedTest]
            case "satellites": path = [.satellites]
            case "alignment": path = [.alignment]
            case "obstructions": path = [.obstructions]
            case "contentFilter": path = [.contentFilter]
            case "statistics": path = [.statistics]
            default: break
            }
        }
        #endif
    }

    // MARK: Home

    private var home: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(networkName).font(Theme.ui(15, .semibold)).foregroundStyle(Theme.inkSecondary)
                    HStack(spacing: 8) {
                        Text(statusTitle).font(Theme.ui(26, .bold)).foregroundStyle(Theme.ink)
                        Circle().fill(statusColor).frame(width: 12, height: 12)
                    }
                }
                Spacer()
                Button { store.isPaused.toggle() } label: {
                    Image(systemName: store.isPaused ? "play.fill" : "pause.fill").font(Theme.ui(13)).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).foregroundStyle(store.isPaused ? Theme.warm : Theme.ink)
                .help(store.isPaused ? "Resume live updates" : "Pause live updates so the screen holds still")
                .accessibilityLabel(store.isPaused ? "Resume live updates" : "Pause live updates")
                Button { openSettings(); NSApp.activate(ignoringOtherApps: true) } label: {
                    Image(systemName: "person").font(.title3).frame(width: 28, height: 28)
                }
                .buttonStyle(.plain).foregroundStyle(Theme.ink)
                .help("Open settings to manage the Starlink account")
                .accessibilityLabel("Account settings")
            }
            .padding(.top, 14)
            if let notice { noticeBanner(notice) }
            row("chart.bar", "Statistics", nil, .statistics)
            row("wifi", "Network", "\(store.clients.count) devices", .network)
            row("shield.lefthalf.filled", "Content filtering", contentFilterSubtitle, .contentFilter)
            row("circle.dotted", "Obstructions", obstructionSubtitle, .obstructions)
            row("location.north.line", "Alignment", alignmentSubtitle, .alignment)
            row("speedometer", "Speed test", nil, .speedTest)
            row("globe", "Satellites", "Live sky view", .satellites)
            row("menubar.rectangle", "Menu Bar", Readout.parse(UserDefaults.standard.string(forKey: SettingsKey.readouts) ?? "").map(\.label).joined(separator: ", "), .menuBar)
            Button { openSettings(); NSApp.activate(ignoringOtherApps: true) } label: {
                rowLabel("gearshape", "Settings…", nil)
            }
            .buttonStyle(.plain).help("Open StarPulse settings")
        }
    }

    private func row(_ symbol: String, _ title: String, _ subtitle: String?, _ page: Page) -> some View {
        Button { path.append(page) } label: { rowLabel(symbol, title, subtitle, chevron: true) }
            .buttonStyle(.plain)
    }

    private func rowLabel(_ symbol: String, _ title: String, _ subtitle: String?, chevron: Bool = false) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol).font(.system(size: 15)).frame(width: 28).foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.ui(15, .semibold)).foregroundStyle(Theme.ink)
                if let subtitle { Text(subtitle).font(Theme.ui(13)).foregroundStyle(Theme.inkSecondary).lineLimit(1) }
            }
            Spacer()
            if chevron { Image(systemName: "chevron.right").foregroundStyle(Theme.inkSecondary) }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    // MARK: Derived text

    private var networkName: String {
        if case .connected(let info) = account.state { return info.nickname ?? info.plan ?? "Starlink" }
        return "Starlink"
    }

    private var statusTitle: String {
        switch store.connection {
        case .connecting: "Connecting"
        case .offline: "Offline"
        case .live: store.isPaused ? "Paused" : (store.isOutage ? "No connection" : "Online")
        }
    }

    private var statusColor: Color {
        switch store.connection {
        case .connecting: Theme.inkMuted
        case .offline: Theme.critical
        case .live: store.isOutage ? Theme.critical : Theme.good
        }
    }

    private struct Notice { var title: String; var text: String; var action: String?; var page: Page?; var critical: Bool }

    /// One banner at most, most severe first. The 1% floor for "partially obstructed"
    /// is this app's choice, not a Starlink rule.
    private var notice: Notice? {
        if case .offline = store.connection, let diagnosis = store.dishDiagnosis {
            return Notice(title: "Cannot reach the dish: \(diagnosis.title.lowercased())", text: diagnosis.advice, action: nil, page: nil, critical: true)
        }
        guard let status = store.status, case .live = store.connection else { return nil }
        if store.isOutage { return Notice(title: "No connection", text: "The dish is not reaching the network.", action: "View events…", page: .detail(.events), critical: true) }
        if !status.activeAlerts.isEmpty { return Notice(title: "Alert", text: "The dish reports: \(status.alertTitles.joined(separator: ", ")).", action: "View statistics…", page: .statistics, critical: true) }
        if status.fractionObstructed >= 0.01 { return Notice(title: "Obstructed", text: "Starlink is partially obstructed.", action: "View obstructions…", page: .obstructions, critical: false) }
        return nil
    }

    private func noticeBanner(_ notice: Notice) -> some View {
        let color = notice.critical ? Theme.critical : Theme.warm
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "info.circle").foregroundStyle(color).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title).font(Theme.ui(15, .bold)).foregroundStyle(Theme.ink)
                    Text(notice.text).font(Theme.ui(13)).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let action = notice.action, let page = notice.page {
                Button { path.append(page) } label: {
                    Text(action).font(Theme.ui(13, .semibold)).frame(maxWidth: .infinity).padding(.vertical, 8)
                }
                .buttonStyle(.plain).background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color))
    }

    private var contentFilterSubtitle: String? {
        guard let servers = store.routerConfig?.nameservers else { return nil }
        return ContentFilter.current(servers)?.title ?? "Custom DNS"
    }

    private var obstructionSubtitle: String? {
        store.status.map { String(format: "%.1f%% obstructed", Double($0.fractionObstructed) * 100) }
    }

    private var alignmentSubtitle: String? {
        guard let reading = store.alignment else { return nil }
        return reading.isValid ? (reading.isAligned ? "Starlink is aligned" : "Starlink is misaligned") : "Unavailable"
    }

    // MARK: Pages

    private func pageHeader(_ page: Page) -> some View {
        ZStack {
            VStack(spacing: 1) {
                Text(page.title).font(Theme.ui(15, .bold)).foregroundStyle(Theme.ink)
                if let id = store.status?.deviceId, !id.isEmpty {
                    Text(id.hasPrefix("ut") ? String(id.dropFirst(2)) : id).font(Theme.mono(10)).foregroundStyle(Theme.inkMuted)
                }
            }
            HStack {
                Button { path.removeLast() } label: {
                    Image(systemName: "chevron.left").frame(width: 32, height: 32).background(Theme.surfaceRaised, in: Circle())
                }
                .buttonStyle(.plain).foregroundStyle(Theme.ink)
                .help("Back").accessibilityLabel("Back")
                Spacer()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    @ViewBuilder private func content(_ page: Page) -> some View {
        switch page {
        case .statistics: StatisticsCards(store: store) { path.append(.detail($0)) }
        case .network: NetworkPanel(store: store, account: account)
        case .contentFilter: ContentFilterPicker(store: store, account: account)
        case .obstructions:
            VStack(alignment: .trailing, spacing: 8) {
                SatelliteLink { path.append(.satellites) }
                ObstructionsSummary(store: store, domeHeight: 300)
            }
        case .alignment: AlignmentDetail(reading: store.alignment)
        case .speedTest: SpeedTestView(model: store.speedTest, store: store)
        case .satellites: SatelliteView(store: store, account: account)
        case .menuBar:
            Card(title: "Show in the menu bar") { ReadoutToggles().font(Theme.ui(13)) }
        case .detail(let metric):
            switch metric {
            case .ping, .latency: LatencyChart(samples: store.samples)
            case .power: PowerChart(samples: store.samples)
            case .throughput: VStack(spacing: 12) { ThroughputChart(samples: store.samples); ThroughputStatsCard(store: store) }
            case .events: EventsList(events: store.events, limit: 30)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Open dashboard…") { openWindow(id: "dashboard"); NSApp.activate(ignoringOtherApps: true) }
                .help("Show the full dashboard window")
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q").help("Quit StarPulse")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}
