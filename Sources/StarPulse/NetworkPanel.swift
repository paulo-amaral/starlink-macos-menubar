import Charts
import StarPulseCore
import SwiftUI

struct NetworkPanel: View {
    var store: TelemetryStore
    var account: AccountStore
    @State private var tab = Tab.devices
    @State private var selectedID: String?

    enum Tab: String, CaseIterable { case devices = "Devices", nodes = "Nodes", rules = "Rules" }

    var body: some View {
        content
        #if DEBUG
            // Development aid: open the first device's detail to look at it without clicking.
            .onAppear {
                switch UserDefaults.standard.string(forKey: "debugNetworkTab") {
                case "rules": tab = .rules
                case "nodes": tab = .nodes
                default: break
                }
            }
            .onChange(of: store.clients.count) { _, count in
                if UserDefaults.standard.bool(forKey: "debugDeviceDetail"), count > 0, selectedID == nil { selectedID = store.clients.first?.id }
            }
        #endif
    }

    @ViewBuilder private var content: some View {
        if let id = selectedID, let client = store.allClients.first(where: { $0.id == id }) {
            DeviceDetail(store: store, account: account, client: client) { selectedID = nil }
        } else {
            list
        }
    }

    private var rows: [WifiClient] {
        let source = tab == .devices ? store.clients : store.nodes
        return source.sorted { a, b in
            let aSelf = store.localAddresses.contains(a.ip), bSelf = store.localAddresses.contains(b.ip)
            if aSelf != bSelf { return aSelf }
            let aRate = store.clientHistory.rate(for: a.id), bRate = store.clientHistory.rate(for: b.id)
            let aSum = aRate.downMbps + aRate.upMbps, bSum = bRate.downMbps + bRate.upMbps
            return aSum != bSum ? aSum > bSum : a.displayName < b.displayName
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            AppSegmented(selection: $tab, options: [(Tab.devices, "Devices \(store.clients.count)"), (Tab.nodes, "Nodes \(store.nodes.count)"), (Tab.rules, "Rules")],
                          help: "Switch between devices, router nodes and rules")
                .frame(maxWidth: 360).frame(maxWidth: .infinity)
            if tab == .rules {
                RulesTab(store: store, account: account)
            } else if tab == .nodes {
                NodesTab(store: store)
            } else {
            Text("\(rows.count) \(tab == .devices ? "devices" : "nodes") · live from the router at \(store.routerHost)")
                .font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
            if let error = store.routerError, store.allClients.isEmpty {
                Text("Cannot read the router at \(store.routerHost): \(error). Set its address in Settings.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary)
            }
            ForEach(rows) { client in
                Button { selectedID = client.id } label: { DeviceRow(store: store, client: client) }
                    .buttonStyle(.plain)
            }
            }
        }
    }
}

private struct DeviceRow: View {
    var store: TelemetryStore
    var client: WifiClient

    var body: some View {
        let rate = store.clientHistory.rate(for: client.id)
        HStack(spacing: 12) {
            SignalGlyph(dbm: client.signalDbm, wired: client.band == .wired).frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(client.displayName).font(Theme.ui(13, .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(subtitle).font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if rate.downMbps + rate.upMbps >= 0.01 {
                Text("↓\(megabits(rate.downMbps)) ↑\(megabits(rate.upMbps))").font(Theme.mono(10)).foregroundStyle(Theme.down)
            }
            if client.blocked { Chip(text: "Paused", color: Theme.warm) }
            Chip(text: client.band.label, color: Theme.inkSecondary)
            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.inkSecondary)
        }
        .padding(10)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .help("Show the details and history of \(client.displayName)")
    }

    private var subtitle: String {
        var parts: [String] = []
        if store.localAddresses.contains(client.ip) { parts.append("This device") }
        if let vendor = MacVendor.label(for: client.mac) { parts.append(vendor) }
        if parts.isEmpty { parts.append(client.ip) }
        return parts.joined(separator: " · ")
    }
}

func megabits(_ mbps: Double) -> String { mbps >= 10 ? String(format: "%.0f", mbps) : String(format: "%.1f", mbps) }

struct SignalGlyph: View {
    var dbm: Float?
    var wired: Bool

    var body: some View {
        if wired { Image(systemName: "cable.connector.horizontal").foregroundStyle(Theme.ink) }
        else {
            // -90 dBm reads as empty and -40 dBm as full.
            let level = dbm.map { max(0, min(1, Double(($0 + 90) / 50))) } ?? 0
            Image(systemName: "wifi", variableValue: level).foregroundStyle(Theme.ink)
        }
    }
}

struct DeviceDetail: View {
    var store: TelemetryStore
    var account: AccountStore
    var client: WifiClient
    var back: () -> Void
    @State private var range = HistoryRange.m15
    @State private var confirming = false
    /// The state asked for, until the router's live list shows it.
    @State private var pending: Bool?
    @State private var pauseError: String?

