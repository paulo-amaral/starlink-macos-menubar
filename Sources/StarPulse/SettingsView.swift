import ServiceManagement
import StarPulseCore
import SwiftUI

struct SettingsView: View {
    var account: AccountStore
    var store: TelemetryStore
    @State private var pane = UserDefaults.standard.string(forKey: "debugSettingsPane") ?? "starlink"

    var body: some View {
        VStack(spacing: 0) {
            AppSegmented(selection: $pane, options: [("starlink", "Starlink"), ("router", "Router"), ("app", "App")], help: "Settings section")
                .frame(width: 300).padding(.top, 16).padding(.bottom, 4)
            Group {
                switch pane {
                case "router": RouterSettingsPane(store: store, account: account)
                case "app": AppSettingsPane(account: account)
                default: StarlinkSettingsPane(store: store, account: account)
                }
            }
            .scrollContentBackground(.hidden)
        }
        .frame(width: 560, height: 580)
        .background(Theme.page)
        .appChrome()
    }
}

private let readOnlyHelp = "Changing hardware settings is not enabled yet; this shows the current values"

private struct SettingRow<Value: View>: View {
    var title: String
    var detail: String
    @ViewBuilder var value: Value

    var body: some View {
        LabeledContent {
            value
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
            }
        }
    }
}

struct StarlinkSettingsPane: View {
    var store: TelemetryStore
    var account: AccountStore

    var body: some View {
        Form {
            if let config = store.dishConfig {
                Section {
                    SettingRow(title: "Snow melt", detail: "Heats the panel to shed snow. Automatic uses the dish's own sensors.") { Text(config.snowMelt.label) }
                    SettingRow(title: "Sleep schedule", detail: "Power the dish down for part of every day") { Text(sleepText(config)) }
                    SettingRow(title: "Software updates", detail: UpdateWindow.containing(hour: config.updateRebootHour).range) {
                        Text(UpdateWindow.containing(hour: config.updateRebootHour).label)
                    }
                    SettingRow(title: "Defer updates", detail: "Hold firmware updates for up to 3 days") { Text(config.deferUpdates ? "On" : "Off") }
                }
            } else {
                Section { Text("Reading the dish settings…").foregroundStyle(Theme.inkSecondary) }
            }
            Section("Maintenance") {
                MaintenanceRow(title: "Reset obstruction map", detail: "Wipes the learned sky survey. Do this after physically moving the dish; it takes hours to relearn.", button: "Reset…",
                               confirm: "The dish forgets what it has learned about your sky and maps it again over the next hours.",
                               help: "Clear the dish's learned obstruction map") {
                    sent(try await store.performMaintenance(.clearObstructionMap, account: account), "The obstruction map was reset.")
                }
                MaintenanceRow(title: "Reboot Starlink", detail: "Internet drops for about 2 to 3 minutes while the dish restarts.", button: "Reboot…",
                               confirm: "Internet drops for about 2 to 3 minutes. StarPulse reconnects on its own.",
                               help: "Restart the dish; internet drops for 2 to 3 minutes") {
                    sent(try await store.performMaintenance(.reboot, account: account), "The dish is restarting.")
                }
                MaintenanceRow(title: "Factory reset Starlink", detail: "Wipes every dish setting back to how it shipped. Not reversible.", button: "Factory reset…")
            }
        }
        .formStyle(.grouped)
    }

    private func sent(_ route: DishMaintenance.Route, _ done: String) -> String {
        route == .lan ? "\(done) Sent over your local network." : "\(done) Sent through your Starlink account."
    }

    private func sleepText(_ config: DishConfig) -> String {
        guard config.sleepEnabled else { return "Off" }
        let start = SleepSchedule.localMinutes(fromUTC: config.sleepStartUTCMinutes)
        let end = (start + config.sleepDurationMinutes) % 1440
        func clock(_ minutes: Int) -> String {
            Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date())?.formatted(date: .omitted, time: .shortened) ?? "--"
        }
        return "\(clock(start)) to \(clock(end))"
    }
}

