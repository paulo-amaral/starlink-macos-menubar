import Foundation
import Testing
@testable import StarPulseCore

private func ring(newest: UInt64, count: Int, down: Float = 8_000_000, at now: Date) -> DishHistory {
    let samples = (0..<count).map { index in
        TelemetrySample(timestamp: now.addingTimeInterval(-Double(count - 1 - index)), latencyMs: 20, dropRate: 0, downlinkBps: down, uplinkBps: 800_000, powerW: 30)
    }
    return DishHistory(samples: samples, events: [], newestCounter: newest)
}

@Test func integratorStartsAtFirstReadingAndNeverDoubleCounts() {
    var integrator = DishUsageIntegrator()
    let t0 = Date(timeIntervalSince1970: 6_000)               // exactly on a minute boundary
    #expect(integrator.ingest(ring(newest: 1000, count: 900, at: t0)).isEmpty) // backlog is not counted
    let first = integrator.ingest(ring(newest: 1005, count: 900, at: t0.addingTimeInterval(5)))
    #expect(first.map(\.seconds).reduce(0, +) == 5)
    #expect(first.map(\.down).reduce(0, +) == 5 * 1_000_000)   // 8 Mbps is 1 MB/s
    #expect(integrator.ingest(ring(newest: 1005, count: 900, at: t0.addingTimeInterval(6))).isEmpty) // same counter, nothing new
}

@Test func integratorLosesSamplesBeyondTheRingInsteadOfInventingThem() {
    var integrator = DishUsageIntegrator()
    let t0 = Date(timeIntervalSince1970: 6_000)
    _ = integrator.ingest(ring(newest: 1000, count: 900, at: t0))
    let late = integrator.ingest(ring(newest: 3000, count: 900, at: t0.addingTimeInterval(2000))) // slept 2000 s
    #expect(late.map(\.seconds).reduce(0, +) == 900)
}

@Test func integratorRestartsAfterRebootAndSplitsAcrossMinutes() {
    var integrator = DishUsageIntegrator()
    let t0 = Date(timeIntervalSince1970: 6_030)               // 30 s into a minute
    _ = integrator.ingest(ring(newest: 5000, count: 900, at: t0))
    let after = integrator.ingest(ring(newest: 40, count: 40, at: t0.addingTimeInterval(60))) // counter reset
    #expect(after.map(\.seconds).reduce(0, +) == 40)
    var other = DishUsageIntegrator()
    _ = other.ingest(ring(newest: 100, count: 900, at: t0))
    let split = other.ingest(ring(newest: 160, count: 900, at: Date(timeIntervalSince1970: 6_090))) // spans two minutes
    #expect(split.count == 2)
    #expect(split.map(\.seconds).reduce(0, +) == 60)
}

@Test func trackerFindsEdgesAndReportsExactRate() {
    var tracker = ThroughputTracker()
    let fallback = ClientRate(downMbps: 99, upMbps: 99)
    #expect(tracker.read(key: "a", rx: 1_000, tx: 0, atMs: 0, fallback: fallback).rate == fallback) // seed
    // Polling 4x per step; the counter moves once, by 125,625 bytes = 1 Mbit over 1.005 s.
    #expect(tracker.read(key: "a", rx: 1_000, tx: 0, atMs: 250, fallback: fallback).rate == fallback)
    let edge = tracker.read(key: "a", rx: 126_625, tx: 0, atMs: 500, fallback: fallback)
    #expect(edge.rxDelta == 125_625)
    #expect(abs(edge.rate.downMbps - 1.0) < 0.001)   // 125625*8/1.005 s
    #expect(tracker.read(key: "a", rx: 126_625, tx: 0, atMs: 750, fallback: fallback).rate == edge.rate) // held between edges
    #expect(tracker.read(key: "a", rx: 126_625, tx: 0, atMs: 500 + 2_100, fallback: fallback).rate == .zero) // idle
}

@Test func trackerDoesNotInventTrafficOnResetOrGap() {
    var tracker = ThroughputTracker()
    let fallback = ClientRate(downMbps: 5, upMbps: 1)
    _ = tracker.read(key: "a", rx: 10_000, tx: 10_000, atMs: 0, fallback: fallback)
    let reset = tracker.read(key: "a", rx: 100, tx: 100, atMs: 1_000, fallback: fallback) // device rejoined
    #expect(reset.rxDelta == 0 && reset.rate == fallback)
    let gap = tracker.read(key: "a", rx: 5_000_000, tx: 5_000_000, atMs: 1_000 + 20_000, fallback: fallback) // slept
    #expect(gap.rxDelta == 0 && gap.rate == fallback)
    #expect(tracker.read(key: "wired", rx: nil, tx: nil, atMs: 0, fallback: fallback).rate == fallback)
}

