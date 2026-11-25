import Foundation
import Observation
import StarPulseCore

enum Readout: String, CaseIterable, Identifiable {
    case status, latency, pingSuccess, throughput, power, contentFilter
    var id: String { rawValue }
    var label: String {
        switch self {
        case .status: "Status"
        case .latency: "Latency"
        case .pingSuccess: "Ping success"
        case .throughput: "Throughput"
        case .power: "Power draw"
        case .contentFilter: "Content filter"
        }
    }
}

extension Readout {
    static func parse(_ raw: String) -> [Readout] {
        let parsed = raw.split(separator: ",").compactMap { Readout(rawValue: String($0)) }
        return parsed.isEmpty ? [.latency] : parsed
    }
    static func encode(_ readouts: [Readout]) -> String { readouts.map(\.rawValue).joined(separator: ",") }
}

enum Connection: Equatable {
    case connecting, live
    case offline(String)
}

enum SettingsKey {
    static let host = "dishHost"
    static let routerHost = "routerHost"
    static let readouts = "menuBarReadouts"
    static let appearance = "appearance"
    static let openAtLaunch = "openDashboardAtLaunch"
    static let rateUnit = "rateUnit"
    static let throughputAxisMax = "throughputAxisMaxMbps"
    static let notifyOutages = "notifyOutages"
    static let notifyPacketLoss = "notifyPacketLoss"
    static let notifyLatency = "notifyLatency"

    static var savedRateUnit: RateUnit { RateUnit(rawValue: UserDefaults.standard.string(forKey: rateUnit) ?? "") ?? .automatic }
}

@MainActor @Observable
final class TelemetryStore {
    var status: DishStatus?
    var samples: [TelemetrySample] = []
    var events: [DishEvent] = []
    var allClients: [WifiClient] = []
    var clientHistory = ClientHistory()
    let localAddresses = NetworkGateway.localAddresses()
    var clients: [WifiClient] { allClients.filter { $0.role == .client } }
    var nodes: [WifiClient] { allClients.filter { $0.role != .client } }
    var routerError: String?
    var routerHost = ""
    var obstructionMap: ObstructionMap?
    /// Hourly frames of the obstruction map for the time-lapse (bounded file, see SnapshotStore).
    var snapshots: [ObstructionSnapshot] = SnapshotStore.standard.load()
    /// Daily peak and average throughput, kept for 62 days (see ThroughputLedger).
    var throughputLedger = ThroughputLedgerStore.standard.load()
    private var ledgerSavedAt = Date.distantPast
    private var outageWatch = ConditionWatch(threshold: 30)
    private var lossWatch = ConditionWatch(threshold: 60)
    private var latencyWatch = ConditionWatch(threshold: 60)
    var dishConfig: DishConfig?
    var routerConfig: RouterConfig?
    var routerStatus: RouterStatus?
    var latencyHistory = LatencyHistory()
    let speedTest = SpeedTestModel()
    let satellites = SatelliteStore()
    let rules = RulesController()
    /// Set by the app at launch; rules write through the Starlink account.
    var account: AccountStore?
    /// Stops polling the dish and router so the screen holds still; resuming catches up at once.
    var isPaused = false
    var connection: Connection = .connecting
    /// Likely reason the dish does not answer; set only while it does not.
    var dishDiagnosis: DishDiagnosis?
    private var task: Task<Void, Never>?
    private var routerTask: Task<Void, Never>?

    var latestPower: Float? { samples.last(where: { $0.powerW > 0 })?.powerW }

    /// Share of pings answered over the last 60 samples.
    var pingSuccessPercent: Double? {
        let recent = samples.suffix(60)
        guard !recent.isEmpty else { return nil }
        return 100 * (1 - Double(recent.map(\.dropRate).reduce(0, +)) / Double(recent.count))
    }

