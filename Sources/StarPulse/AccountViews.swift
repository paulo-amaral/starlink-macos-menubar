import StarPulseCore
import SwiftUI

struct AccountCard: View {
    var account: AccountStore

    var body: some View {
        Card(title: "Starlink account") {
            switch account.state {
            case .connected(let info):
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(info.name ?? info.nickname ?? "Connected").font(Theme.ui(13, .semibold)).foregroundStyle(Theme.ink)
                        Text([info.plan, info.nickname, info.locality].compactMap { $0 }.joined(separator: " · "))
                            .font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary)
                    }
                    Spacer()
                    Text("\(info.terminalCount) terminal\(info.terminalCount == 1 ? "" : "s")")
                        .font(Theme.mono(11)).foregroundStyle(Theme.inkMuted)
                }
            case .connecting:
                Text("Connecting to your Starlink account...").font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary)
            case .expired:
                prompt("The Starlink session expired.", button: "Sign in again…")
            case .failed(let message):
                prompt(message, button: "Try again…")
            case .signedOut:
                prompt("Sign in to see your plan and service line. Your password is entered on starlink.com and never reaches StarPulse.", button: "Sign in to Starlink…")
            }
        }
    }

    private func prompt(_ text: String, button: String) -> some View {
        HStack {
            Text(text).font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary)
            Spacer()
            Button(button) { account.signIn() }.help("Open the Starlink sign-in page")
        }
    }
}

struct AccountSettingsRow: View {
    var account: AccountStore

    var body: some View {
        switch account.state {
        case .connected(let info):
            LabeledContent("Signed in", value: info.name ?? info.email ?? "Starlink account")
            Button("Sign out") { account.signOut() }.help("Forget the Starlink session on this Mac")
        case .connecting:
            LabeledContent("Status", value: "Connecting...")
        case .expired:
            LabeledContent("Status", value: "Session expired")
            Button("Sign in again…") { account.signIn() }.help("Open the Starlink sign-in page")
        case .failed(let message):
            LabeledContent("Status", value: message)
            Button("Try again…") { account.signIn() }.help("Open the Starlink sign-in page")
        case .signedOut:
            LabeledContent("Status", value: "Signed out")
            Button("Sign in to Starlink…") { account.signIn() }.help("Open the Starlink sign-in page")
        }
    }
}
