import StarPulseCore
import SwiftUI

struct RulesTab: View {
    var store: TelemetryStore
    var account: AccountStore
    @State private var editing: DeviceRule?
    @State private var creating = false
    @State private var showGuide = false

    private var rules: RulesController { store.rules }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Rules", systemImage: "calendar.badge.clock").font(Theme.ui(15, .bold)).foregroundStyle(Theme.ink)
                    Text("Manage data limits, schedules and timers across the devices on your network.")
                        .font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
                Button { creating = true } label: { Label("New rule…", systemImage: "plus") }
                    .buttonStyle(.appPrimary)
                    .help("Create a schedule, data limit or timer")
            }
            if !account.isConnected {
                Text("Sign in to your Starlink account so rules can pause devices on their own. Until then they only report.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.warm)
            }
            HStack {
                Image(systemName: "shield.lefthalf.filled").foregroundStyle(Theme.inkSecondary)
                Text(currentDnsText).font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
                Spacer()
                Button { showGuide = true } label: { Label("Protect devices away from home…", systemImage: "shield.lefthalf.filled") }.buttonStyle(.appCompact)
                    .help("Set up DNSBunker or dnsforge on iPhone, Mac, Android or a browser")
            }
            if let note = rules.dnsNote { Text(note).font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary) }
            if let error = rules.lastError { Text(error).font(Theme.ui(11)).foregroundStyle(Theme.critical) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10)], spacing: 10) {
                ForEach(rules.rules) { rule in
                    RuleCard(rule: rule, evaluation: rules.evaluations[rule.id], usageNote: usageNote(rule),
                             edit: { editing = rule }, restart: { rules.restartTimer(rule) }, delete: { rules.delete(rule) })
                }
                Button { creating = true } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "plus").font(.title3).frame(width: 34, height: 34).overlay(Circle().stroke(Theme.hairline))
                        Text("Create a rule").font(Theme.ui(13, .semibold)).foregroundStyle(Theme.ink)
                        Text("Group devices and set their limits").font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Create a schedule, data limit or timer")
            }
            Text("Rules act only while StarPulse is open. Data is counted from what this Mac measures on the router, so time with the app closed is not counted.")
                .font(Theme.ui(10)).foregroundStyle(Theme.inkSecondary)
        }
        .sheet(isPresented: $creating) { RuleEditor(store: store, original: nil) { rules.upsert($0) } }
        .sheet(isPresented: $showGuide) { DeviceDnsGuide() }
        .sheet(item: $editing) { rule in RuleEditor(store: store, original: rule) { rules.upsert($0) } }
    }

    private var currentDnsText: String {
        guard let servers = store.routerConfig?.nameservers else { return "Network DNS: reading the router…" }
        if servers.isEmpty { return "Network DNS: Starlink's default resolvers" }
        let name = DnsPreset.matching(servers)?.name ?? "custom (\(servers.joined(separator: ", ")))"
        return "Network DNS: \(name) · home default \(rules.file.dnsBase.name)"
    }

    private func usageNote(_ rule: DeviceRule) -> String? {
        guard case let .dataLimit(_, period, _) = rule.kind else { return nil }
        let interval = RuleEngine.periodInterval(period, containing: Date(), calendar: .current)
        let total = rule.devices.reduce(Int64(0)) { $0 + rules.file.usage.bytes(clientId: $1, from: interval.start, to: Date()) }
        return "\(rule.devices.count) device\(rule.devices.count == 1 ? "" : "s") · \(gigabytes(total)) in total"
    }
}

func gigabytes(_ bytes: Int64) -> String {
    let gb = Double(bytes) / 1e9
    return gb >= 10 ? String(format: "%.0f GB", gb) : (gb >= 0.1 ? String(format: "%.2f GB", gb) : String(format: "%.0f MB", Double(bytes) / 1e6))
}

private func relative(_ date: Date?) -> String? {
    guard let date else { return nil }
    let seconds = date.timeIntervalSinceNow
    guard seconds > 0 else { return nil }
    if seconds < 3600 { return "\(Int((seconds / 60).rounded(.up))) min" }
    if seconds < 86_400 { let h = Int((seconds / 3600).rounded()); return "\(h) hour\(h == 1 ? "" : "s")" }
    let d = Int((seconds / 86_400).rounded()); return "\(d) day\(d == 1 ? "" : "s")"
}