    var stats: TelemetryStats { TelemetryStats.compute(samples: samples, events: events, now: Date()) }
    var alignment: AlignmentReading? { status.map(AlignmentMath.compute) }

    /// A drop replaces every readout, so the menu bar never shows numbers from before it.
    func menuBarText(readouts: [Readout]) -> String {
        if case .offline = connection { return "Offline" }
        if status != nil, isOutage { return "Outage" }
        return readouts.map { menuBarText($0) }.joined(separator: "  ")
    }

    var isOutage: Bool { (status?.dropRate ?? 0) >= 1 }

    func menuBarText(_ readout: Readout) -> String {
        guard let status else { return "--" }
        switch readout {
        case .status:
            if case .offline = connection { return "Offline" }
            return isOutage ? "Outage" : "Online"
        case .contentFilter:
            guard let servers = routerConfig?.nameservers else { return "Filter --" }
            return ContentFilter.current(servers).map { "Filter \($0.shortTitle)" } ?? "Custom DNS"
        case .latency: return status.latencyMs > 0 ? "\(Int(status.latencyMs.rounded())) ms" : "-- ms"
        case .pingSuccess: return pingSuccessPercent.map { "\(Int($0.rounded()))%" } ?? "--"
        case .throughput: return "↓\(Format.menuBarRate(status.downlinkBps, unit: SettingsKey.savedRateUnit))"
        case .power: return latestPower.map { "\(Int($0.rounded())) W" } ?? "-- W"
        }
    }

