import Foundation
import Testing
@testable import StarPulseCore

@Suite struct ConditionWatchTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// Feeds one reading per second: `true` while the condition holds.
    func run(_ watch: inout ConditionWatch, _ readings: [Bool]) -> [ConditionWatch.Event] {
        readings.enumerated().compactMap { i, active in watch.update(isActive: active, at: t0.addingTimeInterval(Double(i))) }
    }

    @Test func briefEpisodesStaySilent() {
        var watch = ConditionWatch(threshold: 30)
        let readings = Array(repeating: true, count: 10) + Array(repeating: false, count: 5) + Array(repeating: true, count: 29) + [false]
        #expect(run(&watch, readings).isEmpty)
    }

    @Test func longEpisodeAnnouncesOnceThenEnd() {
        var watch = ConditionWatch(threshold: 30)
        let events = run(&watch, Array(repeating: true, count: 95) + [false, false])
        #expect(events == [.started(since: t0), .ended(duration: 95)])
    }

    @Test func eachEpisodeIsAnnouncedSeparately() {
        var watch = ConditionWatch(threshold: 30)
        let episode = Array(repeating: true, count: 31) + [false]
        #expect(run(&watch, episode + episode).count == 4)
    }
}

@Suite struct LinkCheckTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func minute(drop: (Int) -> Float, latency: Float = 40) -> [TelemetrySample] {
        (0..<60).map { i in
            let d = drop(i)
            return TelemetrySample(timestamp: t0.addingTimeInterval(Double(i)), latencyMs: d >= 1 ? nil : latency,
                                   dropRate: d, downlinkBps: 0, uplinkBps: 0, powerW: 0)
        }
    }

    @Test func steadyLossIsFlagged() {
        let quality = LinkCheck.recent(minute { _ in 0.15 })
        #expect(LinkCheck.isLossy(quality))
        #expect(!LinkCheck.isSlow(quality))
    }

    @Test func outageSecondsDoNotCountAsLoss() {
        // 20 seconds of total outage, the rest clean: an outage, not a lossy link.
        #expect(!LinkCheck.isLossy(LinkCheck.recent(minute { $0 < 20 ? 1 : 0 })))
    }

    @Test func mostlyOutageMinuteGivesNoReading() {
        #expect(LinkCheck.recent(minute { $0 < 40 ? 1 : 0.5 }) == LinkQuality())
    }

    @Test func highMedianLatencyIsFlagged() {
        #expect(LinkCheck.isSlow(LinkCheck.recent(minute(drop: { _ in 0 }, latency: 180))))
    }

    @Test func chosenThresholdsApply() {
        let quality = LinkCheck.recent(minute(drop: { _ in 0.07 }, latency: 120))
        #expect(!LinkCheck.isLossy(quality) && LinkCheck.isLossy(quality, atLeast: 5))
        #expect(!LinkCheck.isSlow(quality) && LinkCheck.isSlow(quality, atLeast: 100))
    }
}
