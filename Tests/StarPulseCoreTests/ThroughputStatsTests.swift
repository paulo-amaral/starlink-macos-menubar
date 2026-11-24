import Foundation
import Testing
@testable import StarPulseCore

private let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()

private func sample(_ second: Double, down: Float, up: Float, sequence: UInt64) -> TelemetrySample {
    TelemetrySample(timestamp: Date(timeIntervalSince1970: second), latencyMs: 30, dropRate: 0,
                    downlinkBps: down, uplinkBps: up, powerW: 30, sequence: sequence)
}

// Dishylink #104: the ring buffer is re-read every few seconds; each dish second counts once.
@Test func ledgerCountsEachDishSecondOnce() {
    var ledger = ThroughputLedger()
    let day = 1_795_000_000.0 // 2026-11-18 UTC
    ledger.ingest([sample(day, down: 10e6, up: 1e6, sequence: 1), sample(day + 1, down: 30e6, up: 3e6, sequence: 2)], calendar: utc)
    ledger.ingest([sample(day + 1, down: 30e6, up: 3e6, sequence: 2), sample(day + 2, down: 20e6, up: 2e6, sequence: 3)], calendar: utc)
    let today = ledger.summary(.today, now: Date(timeIntervalSince1970: day + 10), calendar: utc)
    #expect(today?.seconds == 3)
    #expect(today?.maxDownBps == 30e6)
    #expect(today?.averageDownBps == 20e6)
    #expect(today?.maxUpBps == 3e6)
    #expect(today?.averageUpBps == 2e6)
}

@Test func ledgerStartsOverWhenTheDishRestarts() {
    var ledger = ThroughputLedger()
    let day = 1_795_000_000.0
    ledger.ingest([sample(day, down: 10e6, up: 0, sequence: 500)], calendar: utc)
    ledger.ingest([sample(day + 60, down: 50e6, up: 0, sequence: 3)], calendar: utc) // counter went back: reboot
    #expect(ledger.summary(.today, now: Date(timeIntervalSince1970: day + 61), calendar: utc)?.seconds == 2)
}

@Test func ledgerSummarisesPeriodsAndKeepsSixtyTwoDays() {
    var ledger = ThroughputLedger()
    let start = 1_793_577_600.0 // 2026-11-02 00:00 UTC
    for day in 0..<70 {
        let t = start - Double(69 - day) * 86_400
        ledger.ingest([sample(t, down: Float(day) * 1e6, up: 1e6, sequence: UInt64(day + 1))], calendar: utc)
    }
    #expect(ledger.dayCount == ThroughputLedger.dayLimit)
    let now = Date(timeIntervalSince1970: start + 3600)
    #expect(ledger.summary(.week, now: now, calendar: utc)?.seconds == 7)
    #expect(ledger.summary(.week, now: now, calendar: utc)?.maxDownBps == 69e6)
    #expect(ledger.summary(.month, now: now, calendar: utc)?.seconds == 2) // 1 and 2 November
    #expect(ledger.summary(.days30, now: now, calendar: utc)?.seconds == 30)
    #expect(ThroughputLedger().summary(.today, now: now, calendar: utc) == nil)
}