private struct MaintenanceRow: View {
    var title: String
    var detail: String
    var button: String
    var confirm = ""
    var help = readOnlyHelp
    /// nil keeps the row read-only; otherwise runs after confirmation and returns the outcome to show.
    var run: (() async throws -> String)? = nil
    @State private var asking = false
    @State private var busy = false
    @State private var outcome: (text: String, failed: Bool)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingRow(title: title, detail: detail) {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button(button) { asking = true }.disabled(run == nil).help(help)
                }
            }
            if let outcome {
                Text(outcome.text).font(Theme.ui(11)).foregroundStyle(outcome.failed ? Theme.critical : Theme.good)
            }
        }
        .confirmationDialog("\(title)?", isPresented: $asking) {
            Button(button.replacingOccurrences(of: "…", with: ""), role: .destructive) { start() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirm)
        }
    }

    private func start() {
        guard let run else { return }
        busy = true
        outcome = nil
        Task {
            do { outcome = (try await run(), false) } catch { outcome = (error.localizedDescription, true) }
            busy = false
        }
    }
}

struct RouterSettingsPane: View {
    var store: TelemetryStore
    var account: AccountStore
    @AppStorage(SettingsKey.routerHost) private var routerHost = ""

    var body: some View {
        Form {
            if let config = store.routerConfig {
                Section("Content filtering") { ContentFilterPicker(store: store, account: account) }
                Section("Networks") {
                    ForEach(config.networks, id: \.ssid) { network in
                        SettingRow(title: network.ssid, detail: "\(network.security) · password managed in the Starlink app") {
                            Text(network.bands.joined(separator: ", ")).font(Theme.mono(11))
                        }
                    }
                    if config.networks.isEmpty { Text("No networks reported.").foregroundStyle(Theme.inkSecondary) }
                }
                Section("Mesh nodes") {
                    ForEach(config.meshNodes, id: \.name) { node in
                        SettingRow(title: node.name, detail: node.hardware.isEmpty ? "" : "hardware \(node.hardware)") { Text(node.trusted ? "Trusted" : "Not trusted") }
                    }
                    if config.meshNodes.isEmpty { Text("No mesh nodes.").foregroundStyle(Theme.inkSecondary) }
                }
                Section {
                    SettingRow(title: "Router firmware", detail: config.country.isEmpty ? "" : "country \(config.country)") {
                        Text(store.routerStatus?.firmware ?? "--").font(Theme.mono(11)).textSelection(.enabled)
                    }
                    if let wan = store.routerStatus, !wan.wanIPv4.isEmpty || !wan.wanIPv6.isEmpty {
                        SettingRow(title: "WAN IPv4", detail: RouterStatus.isCarrierGradeNAT(wan.wanIPv4) ? "Shared by Starlink (CGNAT); not reachable from the internet" : "Address on the Starlink side") {
                            Text(wan.wanIPv4.isEmpty ? "--" : wan.wanIPv4).font(Theme.mono(11)).textSelection(.enabled)
                        }
                        SettingRow(title: "WAN IPv6", detail: "Public addresses assigned by Starlink") {
                            Text(wan.wanIPv6.isEmpty ? "--" : wan.wanIPv6.joined(separator: "\n")).font(Theme.mono(11)).multilineTextAlignment(.trailing).textSelection(.enabled)
                        }
                    }
                    SettingRow(title: "DNS servers", detail: config.nameservers.isEmpty ? "Default" : "Set on the router") {
                        Text(config.nameservers.joined(separator: ", ")).font(Theme.mono(11)).textSelection(.enabled)
                    }
                    SettingRow(title: "Bypass mode", detail: "Use your own networking gear behind the dish") { Text(config.bypassMode ? "On" : "Off") }
                }
            } else {
                Section { Text("Reading the router settings…").foregroundStyle(Theme.inkSecondary) }
            }
            Section("Maintenance") {
                MaintenanceRow(title: "Reboot router", detail: "Wi-Fi drops for a minute or two; the dish stays up.", button: "Reboot…")
                MaintenanceRow(title: "Factory reset router", detail: "Wipes the Wi-Fi name, password and every router setting. Not reversible.", button: "Factory reset…")
            }
            Section("Connection") {
                TextField("Router address", text: $routerHost, prompt: Text("Automatic (default gateway)"))
                    .help("Leave empty to use this Mac's default gateway. Port 9001 is used for the local API")
            }
        }
        .formStyle(.grouped)
    }
}

