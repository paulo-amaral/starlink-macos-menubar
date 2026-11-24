#if DEBUG
import Foundation
import StarPulseCore

/// Development aid for documentation screenshots: replaces anything that identifies a household
/// (device names, addresses, network name, account details, location, device ids) with neutral values.
/// Compiled only into debug builds and enabled with `defaults write app.starpulse.mac debugAnonymize -bool true`.
enum Anonymizer {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "debugAnonymize") }

    private static let names = ["MacBook Pro", "iPhone", "Living Room TV", "iPad", "Android Phone", "Apple Watch", "Work Laptop", "Smart Speaker", "Game Console", "E-reader", "Thermostat", "Printer"]

    static func clients(_ clients: [WifiClient]) -> [WifiClient] {
        guard isOn else { return clients }
        var index = 0
        return clients.map { client in
            var c = client
            guard c.role == .client else { c.name = "Router"; c.givenName = ""; return c }
            c.givenName = names[index % names.count]
            c.name = c.givenName
            c.ip = "192.168.1.\(20 + index)"
            c.mac = String(format: "02:00:00:00:00:%02x", index) // locally administered: shown as "Private"
            index += 1
            return c
        }
    }

    static func status(_ status: DishStatus?) -> DishStatus? {
        guard isOn, var s = status else { return status }
        s.deviceId = "ut00000000-00000000-00000000"
        s.countryCode = "US"
        return s
    }

    static func routerStatus(_ status: RouterStatus) -> RouterStatus {
        guard isOn else { return status }
        var s = status
        s.deviceId = "Router-000000000000000000000000"
        s.wanIPv4 = "100.64.0.2"
        s.wanIPv6 = ["2001:db8::1/64"] // documentation range
        return s
    }

    static func config(_ config: RouterConfig?) -> RouterConfig? {
        guard isOn, var c = config else { return config }
        c.networks = c.networks.map { var n = $0; n.ssid = "Starlink"; return n }
        c.country = "US"
        return c
    }

    static func account(_ account: CloudAccount) -> CloudAccount {
        guard isOn else { return account }
        var a = account
        a.name = "Starlink User"; a.email = "user@example.com"; a.nickname = "Home"; a.locality = "Redmond, WA"
        a.serviceLineNumber = "SL-000000-00000-00"; a.accountReference = "ACC-000000-00000-00"
        a.latitude = 47.674; a.longitude = -122.121 // a public reference point, not the real service address
        return a
    }
}
#endif
