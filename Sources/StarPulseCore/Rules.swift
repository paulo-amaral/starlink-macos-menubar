import Foundation

/// A rule over one or more devices, keyed by the router's clientId (MACs are masked on this firmware).
/// Modelled on Dishylink's Rules: schedules, data limits and timers that pause devices and let them back on.
public struct DeviceRule: Codable, Sendable, Equatable, Identifiable {
    public enum Period: String, Codable, Sendable, CaseIterable { case day, week, month }

    public enum Kind: Codable, Sendable, Equatable {
        /// Devices are online inside the window on the chosen weekdays and paused outside it.
        /// Weekdays follow Calendar: 1 is Sunday, 7 is Saturday. An end before the start runs past midnight.
        case schedule(weekdays: Set<Int>, startMinutes: Int, endMinutes: Int)
        /// Bytes (down plus up) per period, shared by the group or given to each device.
        case dataLimit(bytes: Int64, period: Period, shared: Bool)
        /// Online until `startedAt + duration`, then paused until the rule is restarted or removed.
        case timer(duration: TimeInterval, startedAt: Date)
        /// Switches the whole network's DNS to a filtering service inside the window (every day, 0 to 0, means always).
        case dnsProfile(preset: DnsPreset, weekdays: Set<Int>, startMinutes: Int, endMinutes: Int)
    }

    public var id = UUID()
    public var name: String
    public var devices: [UInt32]
    public var kind: Kind
    /// Off means the rule only reports; it never writes to the router.
    public var autoPause = true

    public init(name: String, devices: [UInt32], kind: Kind, autoPause: Bool = true) {
        self.name = name; self.devices = devices; self.kind = kind; self.autoPause = autoPause
    }
}

public struct RuleEvaluation: Sendable, Equatable {
    /// Devices this rule wants paused right now.
    public var held: Set<UInt32> = []
    /// Whether the rule currently lets its devices online.
    public var isOpen = true
    /// Next moment the answer changes: window closes or opens, the limit resets, the timer ends.
    public var nextChange: Date?
    /// Data limits: bytes used in the period (the group total when shared, else the heaviest device).
    public var usedBytes: Int64?
    /// Schedules: true when today is not one of the rule's days.
    public var notScheduledToday = false
    /// Timers: time left, zero once it has run out.
    public var remaining: TimeInterval?
}

public enum RuleEngine {
    /// `usage(clientId, from, to)` returns the bytes a device moved in that span.
    public static func evaluate(_ rule: DeviceRule, now: Date, calendar: Calendar = .current,
                                usage: (UInt32, Date, Date) -> Int64) -> RuleEvaluation {
        var result = RuleEvaluation()
        switch rule.kind {
        case let .schedule(weekdays, start, end):
            let (open, next, scheduledToday) = window(weekdays: weekdays, start: start, end: end, now: now, calendar: calendar)
            result.isOpen = open
            result.nextChange = next
            result.notScheduledToday = !scheduledToday
            if !open { result.held = Set(rule.devices) }

        case let .dataLimit(bytes, period, shared):
            let interval = periodInterval(period, containing: now, calendar: calendar)
            result.nextChange = interval.end
            let used = Dictionary(uniqueKeysWithValues: rule.devices.map { ($0, usage($0, interval.start, now)) })
            if shared {
                let total = used.values.reduce(0, +)
                result.usedBytes = total
                if total >= bytes { result.held = Set(rule.devices) }
            } else {
                result.usedBytes = used.values.max() ?? 0
                result.held = Set(used.filter { $0.value >= bytes }.keys)
            }
            result.isOpen = result.held.isEmpty

        case let .dnsProfile(_, weekdays, start, end):
            let (open, next, scheduledToday) = window(weekdays: weekdays, start: start, end: end, now: now, calendar: calendar)
            result.isOpen = open
            result.nextChange = next
            result.notScheduledToday = !scheduledToday
            // Network-wide: it never pauses a device.

        case let .timer(duration, startedAt):
            let ends = startedAt.addingTimeInterval(duration)
            result.remaining = max(0, ends.timeIntervalSince(now))
            result.isOpen = now < ends
            result.nextChange = result.isOpen ? ends : nil
            if !result.isOpen { result.held = Set(rule.devices) }
        }
        return result
    }

    public static func periodInterval(_ period: DeviceRule.Period, containing date: Date, calendar: Calendar) -> DateInterval {
        let component: Calendar.Component = switch period { case .day: .day; case .week: .weekOfYear; case .month: .month }
        return calendar.dateInterval(of: component, for: date) ?? DateInterval(start: date, duration: 86_400)
    }

    /// Whether a weekly window is open now, when it next changes, and whether today is one of its days.
    static func window(weekdays: Set<Int>, start: Int, end: Int, now: Date, calendar: Calendar) -> (open: Bool, next: Date?, today: Bool) {
        let startOfToday = calendar.startOfDay(for: now)
        let today = calendar.component(.weekday, from: now)
        let length = end > start ? end - start : 1440 - start + end
        var nextStart: Date?
        // Look back one day for a window that crosses midnight, and ahead a week for the next one.
        for offset in -1...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfToday),
                  weekdays.contains(calendar.component(.weekday, from: day)),
                  let opens = calendar.date(byAdding: .minute, value: start, to: day),
                  let closes = calendar.date(byAdding: .minute, value: length, to: opens) else { continue }
            if opens <= now, now < closes { return (true, closes, weekdays.contains(today)) }
            if opens > now, nextStart == nil { nextStart = opens }
        }
        return (false, nextStart, weekdays.contains(today))
    }
}

