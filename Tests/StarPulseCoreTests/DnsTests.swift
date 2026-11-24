import Foundation
import Testing
@testable import StarPulseCore

@Test func routerCurrentDnsIsRecognisedAsCloudflareFamilies() {
    // A list as a Starlink router reports it when set to Cloudflare for Families.
    let live = ["1.1.1.3", "1.0.0.3", "2606:4700:4700::1113", "2606:4700:4700::1003"]
    #expect(DnsPreset.matching(live) == .cloudflareFamilies)
    #expect(DnsPreset.matching(live.reversed()) == .cloudflareFamilies)              // order does not matter
    #expect(DnsPreset.matching(["1.1.1.3", "1.0.0.3", "2606:4700:4700:0:0:0:0:1113", "2606:4700:4700::1003"]) == .cloudflareFamilies) // IPv6 spelled out
    #expect(DnsPreset.matching(["8.8.8.8"]) == nil)
    #expect(DnsPlanner.mayManage(current: live) && !DnsPlanner.mayManage(current: ["192.168.1.53"]))
    for preset in DnsPreset.allCases { #expect(preset.servers.count == 4 && preset.servers.allSatisfy(DnsWrite.isAddress)) }
}

@Test func dnsRequestCarriesOnlyTheListAndTheApplyFlag() throws {
    let body = try DnsWrite.request(targetId: "Router-1", nameservers: DnsPreset.dnsforgeClean.servers)
    var servers: [String] = [], apply = false, target = ""
    for field in try ProtoReader.rawFields(body) {
        var r = field.reader
        if field.number == 13 { target = String(decoding: try r.readLengthDelimited(), as: UTF8.self) }
        if field.number == 3001 {
            let wifi = try #require(try DishDecoder.submessage(1, in: try r.readLengthDelimited()))
            for f in try ProtoReader.rawFields(wifi) {
                var fr = f.reader
                switch f.number {
                case 30: servers.append(String(decoding: try fr.readLengthDelimited(), as: UTF8.self))
                case 1054: apply = try fr.readVarint() == 1
                default: Issue.record("unexpected WifiConfig field \(f.number)")
                }
            }
        }
    }
    #expect(target == "Router-1" && apply && servers == DnsPreset.dnsforgeClean.servers)
    #expect(throws: PauseError.self) { try DnsWrite.request(targetId: "Router-1", nameservers: ["not-an-ip"]) }
    #expect(throws: PauseError.self) { try DnsWrite.request(targetId: "Router-1", nameservers: []) }
    #expect(throws: PauseError.self) { try DnsWrite.request(targetId: "Router-1", nameservers: Array(repeating: "1.1.1.1", count: 5)) }
}

@Test func plannerPicksTheOpenDnsRuleElseTheHomeDefault() {
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
    let monday = utc.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 17))!
    let kids = DeviceRule(name: "Kids hours", devices: [], kind: .dnsProfile(preset: .dnsforgeClean, weekdays: [2, 3, 4, 5, 6], startMinutes: 16 * 60, endMinutes: 21 * 60))
    #expect(DnsPlanner.desired(rules: [kids], base: .cloudflareFamilies, now: monday, calendar: utc) == .dnsforgeClean)
    #expect(DnsPlanner.desired(rules: [kids], base: .cloudflareFamilies, now: monday.addingTimeInterval(5 * 3600), calendar: utc) == .cloudflareFamilies)
    let always = DeviceRule(name: "Always", devices: [], kind: .dnsProfile(preset: .quad9, weekdays: Set(1...7), startMinutes: 0, endMinutes: 0))
    #expect(DnsPlanner.desired(rules: [always], base: .cloudflareFamilies, now: monday, calendar: utc) == .quad9)
    var reportOnly = kids; reportOnly.autoPause = false
    #expect(DnsPlanner.desired(rules: [reportOnly], base: .cloudflareFamilies, now: monday, calendar: utc) == .cloudflareFamilies)
    #expect(RuleEngine.evaluate(kids, now: monday, calendar: utc) { _, _, _ in 0 }.held.isEmpty)
}

@Test func olderRulesFilesStillLoad() throws {
    let old = #"{"rules":[],"usage":{"days":{}},"pausedByRules":[],"overridden":[]}"#
    let file = try JSONDecoder().decode(RulesFile.self, from: Data(old.utf8))
    #expect(file.dnsBase == .cloudflareFamilies)
}

// The Starlink app's Content Filtering is Cloudflare DNS on the router (Starlink help center,
// "Content Filtering"); No Filtering is the router's default, an empty list.
@Test func contentFilterMatchesTheStarlinkAppOptions() {
    #expect(ContentFilter.current([]) == ContentFilter.none)
    #expect(ContentFilter.current(["1.1.1.2", "1.0.0.2", "2606:4700:4700::1112", "2606:4700:4700::1002"]) == .malware)
    #expect(ContentFilter.current(["1.1.1.3", "1.0.0.3", "2606:4700:4700::1113", "2606:4700:4700::1003"]) == .malwareAndAdult)
    #expect(ContentFilter.current(["9.9.9.9", "149.112.112.112", "2620:fe::fe", "2620:fe::9"]) == nil) // set elsewhere
    #expect(ContentFilter.malware.preset == .cloudflareMalware)
    #expect(ContentFilter.none.preset == nil)
}

@Test func clearingTheDnsListSendsOnlyTheApplyFlag() throws {
    var expected = ProtoWriter()
    expected.writeString(13, "Router-1")
    expected.writeMessage(3001) { set in set.writeMessage(1) { wifi in wifi.writeBool(1054, true) } }
    #expect(try DnsWrite.clear(targetId: "Router-1") == expected.bytes)
    #expect(throws: PauseError.invalidTarget) { try DnsWrite.clear(targetId: "ut123") }
}

@Test func contentFilterHasShortMenuBarNames() {
    #expect(ContentFilter.allCases.map(\.shortTitle) == ["Off", "Malware", "Adult + malware"])
}
