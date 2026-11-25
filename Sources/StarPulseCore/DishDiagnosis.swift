import Foundation

/// Why the dish does not answer, guessed from what the Mac can see on its own side. The router's
/// routing table is out of reach, so a missing static route is inferred, not read.
public enum DishDiagnosis: Equatable, Sendable {
    case noNetwork
    /// This Mac sits inside the dish's own 192.168.100.x range, so packets for the dish stay on the LAN.
    case addressClash(macAddress: String)
    /// The kernel sends packets for the dish through a VPN interface.
    case vpn(interface: String)
    /// No Starlink router answers: own router (bypass mode) without a route to the dish, or another network.
    case noRoute(dishHost: String)
    /// The Starlink router answers but the dish does not.
    case dishSilent

    public struct LocalInterface: Equatable, Sendable {
        public var name: String
        public var address: String
        public init(name: String, address: String) { self.name = name; self.address = address }
        var isVPN: Bool { ["utun", "ipsec", "ppp", "tun", "tap"].contains { name.hasPrefix($0) } }
    }

    /// - Parameters:
    ///   - interfaces: this Mac's IPv4 interfaces.
    ///   - routeInterface: the interface the kernel would use to reach `dishHost`, if any.
    ///   - starlinkRouterAnswers: whether the Starlink router's API answered at the gateway.
    public static func diagnose(dishHost: String, interfaces: [LocalInterface], routeInterface: String?, starlinkRouterAnswers: Bool) -> DishDiagnosis {
        let usable = interfaces.filter { $0.name != "lo0" && !$0.address.hasPrefix("169.254.") }
        if usable.isEmpty { return .noNetwork }
        if dishHost.hasPrefix("192.168.100."),
           let clash = usable.first(where: { !$0.isVPN && $0.address.hasPrefix("192.168.100.") && $0.address != dishHost }) {
            return .addressClash(macAddress: clash.address)
        }
        if let routeInterface, let vpn = usable.first(where: { $0.name == routeInterface && $0.isVPN }) {
            return .vpn(interface: vpn.name)
        }
        return starlinkRouterAnswers ? .dishSilent : .noRoute(dishHost: dishHost)
    }

    public var title: String {
        switch self {
        case .noNetwork: "No network"
        case .addressClash: "Address clash"
        case .vpn: "VPN in the way"
        case .noRoute: "No route to the dish"
        case .dishSilent: "Dish not answering"
        }
    }

    public var advice: String {
        switch self {
        case .noNetwork:
            "This Mac is not connected to a network. Join the Starlink Wi-Fi or plug in Ethernet."
        case .addressClash(let address):
            "This Mac has \(address), inside the dish's own 192.168.100.x range, so traffic for the dish never leaves your network. Change your router's LAN range, for example to 192.168.1.x."
        case .vpn(let interface):
            "Traffic for the dish goes through \(interface), a VPN. Allow local network access in the VPN app, or disconnect it."
        case .noRoute(let host):
            "No Starlink router answers at the gateway. With your own router (bypass mode), the dish still answers at \(host), but the router needs a static route to \(host)/32 out of the Starlink WAN port; with dual-WAN, keep that route on the Starlink WAN. Also check System Settings › Privacy & Security › Local Network. Away from the Starlink network, there is no dish to read."
        case .dishSilent:
            "The Starlink router answers but the dish does not. Check the dish's power and cable, and the dish address in Settings."
        }
    }
}
