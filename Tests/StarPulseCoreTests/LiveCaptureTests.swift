import Foundation
import Testing
@testable import StarPulseCore

/// Opt-in: set STARPULSE_LIVE_DIR to a folder holding resp_status.bin and resp_history.bin
/// captured from a real dish. Captures stay out of the repo (they carry the device id).
private let liveDir = ProcessInfo.processInfo.environment["STARPULSE_LIVE_DIR"]

@Test(.enabled(if: liveDir != nil))
func realDishCaptureDecodes() throws {
    let dir = URL(fileURLWithPath: try #require(liveDir))
    let status = try DishDecoder.decodeStatus(response: GrpcWeb.decodeResponse(body: Data(contentsOf: dir.appending(path: "resp_status.bin")), headerStatus: nil, headerMessage: nil))
    let history = try DishDecoder.decodeHistory(response: GrpcWeb.decodeResponse(body: Data(contentsOf: dir.appending(path: "resp_history.bin")), headerStatus: nil, headerMessage: nil), now: Date())

    let answered = history.samples.compactMap(\.latencyMs)
    print("LIVE status: hw=\(status.hardwareVersion) fw=\(status.softwareVersion) uptime=\(status.uptimeSeconds)s latency=\(status.latencyMs)ms drop=\(status.dropRate) down=\(Format.rate(status.downlinkBps)) up=\(Format.rate(status.uplinkBps)) obstructed=\(status.fractionObstructed) eth=\(status.ethSpeedMbps) alerts=\(status.activeAlerts)")
    print("LIVE history: samples=\(history.samples.count) counter=\(history.newestCounter) answered=\(answered.count) maxPower=\(history.samples.map(\.powerW).max() ?? 0) maxDown=\(history.samples.map(\.downlinkBps).max() ?? 0) events=\(history.events.map(\.title)) outages=\(TelemetrySample.outageRanges(history.samples).count)")

    #expect(!status.hardwareVersion.isEmpty)
    #expect(status.uptimeSeconds > 0)
    #expect(history.samples.count == 900)
    #expect(!answered.isEmpty)
}

@Test(.enabled(if: liveDir != nil))
func realRouterCaptureDecodes() throws {
    let dir = URL(fileURLWithPath: try #require(liveDir))
    let body = try Data(contentsOf: dir.appending(path: "resp_clients.bin"))
    let clients = try RouterDecoder.decodeClients(response: GrpcWeb.decodeResponse(body: body, headerStatus: nil, headerMessage: nil))
    print("LIVE router: clients=\(clients.count) bands=\(clients.map(\.band.label)) roles=\(clients.map(\.role.rawValue)) activeMbps=\(clients.map(\.throughputMbps))")
    #expect(!clients.isEmpty)
    #expect(clients.contains { $0.role == .controller })
}

/// Opt-in network check against real hardware, read-only, nothing written to disk:
/// STARPULSE_LIVE_NET=<router host> swift test
private let liveRouterHost = ProcessInfo.processInfo.environment["STARPULSE_LIVE_NET"]

@Test(.enabled(if: liveRouterHost != nil))
func liveConfigReadsFromRealHardware() async throws {
    let dish = DishClient()
    let dishConfig = try await dish.config()
    let host = try #require(liveRouterHost)
    let router = try #require(RouterAPI(host: host))
    let routerConfig = try await router.config()
    let status = try await router.status()
    print("LIVE dish config: snow=\(dishConfig.snowMelt.label) sleep=\(dishConfig.sleepEnabled) updateWindow=\(UpdateWindow.containing(hour: dishConfig.updateRebootHour).label) defer=\(dishConfig.deferUpdates)")
    print("LIVE router: networks=\(routerConfig.networks.map { "\($0.ssid.prefix(3))*** \($0.bands) \($0.security)" }) mesh=\(routerConfig.meshNodes.count) country=\(routerConfig.country) dns=\(routerConfig.nameservers.count) fw=\(status.firmware) hw=\(status.hardwareVersion) popLatency=\(status.popLatencyMs ?? -1)")
    #expect(!routerConfig.networks.isEmpty)
    #expect(!status.firmware.isEmpty)
}

/// Opt-in timing of the satellite tracker on a real CelesTrak file: STARPULSE_TLE_FILE=/path/starlink.tle
private let tleFile = ProcessInfo.processInfo.environment["STARPULSE_TLE_FILE"]

@Test(.enabled(if: tleFile != nil))
func trackerSpeedOnTheFullConstellation() throws {
    let path = try #require(tleFile)
    let tles = TLE.parse(try String(contentsOfFile: path, encoding: .utf8))
    let setup = ContinuousClock.now
    let tracker = StarlinkTracker(tles: tles, observer: Observer(latitudeDeg: 0, longitudeDeg: 0))
    let setupTime = ContinuousClock.now - setup
    let start = ContinuousClock.now
    var visible = 0
    for step in 0..<5 { visible = tracker.inView(at: Date().addingTimeInterval(Double(step))).count }
    let perCall = (ContinuousClock.now - start) / 5
    print("LIVE tracker: parsed \(tles.count) element sets, usable \(tracker.constellationSize), setup \(setupTime), inView() \(perCall) per call, \(visible) above the horizon")
    #expect(tracker.constellationSize > 1000)
}

/// Opt-in DRY RUN against the real router: reads the client list over the LAN and builds a pause request in
/// memory for every listed device. Nothing is sent anywhere. STARPULSE_LIVE_NET=<router host>
@Test(.enabled(if: liveRouterHost != nil))
func livePauseRequestDryRunNeverSends() async throws {
    let host = try #require(liveRouterHost)
    let router = try #require(RouterAPI(host: host))
    let existing = try DevicePause.rawClientConfigs(configResponse: try await router.rawConfigResponse())
    let clients = try await router.clients().filter { $0.role == .client && $0.clientId != nil }
    var built = 0
    for client in clients {
        let pause = try DevicePause.request(targetId: "Router-dryrun", existing: existing, clientId: client.clientId!, macAddress: client.mac, paused: true)
        let resume = try DevicePause.request(targetId: "Router-dryrun", existing: existing, clientId: client.clientId!, macAddress: client.mac, paused: false)
        #expect(!pause.isEmpty && !resume.isEmpty)
        built += 1
    }
    print("LIVE pause dry run: router holds \(existing.count) client entries, built pause and resume requests for \(built) live devices, sent none")
    #expect(built == clients.count)
}