struct AppSettingsPane: View {
    var account: AccountStore
    @AppStorage(SettingsKey.host) private var host = "192.168.100.1"
    @AppStorage(SettingsKey.openAtLaunch) private var openAtLaunch = false
    @AppStorage(SettingsKey.appearance) private var appearance = AppearanceChoice.dark.rawValue
    @AppStorage(SettingsKey.rateUnit) private var rateUnit = RateUnit.automatic.rawValue
    @AppStorage(SettingsKey.throughputAxisMax) private var axisMax = 0.0
    @AppStorage(SettingsKey.notifyOutages) private var notifyOutages = true

    var body: some View {
        Form {
            Section("Menu bar") { ReadoutToggles() }
            Section("General") {
                OpenAtLoginToggle()
                Toggle("Open dashboard at launch", isOn: $openAtLaunch)
                    .help("Show the dashboard window when StarPulse starts")
                Toggle("Notify when Starlink is down", isOn: $notifyOutages)
                    .help("Alert after 30 seconds without a connection, and again when it is back")
                LabeledContent("Theme") {
                    AppSegmented(selection: $appearance, options: AppearanceChoice.allCases.map { ($0.rawValue, $0.label) },
                                  help: "Dark is the default; System follows macOS").frame(width: 240)
                }
            }
            Section("Throughput") {
                LabeledContent("Unit") {
                    AppSegmented(selection: $rateUnit, options: RateUnit.allCases.map { ($0.rawValue, $0.label) },
                                  help: "Automatic switches between Kbps and Mbps; the others keep one unit").frame(width: 240)
                }
                LabeledContent("Chart scale") {
                    AppSegmented(selection: $axisMax, options: [(0.0, "Auto"), (100.0, "100"), (250.0, "250"), (500.0, "500")],
                                  help: "Auto fits the data; a fixed top in Mbps keeps spikes comparable").frame(width: 240)
                }
            }
            Section("Dish") {
                TextField("Dish address", text: $host)
                    .help("Default 192.168.100.1. Port 9201 is used for the local API")
            }
            Section("Starlink account") { AccountSettingsRow(account: account) }
        }
        .formStyle(.grouped)
        .onChange(of: appearance) { _, new in (AppearanceChoice(rawValue: new) ?? .dark).apply() }
        .onChange(of: notifyOutages) { _, on in if on { OutageNotifier.shared.requestPermission() } }
    }
}

struct ReadoutToggles: View {
    @AppStorage(SettingsKey.readouts) private var readouts = Readout.latency.rawValue

    var body: some View {
        ForEach(Readout.allCases) { item in
            Toggle(item.label, isOn: Binding(
                get: { Readout.parse(readouts).contains(item) },
                set: { on in
                    var current = Readout.parse(readouts).filter { $0 != item }
                    if on { current.append(item) }
                    // At least one readout stays on, or the menu bar would show nothing.
                    if !current.isEmpty { readouts = Readout.encode(Readout.allCases.filter(current.contains)) }
                }
            ))
            .help("Show \(item.label.lowercased()) in the menu bar")
        }
    }
}

/// Starts StarPulse in the menu bar when you log in, through macOS's own login items (Dishylink issue #57).
private struct OpenAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Open at login", isOn: Binding(get: { enabled }, set: { change($0) }))
                .help("Start StarPulse in the menu bar when you log in, without opening a window")
            if let note { Text(note).font(Theme.ui(11)).foregroundStyle(Theme.warm) }
        }
    }

    private func change(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            note = SMAppService.mainApp.status == .requiresApproval ? "Allow StarPulse in System Settings › General › Login Items." : nil
        } catch {
            note = error.localizedDescription
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}