private func latencyRing(newest: UInt64, count: Int, ms: Float?, at now: Date) -> DishHistory {
    DishHistory(samples: (0..<count).map { TelemetrySample(timestamp: now.addingTimeInterval(-Double(count - 1 - $0)), latencyMs: ms, dropRate: 0, downlinkBps: 0, uplinkBps: 0, powerW: 0) }, events: [], newestCounter: newest)
}

@Test func latencyHistoryCountsEachSecondOnceAndBinsBy5ms() {
    var history = LatencyHistory()
    let now = Date(timeIntervalSince1970: 6_060)
    history.ingestDish(latencyRing(newest: 900, count: 900, ms: 22, at: now))
    history.ingestDish(latencyRing(newest: 900, count: 900, ms: 22, at: now.addingTimeInterval(5))) // same counter: ignored
    var window = history.window(.m15, dishSamples: latencyRing(newest: 900, count: 900, ms: 22, at: now).samples, now: now)
    #expect(window.average == 22)
    #expect(window.starlinkHistogram[4] == 100)         // 22 ms falls in the 20-25 ms bin
    #expect(window.starlinkHistogram.count == 21)
    history.ingestDish(latencyRing(newest: 910, count: 900, ms: 120, at: now.addingTimeInterval(10)))
    window = history.window(.h1, dishSamples: [], now: now.addingTimeInterval(10)) // 1 h spans every bucket; a 15 min window drops the oldest partial minute
    #expect(abs(window.starlinkHistogram[20] - 100 * 10 / 910) < 0.001)   // 120 ms lands in the 100+ bin
}

@Test func latencyWindowCoverageGrowsAndOutageSecondsAreSkipped() {
    var history = LatencyHistory()
    let now = Date(timeIntervalSince1970: 36_000)
    history.ingestDish(latencyRing(newest: 900, count: 900, ms: 30, at: now))
    let h6 = history.window(.h6, dishSamples: [], now: now)
    #expect(h6.coverage > 0.04 && h6.coverage < 0.06)   // 15 of 360 minutes
    var outage = LatencyHistory()
    outage.ingestDish(latencyRing(newest: 60, count: 60, ms: nil, at: now))
    #expect(outage.window(.m15, dishSamples: [], now: now).average == nil)
    history.recordRouter(.nan, at: now); history.recordRouter(0, at: now); history.recordRouter(48, at: now)
    #expect(history.window(.m15, dishSamples: [], now: now).router.count == 1)
}

@Test func dishConfigDefaultsAndWindows() throws {
    var inner = ProtoWriter(); inner.writeVarint(9, 3)                     // only the hour is sent; zero values are omitted
    var outer = ProtoWriter(); outer.writeMessage(1) { $0.writeVarint(9, 3) }
    var envelope = ProtoWriter(); envelope.writeBytes(2011, outer.bytes)
    let config = try DishDecoder.decodeConfig(response: envelope.bytes)
    #expect(config.snowMelt == .automatic && !config.sleepEnabled && !config.deferUpdates && config.updateRebootHour == 3)
    #expect(UpdateWindow.containing(hour: 3).label == "Overnight, around 3 AM")
    #expect(UpdateWindow.containing(hour: 10).hour == 9)                  // off-grid hour shows its window
    var on = ProtoWriter(); on.writeMessage(1) { $0.writeVarint(1, 2); $0.writeVarint(4, 60); $0.writeVarint(5, 480); $0.writeBool(6, true); $0.writeBool(7, true) }
    var env2 = ProtoWriter(); env2.writeBytes(2011, on.bytes)
    let set = try DishDecoder.decodeConfig(response: env2.bytes)
    #expect(set.snowMelt == .alwaysOff && set.sleepEnabled && set.deferUpdates && set.sleepStartUTCMinutes == 60 && set.sleepDurationMinutes == 480)
    let zone = TimeZone(secondsFromGMT: 9 * 3600)!
    #expect(SleepSchedule.localMinutes(fromUTC: 23 * 60, in: zone) == 8 * 60) // wraps past midnight
}

