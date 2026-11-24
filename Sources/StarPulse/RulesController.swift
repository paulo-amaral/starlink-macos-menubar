import Foundation
import Observation
import StarPulseCore

/// Keeps the router in line with the rules while StarPulse runs: evaluates every rule, works out which
/// devices to pause or let back on, and writes one change at a time through the Starlink account.
@MainActor @Observable
final class RulesController {
    private(set) var file = RulesController.initialFile()

    private static func initialFile() -> RulesFile {
        #if DEBUG
        if Anonymizer.isOn {
            // Report-only sample rules for screenshots; the real rules file is never read or written in this mode.
            var sample = RulesFile()
            sample.rules = [
                DeviceRule(name: "Kids' tablets (school days)", devices: [1, 2], kind: .schedule(weekdays: [2, 3, 4, 5, 6], startMinutes: 16 * 60, endMinutes: 21 * 60), autoPause: false),
                DeviceRule(name: "Streaming cap", devices: [3], kind: .dataLimit(bytes: 8_000_000_000, period: .day, shared: false), autoPause: false),
                DeviceRule(name: "Game console hour", devices: [4], kind: .timer(duration: 3600, startedAt: Date().addingTimeInterval(-900)), autoPause: false),
                DeviceRule(name: "Homework hours", devices: [], kind: .dnsProfile(preset: .dnsforgeClean, weekdays: [2, 3, 4, 5, 6], startMinutes: 15 * 60, endMinutes: 20 * 60), autoPause: false),
            ]
            return sample
        }
        #endif
        return RulesFile.load()
    }

    private var persists: Bool {
        #if DEBUG
        return !Anonymizer.isOn
        #else
        return true
        #endif
    }
    private(set) var evaluations: [UUID: RuleEvaluation] = [:]
    var lastError: String?
    /// Plain-language state of the network DNS, shown in the Rules tab.
    var dnsNote: String?
    private var nextDnsAttempt = Date.distantPast
    private var busy = false
    private var lastUsageSave = Date.distantPast

    var rules: [DeviceRule] { file.rules }

    private func saveIfAllowed() { if persists { file.save() } }

    func upsert(_ rule: DeviceRule) {
        if let index = file.rules.firstIndex(where: { $0.id == rule.id }) { file.rules[index] = rule } else { file.rules.append(rule) }
        saveIfAllowed()
    }

    func delete(_ rule: DeviceRule) {
        file.rules.removeAll { $0.id == rule.id }
        saveIfAllowed()
    }

    func restartTimer(_ rule: DeviceRule) {
        guard case let .timer(duration, _) = rule.kind else { return }
        var updated = rule
        updated.kind = .timer(duration: duration, startedAt: Date())
        upsert(updated)
    }

    func pausedByStarPulse(_ clientId: UInt32?) -> Bool { clientId.map { file.pausedByRules.contains($0) } ?? false }

    /// Bytes measured by the router poll, counted per local day.
    func addUsage(_ moved: [UInt32: UInt64], at date: Date) {
        guard !moved.isEmpty else { return }
        for (id, bytes) in moved { file.usage.add(bytes, clientId: id, at: date) }
        if date.timeIntervalSince(lastUsageSave) > 60 {
            file.usage.prune(now: date)
            saveIfAllowed()
            lastUsageSave = date
        }
    }

    /// Keeps the network DNS on the preset the rules ask for. Acts only when the router's current list is a
    /// known preset (a DNS set by hand in the Starlink app is left alone), and without DNS rules only undoes
    /// a change StarPulse itself made. Every write is read back from the router to confirm it.
    private func enforceDns(account: AccountStore, routerHost: String, now: Date) async {
        let hasDnsRules = file.rules.contains { $0.kind.isDns }
        guard hasDnsRules || file.dnsSetByStarPulse != nil, !busy, now >= nextDnsAttempt,
              let router = RouterAPI(host: routerHost), let current = try? await router.config().nameservers else { return }
        let currentPreset = DnsPreset.matching(current)
        let desired = DnsPlanner.desired(rules: file.rules, base: file.dnsBase, now: now)
        guard currentPreset != desired else {
            dnsNote = "Network DNS: \(desired.name)"
            if !hasDnsRules, desired == file.dnsBase { file.dnsSetByStarPulse = nil; saveIfAllowed() }
            return
        }
        guard DnsPlanner.mayManage(current: current) else {
            dnsNote = "Your router uses DNS servers set outside StarPulse (\(current.joined(separator: ", "))). DNS rules leave them alone."
            return
        }
        if !hasDnsRules, currentPreset != file.dnsSetByStarPulse {
            return // someone else picked this preset; nothing of ours to undo
        }
        guard account.isConnected else { dnsNote = "Sign in to your Starlink account so DNS rules can switch the network DNS."; return }
        busy = true
        defer { busy = false }
        do {
            try await account.setNameservers(desired.servers, routerHost: routerHost)
            // Read back: the router, not the write, is the proof.
            try? await Task.sleep(for: .seconds(3))
            let after = (try? await router.config().nameservers).flatMap(DnsPreset.matching)
            file.dnsSetByStarPulse = desired == file.dnsBase ? nil : desired
            saveIfAllowed()
            dnsNote = after == desired ? "Network DNS switched to \(desired.name)." : "Starlink accepted the DNS change; the router has not shown it yet."
            nextDnsAttempt = now.addingTimeInterval(120)
        } catch {
            dnsNote = "DNS change failed: \(error.localizedDescription)"
            nextDnsAttempt = now.addingTimeInterval(300)
        }
    }

    /// Called about every 30 seconds by the telemetry loop.
    func tick(clients: [WifiClient], localAddresses: Set<String>, account: AccountStore, routerHost: String) async {
        let now = Date()
        var held = Set<UInt32>()
        for rule in file.rules {
            let evaluation = RuleEngine.evaluate(rule, now: now) { [file] id, from, to in file.usage.bytes(clientId: id, from: from, to: to) }
            evaluations[rule.id] = evaluation
            if rule.autoPause { held.formUnion(evaluation.held) }
        }
        guard persists else { return } // screenshot mode: evaluate only, never write to the router
        await enforceDns(account: account, routerHost: routerHost, now: now)
        guard !busy, account.isConnected, !file.rules.isEmpty || !file.pausedByRules.isEmpty else { return }
        let listed = clients.filter { $0.clientId != nil }
        let present = Set(listed.compactMap(\.clientId))
        let blocked = Set(listed.filter(\.blocked).compactMap(\.clientId))
        let protected = Set(listed.filter { localAddresses.contains($0.ip) }.compactMap(\.clientId))
        let before = file
        let actions = RulePlanner.plan(held: held, blocked: blocked, present: present, protected: protected, now: now, file: &file)
        if file != before { saveIfAllowed() }
        guard !actions.isEmpty else { return }
        busy = true
        defer { busy = false }
        for action in actions {
            let (id, pause) = switch action { case .pause(let id): (id, true); case .resume(let id): (id, false) }
            guard let client = listed.first(where: { $0.clientId == id }) else { continue }
            do {
                try await account.setPaused(pause, client: client, routerHost: routerHost)
                if pause { file.recordPause(id, at: now) } else { file.recordResume(id) }
                saveIfAllowed()
                lastError = nil
            } catch {
                // The next tick tries again; one failed device does not stop the others.
                lastError = "\(client.displayName): \(error.localizedDescription)"
            }
        }
    }
}
