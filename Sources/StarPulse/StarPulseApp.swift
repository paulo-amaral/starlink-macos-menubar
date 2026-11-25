import AppKit
import StarPulseCore
import SwiftUI

@main
struct StarPulseApp: App {
    @State private var store: TelemetryStore
    @State private var account = AccountStore()
    @AppStorage(SettingsKey.readouts) private var readouts = Readout.latency.rawValue

    init() {
        Theme.registerFonts()
        OutageNotifier.shared.start()
        let store = TelemetryStore()
        store.start()
        _store = State(initialValue: store)
        let account = AccountStore()
        account.start()
        store.account = account
        _account = State(initialValue: account)
        NSApplication.shared.setActivationPolicy(.accessory)
        let saved = UserDefaults.standard.string(forKey: SettingsKey.appearance) ?? AppearanceChoice.dark.rawValue
        (AppearanceChoice(rawValue: saved) ?? .dark).apply()
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView(store: store, account: account)
        } label: {
            MenuBarLabel(store: store, readouts: Readout.parse(readouts))
        }
        .menuBarExtraStyle(.window)

        Window("StarPulse", id: "dashboard") {
            DashboardView(store: store, account: account)
        }
        .defaultSize(width: 1240, height: 900)

        Settings { SettingsView(account: account, store: store) }

        #if DEBUG
        // Lets the popover be looked at in a normal window while developing.
        Window("Popover preview", id: "popover-preview") { PopoverView(store: store, account: account) }
        Window("Settings preview", id: "settings-preview") { SettingsView(account: account, store: store) }
        Window("Guide preview", id: "guide-preview") { DeviceDnsGuide() }
        Window("Statistics preview", id: "statistics-preview") { ScrollView { StatisticsPanel(store: store).padding(20) }.frame(minWidth: 700, minHeight: 600).background(Theme.page) }
        Window("Network preview", id: "network-preview") { ScrollView { NetworkPanel(store: store, account: account).padding(20) }.frame(minWidth: 560, minHeight: 700).background(Theme.page) }
        #endif
    }
}

private struct MenuBarLabel: View {
    var store: TelemetryStore
    var readouts: [Readout]
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsKey.openAtLaunch) private var openAtLaunch = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: store.isOutage ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right")
            Text(store.menuBarText(readouts: readouts)).monospacedDigit()
        }
        .onAppear {
            #if DEBUG
            if UserDefaults.standard.bool(forKey: "debugPopoverPreview") { openWindow(id: "popover-preview") }
            if UserDefaults.standard.bool(forKey: "debugSettingsPreview") { openWindow(id: "settings-preview") }
            if UserDefaults.standard.bool(forKey: "debugNetworkPreview") { openWindow(id: "network-preview") }
            if UserDefaults.standard.string(forKey: "debugStatisticsMetric") != nil { openWindow(id: "statistics-preview") }
            if UserDefaults.standard.bool(forKey: "debugGuidePreview") { openWindow(id: "guide-preview") }
            #endif
            guard openAtLaunch else { return }
            openWindow(id: "dashboard")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