@Test func routerConfigReadsNamesAndNeverTheCredential() throws {
    var wifi = ProtoWriter()
    wifi.writeString(3, "TL")
    wifi.writeMessage(1100) { network in
        network.writeMessage(2) { $0.writeString(1005, "HomeNet"); $0.writeVarint(1011, 2); $0.writeMessage(2002) { $0.writeString(1, "super-secret-pass") } }
        network.writeMessage(2) { $0.writeString(1005, "HomeNet"); $0.writeVarint(1011, 5); $0.writeMessage(2002) { $0.writeString(1, "super-secret-pass") } }
    }
    wifi.writeMessage(33) { entry in entry.writeString(1, "node-1"); entry.writeMessage(2) { $0.writeString(1, "Mesh 1"); $0.writeVarint(3, 2); $0.writeString(9, "v2") } }
    wifi.writeString(30, "1.1.1.1")
    var outer = ProtoWriter(); outer.writeMessage(1) { $0.writeBytes(0, []) }
    var envelope = ProtoWriter(); envelope.writeMessage(3009) { $0.writeBytes(1, wifi.bytes) }
    let config = try RouterDecoder.decodeConfig(response: envelope.bytes)
    #expect(config.country == "TL")
    #expect(config.networks == [RouterNetwork(ssid: "HomeNet", bands: ["2.4 GHz", "5 GHz"], security: "WPA2", hidden: false)])
    #expect(config.meshNodes == [MeshNode(name: "Mesh 1", trusted: true, hardware: "v2")])
    #expect(config.nameservers == ["1.1.1.1"])
    #expect(!"\(config)".contains("super-secret-pass"))
}

private func client(_ id: UInt32, rx: UInt64?, tx: UInt64?) -> WifiClient {
    var c = WifiClient(); c.clientId = id; c.name = "dev"; c.rxBytes = rx; c.txBytes = tx; c.downAvgMbps = 0.5; c.upAvgMbps = 0.1
    return c
}

@Test func clientHistoryUsesCountersAndBuildsSeries() {
    var history = ClientHistory()
    let t0 = Date(timeIntervalSince1970: 6_000)
    // Four polls per refresh period; the counter steps once by 125,625 bytes (1 Mbit over 1.005 s).
    history.record([client(1, rx: 1_000, tx: 0)], at: t0)
    history.record([client(1, rx: 1_000, tx: 0)], at: t0.addingTimeInterval(0.25))
    history.record([client(1, rx: 126_625, tx: 0)], at: t0.addingTimeInterval(0.5))
    #expect(abs(history.rate(for: "1").downMbps - 1.0) < 0.001)
    #expect(history.rate(for: "missing") == .zero)
    history.record([client(1, rx: 126_625, tx: 0)], at: t0.addingTimeInterval(1.5))
    let series = history.series(for: "1", range: .m15, now: t0.addingTimeInterval(2))
    #expect(series.count == 2)                                   // one point per second, not per poll
    let hour = history.series(for: "1", range: .h1, now: t0.addingTimeInterval(2))
    #expect(hour.count == 1 && hour[0].downMbps > 0)
}

@Test func clientHistoryFallsBackToRouterAverageWithoutCounters() {
    var history = ClientHistory()
    history.record([client(2, rx: nil, tx: nil)], at: Date(timeIntervalSince1970: 6_000))
    #expect(history.rate(for: "2") == ClientRate(downMbps: 0.5, upMbps: 0.1))
}

@Test func macVendorFindsRegistryNamesAndPrivateAddresses() {
    #expect(MacVendor.isPrivate("2a:1d:a1:7c:a9:7e"))             // locally administered bit set
    #expect(MacVendor.label(for: "2a:1d:a1:00:00:00") == "Private")
    #expect(!MacVendor.isPrivate("28:6f:b9:00:00:00"))
    #expect(MacVendor.label(for: "28:6F:B9:00:00:00")?.isEmpty == false) // 286fb9 is in the registry
    #expect(MacVendor.label(for: "not a mac") == nil)
    #expect(SignalQuality.label(dbm: -45) == "excellent" && SignalQuality.label(dbm: -84) == "weak")
}

