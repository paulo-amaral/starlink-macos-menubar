import Foundation
import Testing
@testable import StarPulseCore

private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; c.firstWeekday = 2; return c }
/// 2026-11-23 is a Monday.
private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
}

@Test func scheduleOpensInsideTheWindowOnChosenDays() {
    let rule = DeviceRule(name: "School days", devices: [1, 2], kind: .schedule(weekdays: [2, 3, 4, 5, 6], startMinutes: 16 * 60, endMinutes: 21 * 60))
    let inside = RuleEngine.evaluate(rule, now: date(23, 17), calendar: utc) { _, _, _ in 0 }
    #expect(inside.isOpen && inside.held.isEmpty && inside.nextChange == date(23, 21))
    let before = RuleEngine.evaluate(rule, now: date(23, 10), calendar: utc) { _, _, _ in 0 }
    #expect(!before.isOpen && before.held == [1, 2] && before.nextChange == date(23, 16) && !before.notScheduledToday)
    let saturday = RuleEngine.evaluate(rule, now: date(28, 17), calendar: utc) { _, _, _ in 0 }
    #expect(!saturday.isOpen && saturday.notScheduledToday && saturday.nextChange == date(30, 16))
}

@Test func overnightScheduleRunsPastMidnight() {
    let rule = DeviceRule(name: "Night", devices: [1], kind: .schedule(weekdays: [2], startMinutes: 22 * 60, endMinutes: 2 * 60))
    #expect(RuleEngine.evaluate(rule, now: date(24, 1), calendar: utc) { _, _, _ in 0 }.isOpen)       // Tuesday 01:00, Monday's window
    #expect(!RuleEngine.evaluate(rule, now: date(24, 3), calendar: utc) { _, _, _ in 0 }.isOpen)
}

@Test func dataLimitsSharedAndEach() {
    let used: [UInt32: Int64] = [1: 5_000, 2: 4_000, 3: 100]
    let each = DeviceRule(name: "Each", devices: [1, 2, 3], kind: .dataLimit(bytes: 4_500, period: .day, shared: false))
    let e = RuleEngine.evaluate(each, now: date(23, 12), calendar: utc) { id, _, _ in used[id] ?? 0 }
    #expect(e.held == [1] && e.usedBytes == 5_000 && e.nextChange == date(24, 0))
    let shared = DeviceRule(name: "Shared", devices: [2, 3], kind: .dataLimit(bytes: 4_000, period: .week, shared: true))
    let s = RuleEngine.evaluate(shared, now: date(23, 12), calendar: utc) { id, _, _ in used[id] ?? 0 }
    #expect(s.held == [2, 3] && s.usedBytes == 4_100 && s.nextChange == date(30, 0))
}

@Test func timerRunsOutThenHolds() {
    let rule = DeviceRule(name: "Lamp", devices: [9], kind: .timer(duration: 3600, startedAt: date(23, 10)))
    let running = RuleEngine.evaluate(rule, now: date(23, 10, 45), calendar: utc) { _, _, _ in 0 }
    #expect(running.isOpen && running.remaining == 900 && running.held.isEmpty)
    let done = RuleEngine.evaluate(rule, now: date(23, 11, 1), calendar: utc) { _, _, _ in 0 }
    #expect(!done.isOpen && done.remaining == 0 && done.held == [9])
}

@Test func ledgerCountsWholeDaysAndPrunes() {
    var ledger = UsageLedger()
    ledger.add(100, clientId: 1, at: date(22, 23), calendar: utc)
    ledger.add(50, clientId: 1, at: date(23, 1), calendar: utc)
    ledger.add(25, clientId: 1, at: date(23, 9), calendar: utc)
    #expect(ledger.bytes(clientId: 1, from: date(23, 0), to: date(23, 12), calendar: utc) == 75)
    #expect(ledger.bytes(clientId: 1, from: date(22, 0), to: date(23, 12), calendar: utc) == 175)
    ledger.prune(now: date(23, 12).addingTimeInterval(60 * 86_400), calendar: utc)
    #expect(ledger.days.isEmpty)
}

@Test func plannerPausesHeldDevicesAndOnlyReleasesItsOwn() {
    var file = RulesFile()
    // Device 1 held and free: pause. Device 2 held but this Mac: never. Device 3 paused by the Starlink app, not held: left alone.
    var actions = RulePlanner.plan(held: [1, 2], blocked: [3], present: [1, 2, 3], protected: [2], file: &file)
    #expect(actions == [.pause(1)])
    file.pausedByRules.insert(1)
    // The window opens: device 1 is released; device 3 still untouched.
    actions = RulePlanner.plan(held: [], blocked: [1, 3], present: [1, 2, 3], protected: [2], file: &file)
    #expect(actions == [.resume(1)])
}

@Test func plannerRespectsAManualResumeWhileHeld() {
    var file = RulesFile()
    file.pausedByRules = [1]
    // Someone resumed device 1 by hand while the rule still holds it: no re-pause.
    #expect(RulePlanner.plan(held: [1], blocked: [], present: [1], protected: [], file: &file).isEmpty)
    #expect(file.overridden == [1])
    #expect(RulePlanner.plan(held: [1], blocked: [], present: [1], protected: [], file: &file).isEmpty)
    // Once no rule holds it, the override clears; a later hold pauses it again.
    _ = RulePlanner.plan(held: [], blocked: [], present: [1], protected: [], file: &file)
    #expect(file.overridden.isEmpty)
    #expect(RulePlanner.plan(held: [1], blocked: [], present: [1], protected: [], file: &file) == [.pause(1)])
}

@Test func rulesFileRoundTrips() throws {
    var file = RulesFile()
    file.rules = [DeviceRule(name: "A", devices: [1], kind: .timer(duration: 60, startedAt: date(23, 1)))]
    file.usage.add(10, clientId: 1, at: date(23, 1), calendar: utc)
    file.pausedByRules = [1]
    let url = FileManager.default.temporaryDirectory.appending(path: "rules-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    file.save(to: url)
    #expect(RulesFile.load(from: url) == file)
}