struct RuleCard: View {
    var rule: DeviceRule
    @State private var showActions = false
    var evaluation: RuleEvaluation?
    var usageNote: String?
    var edit: () -> Void
    var restart: () -> Void
    var delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon).frame(width: 30, height: 30).background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(Theme.ink)
                VStack(alignment: .leading, spacing: 1) {
                    Text(rule.name).font(Theme.ui(14, .bold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(rule.kind.isDns ? "Whole network" : (usageNote ?? "\(rule.devices.count) device\(rule.devices.count == 1 ? "" : "s")")).font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
                }
                Spacer()
                Button { showActions = true } label: {
                    Image(systemName: "ellipsis").frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Theme.inkSecondary)
                .help("Edit, restart or delete this rule").accessibilityLabel("Rule actions")
                .popover(isPresented: $showActions, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Edit…") { showActions = false; edit() }.frame(maxWidth: .infinity, alignment: .leading)
                        if case .timer = rule.kind { Button("Restart timer") { showActions = false; restart() } }
                        Button("Delete") { showActions = false; delete() }.buttonStyle(.appDestructive)
                    }
                    .buttonStyle(.appSecondary)
                    .padding(10)
                    .frame(width: 170)
                }
            }
            content
            HStack {
                Circle().fill(statusColor).frame(width: 6, height: 6)
                Text(statusText).font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
                Spacer()
                if let detail = rightText { Text(detail).font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary) }
            }
            if !rule.autoPause { Text("Reports only; does not pause devices.").font(Theme.ui(10)).foregroundStyle(Theme.warm) }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
    }

    private var icon: String {
        switch rule.kind { case .schedule: "calendar.badge.clock"; case .dataLimit: "gauge.with.dots.needle.33percent"; case .timer: "timer"; case .dnsProfile: "shield.lefthalf.filled" }
    }

    @ViewBuilder private var content: some View {
        switch rule.kind {
        case let .schedule(weekdays, start, end):
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ONLINE").font(Theme.ui(10, .semibold)).foregroundStyle(Theme.inkSecondary)
                    Text(dayList(weekdays)).font(Theme.ui(13)).foregroundStyle(Theme.ink)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("HOURS").font(Theme.ui(10, .semibold)).foregroundStyle(Theme.inkSecondary)
                    Text("\(clock(start)) – \(clock(end))").font(Theme.ui(13)).foregroundStyle(Theme.ink)
                }
            }
        case let .dataLimit(bytes, period, shared):
            let used = evaluation?.usedBytes ?? 0
            HStack(alignment: .firstTextBaseline) {
                Text(gigabytes(used)).font(Theme.ui(22, .bold)).foregroundStyle(Theme.ink)
                Spacer()
                Text("Limit: \(gigabytes(bytes)) \(shared ? "shared" : "each") per \(period.rawValue)").font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
            }
            ProgressView(value: min(1, Double(used) / Double(max(bytes, 1)))).tint(used >= bytes ? Theme.critical : Theme.down)
        case let .timer(duration, _):
            let left = evaluation?.remaining ?? duration
            HStack(alignment: .firstTextBaseline) {
                Text(Format.duration(left)).font(Theme.ui(22, .bold)).foregroundStyle(Theme.ink)
                Spacer()
                Text("of \(Format.duration(duration))").font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
            }
            ProgressView(value: left / max(duration, 1)).tint(Theme.accent)
        case let .dnsProfile(preset, weekdays, start, end):
            VStack(alignment: .leading, spacing: 4) {
                Text(preset.name).font(Theme.ui(16, .bold)).foregroundStyle(Theme.ink)
                Text(preset.blocks).font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
                Text(weekdays.count == 7 && start == end ? "Always, whole network" : "\(dayList(weekdays)) · \(clock(start)) – \(clock(end)) · whole network")
                    .font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
            }
        }
    }

    private var statusText: String {
        guard let evaluation else { return "Checking…" }
        switch rule.kind {
        case .schedule: return evaluation.isOpen ? "Active" : (evaluation.notScheduledToday ? "Not scheduled today" : "Paused")
        case .dataLimit: return evaluation.held.isEmpty ? "Active" : "Limit reached"
        case .timer: return evaluation.isOpen ? "Active" : "Time is up"
        case .dnsProfile: return evaluation.isOpen ? "In use now" : "Not in use"
        }
    }

    private var statusColor: Color {
        if case .dnsProfile = rule.kind { return (evaluation?.isOpen ?? false) ? Theme.good : Theme.inkMuted }
        return (evaluation?.held.isEmpty ?? true) ? Theme.good : Theme.inkMuted
    }

    private var rightText: String? {
        guard let evaluation, let when = relative(evaluation.nextChange) else { return nil }
        switch rule.kind {
        case .schedule: return evaluation.isOpen ? "Closes in \(when)" : "Resumes in \(when)"
        case .dataLimit: return "Resets in \(when)"
        case .timer: return nil
        case .dnsProfile: return evaluation.isOpen ? "Ends in \(when)" : "Starts in \(when)"
        }
    }

    private func clock(_ minutes: Int) -> String {
        Calendar.current.date(bySettingHour: minutes / 60 % 24, minute: minutes % 60, second: 0, of: Date())?.formatted(date: .omitted, time: .shortened) ?? "--"
    }

    private func dayList(_ days: Set<Int>) -> String {
        if days == [2, 3, 4, 5, 6] { return "Mon–Fri" }
        if days == [1, 7] { return "Sat–Sun" }
        if days.count == 7 { return "Every day" }
        let symbols = Calendar.current.shortWeekdaySymbols
        return days.sorted { ($0 + 5) % 7 < ($1 + 5) % 7 }.map { symbols[$0 - 1] }.joined(separator: ", ")
    }
}