@Test func phaseMeterExcludesRampAndAveragesSinceIt() {
    var meter = PhaseMeter(startedAt: 100)
    // 10 MB arrived during the 1 s ramp (slow start, setup); it must not count.
    #expect(meter.sample(bytes: 5_000_000, at: 100.5) == nil)
    #expect(meter.sample(bytes: 10_000_000, at: 101.0) == nil)          // ramp ends: this is the mark
    #expect(meter.sample(bytes: 11_000_000, at: 101.5) == nil)          // still settling
    let live = meter.sample(bytes: 21_000_000, at: 102.0)                 // 11 MB over 1 s since the mark
    #expect(abs((live ?? 0) - 88.0) < 0.001)                              // 11e6 * 8 / 1 s = 88 Mbps
    #expect(!meter.isDone(at: 105))
    #expect(meter.isDone(at: 111.0))
    #expect(abs(meter.finish(bytes: 110_000_000, at: 111.0) - 80.0) < 0.001) // 100 MB over 10 s
}

@Test func linkQualityReadsTheDishPingsOverTheTestWindow() {
    func sample(_ second: Double, _ ms: Float?, drop: Float = 0) -> TelemetrySample {
        TelemetrySample(timestamp: Date(timeIntervalSince1970: second), latencyMs: ms, dropRate: drop, downlinkBps: 0, uplinkBps: 0, powerW: 0)
    }
    let samples = [sample(0, 500), sample(10, 20), sample(11, 24), sample(12, 22, drop: 0.5), sample(13, nil, drop: 1), sample(99, 900)]
    let quality = LinkQuality.over(samples, from: Date(timeIntervalSince1970: 10), to: Date(timeIntervalSince1970: 13))
    #expect(quality.latencyMs == 22)                       // median of 20, 24, 22; outside samples ignored
    #expect(quality.jitterMs == 3)                         // (|24-20| + |22-24|) / 2
    let expectedLoss: Double = (0.0 + 0.0 + 0.5 + 1.0) / 4.0 * 100.0
    #expect(quality.lossPercent == expectedLoss)
    #expect(LinkQuality.over(samples, from: nil, to: nil) == LinkQuality())
}

@Test func bufferbloatComparesLoadedLatencyWithIdle() {
    func sample(_ second: Double, _ ms: Float?) -> TelemetrySample {
        TelemetrySample(timestamp: Date(timeIntervalSince1970: second), latencyMs: ms, dropRate: 0, downlinkBps: 0, uplinkBps: 0, powerW: 0)
    }
    // Idle 20-40 ms before the run (mean 30); download 70 ms (mean); upload 40 ms (mean).
    let samples = [sample(50, 900), sample(80, 20), sample(90, 40),
                   sample(100, 60), sample(105, 80), sample(120, 40), sample(125, 40), sample(200, 900)]
    var progress = SpeedTestProgress()
    progress.startedAt = Date(timeIntervalSince1970: 100)
    progress.downloadEndedAt = Date(timeIntervalSince1970: 110)
    progress.uploadStartedAt = Date(timeIntervalSince1970: 118)
    progress.endedAt = Date(timeIntervalSince1970: 130)
    let bloat = Bufferbloat.measure(samples, progress: progress)
    #expect(bloat?.idleMs == 30)
    #expect(bloat?.downloadMs == 70)
    #expect(bloat?.uploadMs == 40)
    #expect(bloat?.increaseMs == 40)          // the larger increase, download
    #expect(bloat?.grade == "B")
    #expect(Bufferbloat.measure(samples, progress: SpeedTestProgress()) == nil)
}

@Test func bufferbloatGradesFollowWaveformsScale() {
    func grade(_ increase: Double) -> String { Bufferbloat(idleMs: 30, downloadMs: 30 + increase, uploadMs: nil).grade }
    #expect(grade(4.9) == "A+")
    #expect(grade(5) == "A")
    #expect(grade(59) == "B")
    #expect(grade(199) == "C")
    #expect(grade(399) == "D")
    #expect(grade(400) == "F")
    #expect(Bufferbloat(idleMs: 40, downloadMs: 30, uploadMs: nil).increaseMs == 0)
}

// Dishylink #71: label a speed test by whether it ran through SpaceX's network (AS14593).
@Test func starlinkNetworkMatchesAnnouncedPrefixes() throws {
    let json = #"{"data":{"prefixes":[{"prefix":"98.97.0.0/16"},{"prefix":"2605:59c8::/31"},{"prefix":"129.222.4.0/23"}]}}"#
    let network = try StarlinkNetwork(ripeStatJSON: Data(json.utf8))
    #expect(network.contains("98.97.12.34"))
    #expect(network.contains("129.222.5.200"))
    #expect(!network.contains("129.222.6.1"))
    #expect(network.contains("2605:59c9:1234::1"))
    #expect(!network.contains("2605:59ca::1"))
    #expect(!network.contains("203.0.113.9"))
    #expect(!network.contains("not an address"))
}