    var body: some View {
        let rate = store.clientHistory.rate(for: client.id)
        let series = store.clientHistory.series(for: client.id, range: range, now: Date())
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Button(action: back) { Image(systemName: "chevron.left").frame(width: 28, height: 28).background(Theme.surfaceRaised, in: Circle()) }
                    .buttonStyle(.plain).foregroundStyle(Theme.ink).help("Back to the device list").accessibilityLabel("Back")
                SignalGlyph(dbm: client.signalDbm, wired: client.band == .wired)
                VStack(alignment: .leading, spacing: 0) {
                    Text(client.displayName).font(Theme.ui(17, .bold)).foregroundStyle(Theme.ink)
                    Text(headerSubtitle).font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
                }
            }
            VStack(spacing: 0) {
                row("Status", client.blocked ? "paused" : (rate.downMbps + rate.upMbps >= 0.01 ? "active" : "idle"))
                row("Role", roleText)
                row("Connected to", "Router")
                row("Manufacturer", MacVendor.label(for: client.mac) ?? "Unknown")
                row("Connection", client.band.label)
                row("Signal", client.signalDbm.map { "\(Int($0.rounded())) dBm · \(SignalQuality.label(dbm: $0))" } ?? "--")
                row("IP address", client.ip)
                row("MAC address", client.mac, help: "As the router reports it; this firmware masks the last three bytes")
                row("Connected for", Format.duration(TimeInterval(client.associatedSeconds)))
                row("Data this period", String(format: "↓ %.2f GB  ↑ %.2f GB", Double(client.downloadMB) / 1000, Double(client.uploadMB) / 1000),
                    help: "Totals as the router counts them, in GB")
            }
            .padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
            pauseControl
            HStack {
                Text("Throughput").font(Theme.ui(15, .semibold)).foregroundStyle(Theme.ink)
                Spacer()
                RangePicker(range: $range)
            }
            chart("Download", value: rate.downMbps, color: Theme.down, series: series.map { ($0.date, $0.downMbps) })
            chart("Upload", value: rate.upMbps, color: Theme.up, series: series.map { ($0.date, $0.upMbps) })
            if range != .m15 {
                Text("History builds while the app is open and is kept in memory only; the router keeps none.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    /// Pause and resume, as in the Starlink app. The write goes through the Starlink account; the live
    /// "Paused" state comes back from the router itself a few seconds later.
    private var pauseControl: some View {
        let isSelf = store.localAddresses.contains(client.ip)
        let waiting = pending.map { $0 != client.blocked } ?? false
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(statusLine(waiting: waiting)).font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary)
                Spacer()
                if waiting { ProgressView().controlSize(.small) }
                Button(client.blocked ? "Resume…" : "Pause…") { confirming = true }
                    .disabled(isSelf || waiting || !account.isConnected || client.clientId == nil)
                    .help(isSelf ? "This Mac cannot pause itself; it would cut StarPulse off"
                          : !account.isConnected ? "Sign in to your Starlink account to pause devices"
                          : client.blocked ? "Give this device its internet back" : "Block this device's internet until you resume it")
            }
            if let pauseError { Text(pauseError).font(Theme.ui(11)).foregroundStyle(Theme.critical) }
        }
        .confirmationDialog(client.blocked ? "Resume \(client.displayName)?" : "Pause \(client.displayName)?", isPresented: $confirming) {
            Button(client.blocked ? "Resume" : "Pause", role: client.blocked ? nil : .destructive) { apply(!client.blocked) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(client.blocked
                 ? (store.rules.pausedByStarPulse(client.clientId)
                    ? "Its internet comes back once the router applies the change."
                    : "This pause was not made by StarPulse; it may have been set in the Starlink app or by someone else on your account. Resuming removes it.")
                 : "Its internet stays blocked until you resume it. The change goes to your router through your Starlink account.")
        }
        .onChange(of: client.blocked) { _, now in if pending == now { pending = nil } }
    }

    private func statusLine(waiting: Bool) -> String {
        if waiting { return "Waiting for the router to confirm…" }
        return client.blocked ? "This device's internet is paused." : "Pause blocks this device's internet until you resume it."
    }

    private func apply(_ paused: Bool) {
        pauseError = nil
        pending = paused
        Task {
            do {
                try await account.setPaused(paused, client: client, routerHost: store.routerHost)
                // The block reaches the router's live list seconds later; give up waiting after 45 s.
                try? await Task.sleep(for: .seconds(45))
                if pending == paused { pending = nil; pauseError = "Starlink accepted the change, but the router has not shown it yet." }
            } catch {
                pending = nil
                pauseError = error.localizedDescription
            }
        }
    }

    private var roleText: String {
        switch client.role { case .client: "CLIENT"; case .repeater: "REPEATER"; case .controller: "CONTROLLER"; case .unknown: "--" }
    }

    private var headerSubtitle: String {
        var parts: [String] = []
        if store.localAddresses.contains(client.ip) { parts.append("This device") }
        if !client.givenName.isEmpty, !client.name.isEmpty, client.givenName != client.name { parts.append(client.name) }
        if let vendor = MacVendor.label(for: client.mac) { parts.append(vendor) }
        return parts.joined(separator: " · ")
    }