struct RuleEditor: View {
    enum KindChoice: String, CaseIterable { case schedule = "Schedule", dataLimit = "Data limit", timer = "Timer", dns = "DNS filter" }

    var store: TelemetryStore
    var original: DeviceRule?
    var save: (DeviceRule) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var kind = KindChoice.schedule
    @State private var devices = Set<UInt32>()
    @State private var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    @State private var start = Calendar.current.date(bySettingHour: 16, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var end = Calendar.current.date(bySettingHour: 21, minute: 0, second: 0, of: Date()) ?? Date()
    @State private var limitGB = 8.0
    @State private var period = DeviceRule.Period.day
    @State private var shared = false
    @State private var minutes = 60
    @State private var autoPause = true
    @State private var preset = DnsPreset.dnsforgeClean
    @State private var always = false

    private var candidates: [WifiClient] {
        store.clients.filter { $0.clientId != nil && !store.localAddresses.contains($0.ip) }.sorted { $0.displayName < $1.displayName }
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: original == nil ? "New rule" : "Edit rule", subtitle: "Schedules, data limits, timers and DNS filters for your network.") { dismiss() }
                .padding([.horizontal, .top], 20)
            Form {
                TextField("Name", text: $name, prompt: Text("Kids' tablets"))
                AppSegmented(selection: $kind, options: KindChoice.allCases.map { ($0, $0.rawValue) }, help: "Kind of rule")
                if kind != .dns {
                Section("Devices") {
                    if candidates.isEmpty { Text("No devices are listed by the router right now.").foregroundStyle(Theme.inkSecondary) }
                    ForEach(candidates) { client in
                        Toggle(client.displayName, isOn: Binding(
                            get: { devices.contains(client.clientId!) },
                            set: { on in if on { devices.insert(client.clientId!) } else { devices.remove(client.clientId!) } }))
                    }
                    Text("This Mac is not listed: it cannot pause itself.").font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
                }
                }
                switch kind {
                case .schedule:
                    Section("Online") {
                        HStack {
                            ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                                Toggle(Calendar.current.veryShortWeekdaySymbols[day - 1], isOn: Binding(
                                    get: { weekdays.contains(day) },
                                    set: { on in if on { weekdays.insert(day) } else { weekdays.remove(day) } }))
                                    .toggleStyle(.button)
                            }
                        }
                        DatePicker("From", selection: $start, displayedComponents: .hourAndMinute)
                        DatePicker("Until", selection: $end, displayedComponents: .hourAndMinute)
                        Text("Devices are online inside these hours and paused outside them.").font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
                    }
                case .dataLimit:
                    Section("Limit") {
                        Stepper(value: $limitGB, in: 0.5...2000, step: limitGB < 10 ? 0.5 : 5) { Text(String(format: "%.1f GB", limitGB)) }
                        LabeledContent("Per") { AppSegmented(selection: $period, options: DeviceRule.Period.allCases.map { ($0, $0.rawValue.capitalized) }).frame(width: 240) }
                        Toggle("Share one allowance across the devices", isOn: $shared)
                    }
                case .dns:
                    Section("Filtering service") {
                        AppSegmented(selection: $preset, options: DnsPreset.allCases.filter { $0 != .cloudflareFamilies }
                            .map { ($0, $0.name.replacingOccurrences(of: "dnsforge ", with: "")) }, help: "Filtering service")
                        Text(preset.blocks).font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
                        Toggle("Always", isOn: $always)
                        if !always {
                            HStack {
                                ForEach([2, 3, 4, 5, 6, 7, 1], id: \.self) { day in
                                    Toggle(Calendar.current.veryShortWeekdaySymbols[day - 1], isOn: Binding(
                                        get: { weekdays.contains(day) },
                                        set: { on in if on { weekdays.insert(day) } else { weekdays.remove(day) } }))
                                        .toggleStyle(.button)
                                }
                            }
                            DatePicker("From", selection: $start, displayedComponents: .hourAndMinute)
                            DatePicker("Until", selection: $end, displayedComponents: .hourAndMinute)
                        }
                        Text("Applies to every device on the network. Outside these hours the network goes back to Cloudflare for Families. Blocks whole sites by name, including HTTPS sites; it cannot see pages inside a site.")
                            .font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
                    }
                case .timer:
                    Section("Time online") {
                        AppSegmented(selection: $minutes, options: [15, 30, 60, 120, 240, 480, 1440].map { ($0, Format.duration(TimeInterval($0 * 60))) },
                                      help: "How long the devices stay online")
                        Text("Starts when you save; restart it from the rule's menu.").font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
                    }
                }
                Toggle(kind == .dns ? "Switch the network DNS automatically" : "Pause devices automatically", isOn: $autoPause)
                    .help("Off: the rule only shows its state and never changes the router")
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(original == nil ? "Create" : "Save") { commit() }
                    .buttonStyle(.appPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled((kind != .dns && devices.isEmpty) || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || ((kind == .schedule || (kind == .dns && !always)) && weekdays.isEmpty))
            }
            .padding(14)
        }
        .appChrome()
        .frame(width: 480, height: 640)
        .background(Theme.page)
        .onAppear(perform: load)
    }

    private func minutesOfDay(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date); return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    private func load() {
        guard let original else { return }
        name = original.name; devices = Set(original.devices); autoPause = original.autoPause
        switch original.kind {
        case let .schedule(days, s, e):
            kind = .schedule; weekdays = days
            start = Calendar.current.date(bySettingHour: s / 60, minute: s % 60, second: 0, of: Date()) ?? start
            end = Calendar.current.date(bySettingHour: e / 60 % 24, minute: e % 60, second: 0, of: Date()) ?? end
        case let .dataLimit(bytes, p, sh): kind = .dataLimit; limitGB = Double(bytes) / 1e9; period = p; shared = sh
        case let .timer(duration, _): kind = .timer; minutes = Int(duration / 60)
        case let .dnsProfile(p, days, s, e):
            kind = .dns; preset = p; always = days.count == 7 && s == e; weekdays = days
            start = Calendar.current.date(bySettingHour: s / 60, minute: s % 60, second: 0, of: Date()) ?? start
            end = Calendar.current.date(bySettingHour: e / 60 % 24, minute: e % 60, second: 0, of: Date()) ?? end
        }
    }

    private func commit() {
        let ruleKind: DeviceRule.Kind = switch kind {
        case .dns: always ? .dnsProfile(preset: preset, weekdays: Set(1...7), startMinutes: 0, endMinutes: 0)
                          : .dnsProfile(preset: preset, weekdays: weekdays, startMinutes: minutesOfDay(start), endMinutes: minutesOfDay(end))
        case .schedule: .schedule(weekdays: weekdays, startMinutes: minutesOfDay(start), endMinutes: minutesOfDay(end))
        case .dataLimit: .dataLimit(bytes: Int64(limitGB * 1e9), period: period, shared: shared)
        case .timer:
            // Editing other fields keeps a running timer's start; changing the duration restarts it.
            if case let .timer(duration, startedAt)? = original?.kind, Int(duration / 60) == minutes {
                .timer(duration: duration, startedAt: startedAt)
            } else { .timer(duration: TimeInterval(minutes * 60), startedAt: Date()) }
        }
        var rule = original ?? DeviceRule(name: name, devices: [], kind: ruleKind)
        rule.name = name.trimmingCharacters(in: .whitespaces)
        rule.devices = kind == .dns ? [] : devices.sorted()
        rule.kind = ruleKind
        rule.autoPause = autoPause
        save(rule)
        dismiss()
    }
}

