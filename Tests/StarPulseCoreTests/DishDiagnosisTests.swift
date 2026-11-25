import Testing
@testable import StarPulseCore

@Suite struct DishDiagnosisTests {
    typealias Interface = DishDiagnosis.LocalInterface
    let dish = "192.168.100.1"
    let loopback = Interface(name: "lo0", address: "127.0.0.1")
    let wifi = Interface(name: "en0", address: "192.168.1.20")

    @Test func noUsableInterfaceMeansNoNetwork() {
        let selfAssigned = Interface(name: "en0", address: "169.254.3.4")
        #expect(DishDiagnosis.diagnose(dishHost: dish, interfaces: [loopback, selfAssigned], routeInterface: nil, starlinkRouterAnswers: false) == .noNetwork)
    }

    @Test func lanInsideDishRangeIsAClash() {
        let lan = Interface(name: "en0", address: "192.168.100.42")
        #expect(DishDiagnosis.diagnose(dishHost: dish, interfaces: [loopback, lan], routeInterface: "en0", starlinkRouterAnswers: false)
                == .addressClash(macAddress: "192.168.100.42"))
    }

    @Test func routeThroughVPNIsReported() {
        let vpn = Interface(name: "utun4", address: "10.8.0.2")
        #expect(DishDiagnosis.diagnose(dishHost: dish, interfaces: [wifi, vpn], routeInterface: "utun4", starlinkRouterAnswers: true) == .vpn(interface: "utun4"))
    }

    @Test func otherRouterMeansNoRoute() {
        #expect(DishDiagnosis.diagnose(dishHost: dish, interfaces: [wifi], routeInterface: "en0", starlinkRouterAnswers: false) == .noRoute(dishHost: dish))
    }

    @Test func starlinkRouterWithoutDishMeansDishSilent() {
        #expect(DishDiagnosis.diagnose(dishHost: dish, interfaces: [wifi], routeInterface: "en0", starlinkRouterAnswers: true) == .dishSilent)
    }

    @Test func customDishAddressSkipsTheClashCheck() {
        let lan = Interface(name: "en0", address: "192.168.100.42")
        #expect(DishDiagnosis.diagnose(dishHost: "10.1.1.1", interfaces: [lan], routeInterface: "en0", starlinkRouterAnswers: false) == .noRoute(dishHost: "10.1.1.1"))
    }
}