    private func row(_ label: String, _ value: String, help: String? = nil) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label).font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary)
                Spacer()
                Text(value).font(Theme.mono(11)).foregroundStyle(Theme.ink).textSelection(.enabled)
            }
            .padding(.vertical, 7)
            Divider().overlay(Theme.hairline)
        }
        .help(help ?? "")
    }

    private func chart(_ title: String, value: Double, color: Color, series: [(Date, Double)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
                Spacer()
                Text("\(megabits(value)) Mbps").font(Theme.mono(11, .medium)).foregroundStyle(Theme.ink)
            }
            Chart(Array(series.enumerated()), id: \.offset) { _, point in
                AreaMark(x: .value("Time", point.0), y: .value("Mbps", point.1)).foregroundStyle(LinearGradient(colors: [color.opacity(0.3), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", point.0), y: .value("Mbps", point.1)).foregroundStyle(color)
            }
            .chartYScale(domain: 0...max(1, (series.map(\.1).max() ?? 0) * 1.15))
            .frame(height: 110)
        }
    }
}

struct Chip: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text).font(Theme.mono(10)).foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.6)))
    }
}

/// The router and any mesh nodes, laid out like the Starlink app's Nodes tab.
struct NodesTab: View {
    var store: TelemetryStore
    @State private var showRouter = false

    static let meshGuide = URL(string: "https://starlink.com/support/article/e729e467-6572-99c0-1035-cdd61b2e2cb7")!

    /// A Mini's router is inside the dish; other kits have a separate router.
    private var routerTitle: (name: String, detail: String) {
        if store.status?.hardwareVersion.hasPrefix("mini") == true { return ("Starlink Mini", "Built-in router") }
        let hardware = store.routerStatus?.hardwareVersion ?? ""
        return ("Starlink Router", hardware.isEmpty ? "Router" : "Router \(hardware)")
    }

    private var meshNodes: [WifiClient] { store.nodes.filter { $0.role == .repeater } }

    var body: some View {
        if showRouter {
            RouterNodeDetail(store: store, title: routerTitle.name) { showRouter = false }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Button { showRouter = true } label: {
                    nodeRow(symbol: "wifi.router", title: routerTitle.name, detail: routerTitle.detail, trailing: "\(store.clients.count) devices")
                }
                .buttonStyle(.plain).help("Show the router's details")
                ForEach(meshNodes) { node in
                    nodeRow(symbol: "dot.radiowaves.left.and.right", title: node.displayName,
                            detail: "Mesh node · \(node.band.label)\(node.signalDbm.map { " · \(Int($0.rounded())) dBm" } ?? "")", trailing: nil)
                }
                Button { NSWorkspace.shared.open(Self.meshGuide) } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "plus").font(.system(size: 16, weight: .medium)).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Extend WiFi coverage").font(Theme.ui(15, .bold)).foregroundStyle(Theme.ink)
                            Text("Learn how to set up mesh").font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right").foregroundStyle(Theme.inkSecondary)
                    }
                    .padding(16)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.inkMuted.opacity(0.6)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Theme.ink)
                .help("Open Starlink's guide to adding mesh nodes")
            }
        }
    }

    private func nodeRow(symbol: String, title: String, detail: String, trailing: String?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 16)).frame(width: 28).foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.ui(15, .bold)).foregroundStyle(Theme.ink)
                Text(detail).font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary)
            }
            Spacer()
            if let trailing { Text(trailing).font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary) }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.inkSecondary)
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}

struct RouterNodeDetail: View {
    var store: TelemetryStore
    var title: String
    var back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: back) { Label("Nodes", systemImage: "chevron.left") }
                .buttonStyle(.plain).foregroundStyle(Theme.ink).font(Theme.ui(13, .semibold)).help("Back to the node list")
            Text(title).font(Theme.ui(18, .bold)).foregroundStyle(Theme.ink)
            VStack(spacing: 0) {
                row("Address", store.routerHost)
                row("Hardware", store.routerStatus?.hardwareVersion ?? "--")
                row("Firmware", store.routerStatus?.firmware ?? "--")
                row("Connected devices", "\(store.clients.count)")
                row("Wi-Fi networks", store.routerConfig?.networks.map { "\($0.ssid) (\($0.bands.joined(separator: ", ")))" }.joined(separator: "; ") ?? "--")
                row("Mesh nodes", "\(store.routerConfig?.meshNodes.count ?? 0)")
                row("DNS", store.routerConfig.map { DnsPreset.matching($0.nameservers)?.name ?? $0.nameservers.joined(separator: ", ") } ?? "--")
                row("Latency to Starlink", store.routerStatus?.popLatencyMs.map { "\(Int($0.rounded())) ms" } ?? "--")
                row("Country", store.routerConfig?.country ?? "--")
            }
            .padding(12).background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary)
                Spacer(minLength: 16)
                Text(value).font(Theme.mono(11)).foregroundStyle(Theme.ink).multilineTextAlignment(.trailing).textSelection(.enabled)
            }
            .padding(.vertical, 7)
            Divider().overlay(Theme.hairline)
        }
    }
}