/// Per-device setup for DNS filtering services that the router cannot use or that should follow a device away
/// from home. Steps and addresses from dnsbunker.org and dnsforge.de (checked 2026-11-24).
struct DeviceDnsService: Identifiable, Hashable {
    let id: String
    let name: String
    let summary: String
    let appleProfile: URL
    let appleNote: String
    let androidHost: String
    let doh: String
    let guide: URL

    static let all: [DeviceDnsService] = [
        DeviceDnsService(id: "dnsbunker", name: "DNSBunker",
                         summary: "Ads, trackers, phishing and malware. Frankfurt, no account, no query logs. Encrypted DNS only, so it cannot be the Starlink router's DNS.",
                         appleProfile: URL(string: "https://dnsbunker.org/doh.mobileconfig")!, appleNote: "iPhone, iPad and Mac",
                         androidHost: "dnsbunker.org", doh: "https://dnsbunker.org/dns-query", guide: URL(string: "https://dnsbunker.org/#configuration")!),
        DeviceDnsService(id: "dnsforge-normal", name: "dnsforge Normal",
                         summary: "Ads, trackers and malware. Germany, no logging, free.",
                         appleProfile: URL(string: "https://dnsforge.de/dnsforge-doh.mobileconfig")!, appleNote: "iPhone and iPad (dnsforge lists the profile for iOS)",
                         androidHost: "dnsforge.de", doh: "https://dnsforge.de/dns-query", guide: URL(string: "https://dnsforge.de/#clients")!),
        DeviceDnsService(id: "dnsforge-clean", name: "dnsforge Clean",
                         summary: "Normal plus child protection and SafeSearch; its lists include adult content and gambling.",
                         appleProfile: URL(string: "https://dnsforge.de/clean-dnsforge-doh.mobileconfig")!, appleNote: "iPhone and iPad (dnsforge lists the profile for iOS)",
                         androidHost: "clean.dnsforge.de", doh: "https://clean.dnsforge.de/dns-query", guide: URL(string: "https://dnsforge.de/#clients")!),
        DeviceDnsService(id: "dnsforge-hard", name: "dnsforge Hard",
                         summary: "Strict lists with no exceptions; some features of sites such as Facebook may stop working.",
                         appleProfile: URL(string: "https://dnsforge.de/hard-dnsforge-doh.mobileconfig")!, appleNote: "iPhone and iPad (dnsforge lists the profile for iOS)",
                         androidHost: "hard.dnsforge.de", doh: "https://hard.dnsforge.de/dns-query", guide: URL(string: "https://dnsforge.de/#clients")!),
    ]
}

