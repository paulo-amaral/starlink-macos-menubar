import Foundation
import StarPulseCore
import UserNotifications

/// macOS notifications for long outages (timing in OutageWatch). Banners show even while StarPulse is in front.
final class OutageNotifier: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = OutageNotifier()

    static var isEnabled: Bool { UserDefaults.standard.object(forKey: SettingsKey.notifyOutages) as? Bool ?? true }

    func start() {
        UNUserNotificationCenter.current().delegate = self
        if Self.isEnabled { requestPermission() }
    }

    /// macOS asks only once; later calls return the saved answer.
    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(_ event: OutageWatch.Event) {
        guard Self.isEnabled else { return }
        let content = UNMutableNotificationContent()
        switch event {
        case .down(let since):
            content.title = "Starlink is down"
            content.body = "No connection since \(since.formatted(date: .omitted, time: .shortened)). You will be told when it is back."
            content.sound = .default
        case .restored(let duration):
            content.title = "Starlink is back online"
            content.body = "The outage lasted \(Format.duration(duration))."
        }
        // One identifier, so "back online" replaces "down" in Notification Center.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "starpulse-outage", content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
