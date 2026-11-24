import AppKit
import SwiftUI

/// StarPulse's own controls. macOS draws its standard buttons, segmented controls and pop-up menus with the
/// system font, ignoring the app's; these keep every control in the app's type and colours.
struct AppButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .secondary
    var compact = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.ui(compact ? 12 : 13, .semibold))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 5 : 7)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(kind == .secondary ? Theme.hairline : .clear))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: 8))
    }

    private var foreground: Color {
        switch kind { case .primary: Theme.page; case .secondary: Theme.ink; case .destructive: .white }
    }
    private var background: Color {
        switch kind { case .primary: Theme.ink; case .secondary: Theme.surfaceRaised; case .destructive: Theme.critical }
    }
}

extension ButtonStyle where Self == AppButtonStyle {
    static var appPrimary: AppButtonStyle { AppButtonStyle(kind: .primary) }
    static var appSecondary: AppButtonStyle { AppButtonStyle(kind: .secondary) }
    static var appDestructive: AppButtonStyle { AppButtonStyle(kind: .destructive) }
    static var appCompact: AppButtonStyle { AppButtonStyle(kind: .secondary, compact: true) }
}

/// Pill selector in the manner of the Starlink and Dishylink apps: the chosen option is a filled pill.
struct AppSegmented<Value: Hashable>: View {
    @Binding var selection: Value
    var options: [(value: Value, label: String)]
    var help: String = ""

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection
                Button { selection = option.value } label: {
                    Text(option.label)
                        .font(Theme.ui(12, .semibold))
                        .lineLimit(1)
                        .foregroundStyle(selected ? Theme.page : Theme.inkSecondary)
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .frame(maxWidth: .infinity)
                        .background(selected ? Theme.ink : .clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.surfaceRaised, in: Capsule())
        .overlay(Capsule().stroke(Theme.hairline))
        .help(help)
    }
}

/// A value shown in the mono face with a copy button that confirms what it did.
struct CopyField: View {
    var value: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(value).font(Theme.mono(12)).foregroundStyle(Theme.ink).textSelection(.enabled).lineLimit(1)
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.appCompact)
            .help("Copy \(value)")
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 6)
        .background(Theme.page, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.hairline))
    }
}

/// Header shared by every panel and sheet: title, optional subtitle, and a close button (Escape works too).
struct SheetHeader: View {
    var title: String
    var subtitle: String? = nil
    var close: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.ui(18, .bold)).foregroundStyle(Theme.ink)
                if let subtitle { Text(subtitle).font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 28, height: 28)
                    .background(Theme.surfaceRaised, in: Circle())
            }
            .buttonStyle(.plain).foregroundStyle(Theme.inkSecondary)
            .keyboardShortcut(.cancelAction)
            .help("Close").accessibilityLabel("Close")
        }
    }
}

/// Small uppercase label above a group of controls.
struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased()).font(Theme.ui(10, .semibold)).tracking(0.8).foregroundStyle(Theme.inkSecondary)
    }
}

extension View {
    /// The app's type and controls for a whole window or sheet.
    func appChrome() -> some View {
        self.font(Theme.ui(13)).buttonStyle(.appSecondary).tint(Theme.ink)
    }
}
