import Foundation

/// A restriction on the Starlink service itself (plan, account, location, speed limits), read from
/// dish_get_status. Code meanings follow the dish's own enum reflection as documented by StarlinkBar
/// (github.com/bereto-dev/starlink-monitor, MIT) for firmware 2026.10; unknown codes still show.
public struct ServiceNotice: Equatable, Sendable {
    public var title: String
    public var text: String
    /// Service off or cut back by account or location, rather than only slowed down.
    public var critical: Bool

    public static func from(_ status: DishStatus) -> ServiceNotice? {
        if status.disablementCode > 1 {
            let text = disablement[status.disablementCode] ?? "Starlink service is restricted on this dish (code \(status.disablementCode)). Check the Starlink app."
            return ServiceNotice(title: "Service restricted", text: text, critical: true)
        }
        let down = status.downloadLimitReason > 1 ? status.downloadLimitReason : nil
        let up = status.uploadLimitReason > 1 ? status.uploadLimitReason : nil
        guard let reason = down ?? up else { return nil }
        var text = speedLimit[reason] ?? "Speeds are limited on this dish (reason \(reason))."
        if down == nil { text += " Upload only." } else if up == nil { text += " Download only." }
        return ServiceNotice(title: "Speeds limited", text: text, critical: false)
    }

    static let disablement: [Int: String] = [
        2: "This dish has no active Starlink plan. Check your account in the Starlink app.",
        3: "Service is limited because the dish is too far from its service address.",
        4: "Service is off: the dish is at sea without an ocean plan.",
        6: "Starlink is not available in this country.",
        7: "The data limit is reached. Service stays restricted until you add data or the billing cycle starts again.",
        8: "Starlink is turned off in this area for now.",
        10: "This plan does not allow roaming.",
        11: "Starlink cannot confirm where the dish is, so service is limited.",
        12: "The Starlink account is disabled. Check billing in the Starlink app.",
        13: "The dish software is too old for service and needs an update.",
        14: "Service is paused: the dish is moving too fast for this plan.",
        15: "Service is limited while flying over this area.",
        16: "Starlink is not allowed in this area.",
        17: "Service is limited outside the dish's home region.",
    ]

    static let speedLimit: [Int: String] = [
        2: "Speeds are limited by the plan's policy right now.",
        3: "Speeds are capped by a limit set on the Starlink account.",
        5: "The data limit is reached, so speeds are reduced until you add data or the billing cycle starts again.",
        6: "Speeds are reduced: the plan is on its low-speed tier.",
    ]
}