/// Per-device bytes counted while StarPulse runs, by local calendar day. The router keeps no per-day history and
/// its own per-client totals restart when a device reconnects, so data limits count what this Mac has measured.
public struct UsageLedger: Codable, Sendable, Equatable {
    /// clientId -> "yyyy-MM-dd" -> bytes.
    public var days: [String: [String: Int64]] = [:]
    static let keepDays = 40
    public init() {}

    static func key(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    public mutating func add(_ bytes: UInt64, clientId: UInt32, at date: Date, calendar: Calendar = .current) {
        guard bytes > 0 else { return }
        days[String(clientId), default: [:]][Self.key(date, calendar: calendar), default: 0] += Int64(clamping: bytes)
    }

    /// Bytes from `from` to `to`, at day granularity (days are counted whole).
    public func bytes(clientId: UInt32, from: Date, to: Date, calendar: Calendar = .current) -> Int64 {
        guard let perDay = days[String(clientId)] else { return 0 }
        var total: Int64 = 0
        var day = calendar.startOfDay(for: from)
        while day <= to {
            total += perDay[Self.key(day, calendar: calendar)] ?? 0
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return total
    }

    public mutating func prune(now: Date, calendar: Calendar = .current) {
        guard let cutoff = calendar.date(byAdding: .day, value: -Self.keepDays, to: now) else { return }
        let oldest = Self.key(cutoff, calendar: calendar)
        for id in days.keys {
            days[id] = days[id]?.filter { $0.key >= oldest }
            if days[id]?.isEmpty == true { days[id] = nil }
        }
    }
}

/// Everything the rules need to survive a restart, in one small file.
public struct RulesFile: Codable, Sendable, Equatable {
    public var rules: [DeviceRule] = []
    public var usage = UsageLedger()
    /// Devices StarPulse itself paused; only these are ever resumed automatically.
    public var pausedByRules: Set<UInt32> = []
    /// Devices a person resumed by hand while a rule held them; left alone until no rule holds them.
    public var overridden: Set<UInt32> = []
    /// The network's DNS when no DNS rule is active (Cloudflare for Families unless changed).
    public var dnsBase: DnsPreset = .cloudflareFamilies
    /// The preset StarPulse last wrote, so it only ever undoes its own DNS change.
    public var dnsSetByStarPulse: DnsPreset?
    public init() {}

    enum CodingKeys: String, CodingKey { case rules, usage, pausedByRules, overridden, dnsBase, dnsSetByStarPulse }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rules = try c.decodeIfPresent([DeviceRule].self, forKey: .rules) ?? []
        usage = try c.decodeIfPresent(UsageLedger.self, forKey: .usage) ?? UsageLedger()
        pausedByRules = try c.decodeIfPresent(Set<UInt32>.self, forKey: .pausedByRules) ?? []
        overridden = try c.decodeIfPresent(Set<UInt32>.self, forKey: .overridden) ?? []
        dnsBase = try c.decodeIfPresent(DnsPreset.self, forKey: .dnsBase) ?? .cloudflareFamilies
        dnsSetByStarPulse = try c.decodeIfPresent(DnsPreset.self, forKey: .dnsSetByStarPulse)
    }

    public static var standardURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "app.starpulse.mac/rules.json")
    }

    public static func load(from url: URL = standardURL) -> RulesFile {
        guard let data = try? Data(contentsOf: url), let file = try? JSONDecoder().decode(RulesFile.self, from: data) else { return RulesFile() }
        return file
    }

    public func save(to url: URL = standardURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: url, options: .atomic) }
    }
}

/// What to write to the router so it matches the rules, given what it reports live.
public enum RulePlanner {
    public enum Action: Sendable, Equatable { case pause(UInt32), resume(UInt32) }

    /// - held: devices some auto-pausing rule wants paused now.
    /// - blocked: devices the router reports paused right now (only devices it currently lists).
    /// - present: devices the router currently lists.
    /// - protected: devices never to touch (this Mac).
    public static func plan(held: Set<UInt32>, blocked: Set<UInt32>, present: Set<UInt32>, protected: Set<UInt32>,
                            file: inout RulesFile) -> [Action] {
        var actions: [Action] = []
        // A device someone resumed by hand stays resumed until no rule holds it any more.
        file.overridden = file.overridden.intersection(held)
        for id in file.pausedByRules where present.contains(id) && held.contains(id) && !blocked.contains(id) {
            file.overridden.insert(id)
            file.pausedByRules.remove(id)
        }
        for id in held.sorted() where present.contains(id) && !blocked.contains(id) && !protected.contains(id) && !file.overridden.contains(id) {
            actions.append(.pause(id))
        }
        // Only what StarPulse paused is let go; a pause made in the Starlink app is never undone here.
        for id in file.pausedByRules.sorted() where !held.contains(id) && present.contains(id) && blocked.contains(id) {
            actions.append(.resume(id))
        }
        // Released devices that are already free need no write; forget them.
        file.pausedByRules = file.pausedByRules.filter { held.contains($0) || blocked.contains($0) || !present.contains($0) }
        return actions
    }
}
