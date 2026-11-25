import Foundation
import StarPulseCore
import UserNotifications

/// The conditions StarPulse can notify about, each with its own switch in Settings.
enum LinkAlert: CaseIterable {
    case outage, packetLoss, latency

    var settingsKey: String {
        switch self {
        case .outage: SettingsKey.notifyOutages
        case .packetLoss: SettingsKey.notifyPacketLoss
        case .latency: SettingsKey.notifyLatency
        }
    }

    /// Latency is off by default: a slow minute is common and rarely needs action.
    var onByDefault: Bool { self != .latency }

    var isEnabled: Bool { UserDefaults.standard.object(forKey: settingsKey) as? Bool ?? onByDefault }
}

/// macOS notifications for link problems (timing in ConditionWatch). Banners show even while StarPulse is in front.
final class LinkNotifier: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = LinkNotifier()

    func start() {
        UNUserNotificationCenter.current().delegate = self
        if LinkAlert.allCases.contains(where: \.isEnabled) { requestPermission() }
    }

    /// macOS asks only once; later calls return the saved answer.
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Outages get a "down" and a "back" notification; loss and latency only a "started" one.
    func post(_ alert: LinkAlert, _ event: ConditionWatch.Event, quality: LinkQuality) {
        guard alert.isEnabled else { return }
        let content = UNMutableNotificationContent()
        switch (alert, event) {
        case (.outage, .started(let since)):
            content.title = "Starlink is down"
            content.body = "No connection since \(since.formatted(date: .omitted, time: .shortened)). You will be told when it is back."
            content.sound = .default
        case (.outage, .ended(let duration)):
            content.title = "Starlink is back online"
            content.body = "The outage lasted \(Format.duration(duration))."
        case (.packetLoss, .started):
            content.title = "Starlink is losing packets"
            content.body = String(format: "About %.0f%% of pings were lost over the last minute. Calls and video may stutter.", quality.lossPercent ?? 0)
        case (.latency, .started):
            content.title = "Starlink latency is high"
            content.body = String(format: "Median latency was %.0f ms over the last minute.", quality.latencyMs ?? 0)
        case (.packetLoss, .ended), (.latency, .ended):
            return
        }
        // One identifier per alert, so "back online" replaces "down" in Notification Center.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "starpulse-\(alert)", content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
