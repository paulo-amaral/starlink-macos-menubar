import StarPulseCore
import SwiftUI

/// The Starlink app's Content Filtering (Settings › Router), in its layout: pick an option, then Save.
/// Shown in the menu bar popover and in Settings › Router.
struct ContentFilterPicker: View {
    var store: TelemetryStore
    var account: AccountStore
    /// nil follows what the router reports; set once you pick something else.
    @State private var choice: ContentFilter?
    @State private var saving = false
    @State private var outcome: (text: String, failed: Bool)?

    var body: some View {
        let servers = store.routerConfig?.nameservers
        let current = servers.flatMap(ContentFilter.current)
        let selected = choice ?? current
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(ContentFilter.allCases, id: \.self) { filter in option(filter, selected: filter == selected) }
            }
            if let servers, current == nil {
                Text("Your router uses DNS servers set some other way (\(servers.joined(separator: ", "))). Saving a choice replaces them.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.warm).fixedSize(horizontal: false, vertical: true)
            }
            Link(destination: ContentFilter.helpURL) {
                Label("Learn more about content filtering", systemImage: "arrow.up.right.square").labelStyle(TrailingIcon())
            }
            .buttonStyle(.plain)
            .font(Theme.ui(12)).foregroundStyle(Theme.ink)
            .help("Open Starlink's help article on content filtering")
            Button { save(selected) } label: {
                Group { if saving { ProgressView().controlSize(.small) } else { Text("SAVE").tracking(1) } }
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.appPrimary)
            .disabled(!account.isConnected || saving || selected == nil || selected == current)
            .help(account.isConnected ? "Apply this filter to every device on your Starlink network" : "Sign in to your Starlink account first")
            if !account.isConnected {
                Text("Sign in to your Starlink account to change the filter. The router accepts changes only through Starlink.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.warm).fixedSize(horizontal: false, vertical: true)
            }
            if let outcome {
                Text(outcome.text).font(Theme.ui(11)).foregroundStyle(outcome.failed ? Theme.critical : Theme.good)
            }
            Text("Like the Starlink app, this makes the router hand out Cloudflare for Families DNS. It is a best-effort filter: a device with its own DNS or a VPN is not covered.")
                .font(Theme.ui(10)).foregroundStyle(Theme.inkMuted).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func option(_ filter: ContentFilter, selected: Bool) -> some View {
        Button { choice = filter; outcome = nil } label: {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    Circle().stroke(Theme.ink, lineWidth: 1.5).frame(width: 20, height: 20)
                    if selected { Circle().fill(Theme.ink).frame(width: 11, height: 11) }
                }
                .padding(.top, 1)
                VStack(alignment: .leading, spacing: 5) {
                    Text(filter.title.uppercased()).font(Theme.ui(13, .bold)).foregroundStyle(Theme.ink)
                    if let detail = filter.detail { Text(detail).font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary) }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(saving)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func save(_ filter: ContentFilter?) {
        guard let filter else { return }
        saving = true
        outcome = nil
        Task {
            do {
                outcome = (try await store.applyContentFilter(filter, account: account), false)
                choice = nil
            } catch {
                outcome = (error.localizedDescription, true)
            }
            saving = false
        }
    }
}

private struct TrailingIcon: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.title; configuration.icon }
    }
}