struct DeviceDnsGuide: View {
    @Environment(\.dismiss) private var dismiss
    @State private var service = DeviceDnsService.all[0]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(title: "Protect devices away from home",
                        subtitle: "Set a filtering DNS on each phone, tablet or computer, so it keeps working outside your Starlink network.") { dismiss() }
            AppSegmented(selection: $service, options: DeviceDnsService.all.map { ($0, $0.name) }, help: "Choose the filtering service")
            Text(service.summary).font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
            platform("apple.logo", service.appleNote,
                     "Download the profile, open it, then install it in Settings › Profile downloaded (Mac: System Settings › General › Device Management). Switch airplane mode on and off once.") {
                Button { NSWorkspace.shared.open(service.appleProfile) } label: { Label("Download profile", systemImage: "arrow.down.circle") }
                    .buttonStyle(.appPrimary).help("Open the configuration profile from the provider's site")
            }
            platform("smartphone", "Android 9 or newer", "Settings › Network & internet › Private DNS › Private DNS provider hostname.") {
                CopyField(value: service.androidHost)
            }
            platform("globe", "Firefox, Chrome, Edge", "Settings › Secure DNS › custom provider. Protects that browser only.") {
                CopyField(value: service.doh)
            }
            Text("To undo, remove the profile or set Private DNS back to Automatic. Hotel and train Wi-Fi login pages may need it off for a moment.")
                .font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { NSWorkspace.shared.open(service.guide) } label: { Label("Full guide on \(service.guide.host ?? "the provider's site")", systemImage: "arrow.up.right.square") }
                    .help("Open the provider's own setup guide")
                Spacer()
                Button("Done") { dismiss() }.buttonStyle(.appPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 540)
        .background(Theme.page)
        .appChrome()
    }

    private func platform<Action: View>(_ symbol: String, _ title: String, _ text: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16)).frame(width: 34, height: 34)
                .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(Theme.ink)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Theme.ui(14, .semibold)).foregroundStyle(Theme.ink)
                Text(text).font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary).fixedSize(horizontal: false, vertical: true)
                action()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
    }
}