    func start() {
        task?.cancel()
        routerTask?.cancel()
        // The router refreshes its byte counters about once a second on its own clock; polling
        // four times a second finds each refresh, which is what makes per-device rates exact.
        routerTask = Task { [weak self] in
            while !Task.isCancelled {
                if self?.isPaused == false { await self?.pollClients() }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        task = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                if self?.isPaused == false {
                    await self?.refresh(includeHistory: tick % 5 == 0, includeMap: tick % 30 == 0)
                    await self?.refreshRouter(includeConfig: tick % 60 == 0)
                    if tick % 30 == 5, let self, let account = self.account {
                        await self.rules.tick(clients: self.allClients, localAddresses: self.localAddresses, account: account, routerHost: self.routerHost)
                    }
                }
                tick += 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func makeSource() -> any DishDataSource { makeDishClient() }

    /// Sets the Starlink app's Content Filtering, then reads the router back: the router, not the write, is the proof.
    func applyContentFilter(_ filter: ContentFilter, account: AccountStore) async throws -> String {
        try await account.setContentFilter(filter, routerHost: routerHost)
        if let preset = filter.preset { rules.adoptHomeDns(preset) }
        try? await Task.sleep(for: .seconds(3))
        if let api = RouterAPI(host: routerHost), let config = try? await api.config() {
            #if DEBUG
            routerConfig = Anonymizer.config(config)
            #else
            routerConfig = config
            #endif
        }
        let now = routerConfig.flatMap { ContentFilter.current($0.nameservers) }
        return now == filter ? "\(filter.title) is on." : "Starlink accepted the change; the router has not shown it yet."
    }

    /// Reboot or obstruction-map reset: over the LAN, else through the Starlink account.
    func performMaintenance(_ action: DishMaintenance, account: AccountStore) async throws -> DishMaintenance.Route {
        let dish = makeDishClient()
        let dishId = status?.deviceId ?? ""
        let local: @Sendable () async throws -> Void = { try await dish.perform(action) }
        let viaCloud: @Sendable () async throws -> Void = { try await account.dishMaintenance(action, dishId: dishId) }
        return try await DishMaintenance.run(local: local, cloud: account.isConnected ? viaCloud : nil)
    }

    private var dishHost: String {
        let host = (UserDefaults.standard.string(forKey: SettingsKey.host) ?? "").trimmingCharacters(in: .whitespaces)
        return host.isEmpty ? "192.168.100.1" : host
    }

    private func makeDishClient() -> DishClient {
        let url = URL(string: "http://\(dishHost):9201/SpaceX.API.Device.Device/Handle")
        return DishClient(url: url ?? DishClient.defaultURL)
    }

    /// The setting wins; otherwise the Mac's default gateway, which is the Starlink
    /// router on a typical setup; otherwise Dishylink's factory default.
    private func resolveRouterHost() -> String {
        let configured = (UserDefaults.standard.string(forKey: SettingsKey.routerHost) ?? "").trimmingCharacters(in: .whitespaces)
        return configured.isEmpty ? (NetworkGateway.current() ?? "192.168.1.1") : configured
    }

    private func refreshRouter(includeConfig: Bool) async {
        routerHost = resolveRouterHost()
        guard let api = RouterAPI(host: routerHost) else { return }
        do {
            let status = try await api.status()
            #if DEBUG
            routerStatus = Anonymizer.routerStatus(status)
            #else
            routerStatus = status
            #endif
            if let ms = status.popLatencyMs { latencyHistory.recordRouter(ms, at: Date()) }
            if includeConfig || routerConfig == nil { routerConfig = try? await api.config() }
            #if DEBUG
            routerConfig = Anonymizer.config(routerConfig)
            #endif
            routerError = nil
        } catch {
            routerError = error.localizedDescription
        }
    }

    /// Runs once per dish reading; ConditionWatch keeps each notification to one per episode.
    private func watchLink() {
        let now = Date(), recent = LinkCheck.recent(samples)
        if let event = outageWatch.update(isActive: isOutage, at: now) { LinkNotifier.shared.post(.outage, event, quality: recent) }
        if let event = lossWatch.update(isActive: LinkCheck.isLossy(recent), at: now) { LinkNotifier.shared.post(.packetLoss, event, quality: recent) }
        if let event = latencyWatch.update(isActive: LinkCheck.isSlow(recent), at: now) { LinkNotifier.shared.post(.latency, event, quality: recent) }
    }

    private func pollClients() async {
        guard let api = RouterAPI(host: routerHost.isEmpty ? resolveRouterHost() : routerHost) else { return }
        do {
            allClients = try await api.clients()
            #if DEBUG
            allClients = Anonymizer.clients(allClients)
            #endif
            let now = Date()
            rules.addUsage(clientHistory.record(allClients, at: now), at: now)
        } catch {
            routerError = error.localizedDescription
        }
    }

    private func refresh(includeHistory: Bool, includeMap: Bool) async {
        let source = makeSource()
        do {
            status = try await source.status()
            #if DEBUG
            status = Anonymizer.status(status)
            #endif
            watchLink()
            if includeHistory || samples.isEmpty {
                let history = try await source.history()
                samples = history.samples
                throughputLedger.ingest(history.samples)
                // At most one small write every five minutes.
                if Date().timeIntervalSince(ledgerSavedAt) > 300 {
                    ThroughputLedgerStore.standard.save(throughputLedger)
                    ledgerSavedAt = Date()
                }
                latencyHistory.ingestDish(history)
                events = history.events.sorted { $0.startTimestampNs > $1.startTimestampNs }
            }
            if includeMap || obstructionMap == nil {
                obstructionMap = try? await source.obstructionMap()
                if let map = obstructionMap { snapshots = SnapshotStore.standard.record(map, at: Date(), into: snapshots) }
            }
            if includeMap || dishConfig == nil { dishConfig = try? await source.config() }
            connection = .live
            dishDiagnosis = nil
        } catch {
            connection = .offline(error.localizedDescription)
            let host = dishHost
            dishDiagnosis = DishDiagnosis.diagnose(dishHost: host, interfaces: NetworkGateway.interfaces(),
                                                   routeInterface: NetworkGateway.routeInterface(toward: host),
                                                   starlinkRouterAnswers: routerStatus != nil && routerError == nil)
        }
    }
}
