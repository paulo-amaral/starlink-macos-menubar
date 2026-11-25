import Foundation
import Testing
@testable import StarPulseCore

@Suite struct OutageWatchTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Feeds one reading per second: `true` while the dish reports an outage.
    func run(_ watch: inout OutageWatch, _ readings: [Bool]) -> [OutageWatch.Event] {
        readings.enumerated().compactMap { i, down in watch.update(isDown: down, at: t0.addingTimeInterval(Double(i))) }
    }

    @Test func briefDropsStaySilent() {
        var watch = OutageWatch(threshold: 30)
        let readings = Array(repeating: true, count: 10) + Array(repeating: false, count: 5) + Array(repeating: true, count: 29) + [false]
        #expect(run(&watch, readings).isEmpty)
    }

    @Test func longOutageAnnouncesOnceThenRecovery() {
        var watch = OutageWatch(threshold: 30)
        let events = run(&watch, Array(repeating: true, count: 95) + [false, false])
        #expect(events == [.down(since: t0), .restored(duration: 95)])
    }

    @Test func eachOutageIsAnnouncedSeparately() {
        var watch = OutageWatch(threshold: 30)
        let outage = Array(repeating: true, count: 31) + [false]
        #expect(run(&watch, outage + outage).count == 4)
    }
}
