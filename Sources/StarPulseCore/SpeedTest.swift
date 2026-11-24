import Foundation

public struct SpeedTestProgress: Sendable, Equatable {
    public enum Phase: Sendable { case idle, download, upload, resting, done, error }
    public var phase = Phase.idle
    public var downloadMbps: Double?
    public var uploadMbps: Double?
    /// Wall-clock span of the loaded link, so latency, jitter and loss are read off the dish's own pings for exactly that window.
    public var startedAt: Date?
    public var endedAt: Date?
    public init() {}
}

/// Steady-state rate of one phase, ported from Dishylink src/lib/speedTest.ts (MIT).
/// The ramp (connection setup and TCP slow start) is excluded from the figure. The reported
/// rate is the cumulative average since the ramp: it converges and cannot freefall, which
/// keeps a gauge readable; per-interval rates are far too bursty.
public struct PhaseMeter: Sendable {
    public static let rampSeconds = 1.0
    public static let settleSeconds = 0.9
    public static let measureSeconds = 10.0

    private let startedAt: Double
    private var rampBytes: Int?
    private var rampAt = 0.0

    public init(startedAt: Double) { self.startedAt = startedAt }

    public func isDone(at now: Double) -> Bool { now - startedAt >= Self.rampSeconds + Self.measureSeconds }

    private func rate(bytes: Int, at now: Double) -> Double {
        let (markBytes, markAt) = rampBytes.map { ($0, rampAt) } ?? (0, startedAt)
        let seconds = now - markAt
        return seconds > 0 ? Double(bytes - markBytes) * 8 / seconds / 1e6 : 0
    }

    /// Call about every 250 ms with the total bytes so far. Returns a live rate once the
    /// post-ramp window is wide enough to divide by; a single buffered burst reads as a spike before that.
    public mutating func sample(bytes: Int, at now: Double) -> Double? {
        guard rampBytes != nil else {
            if now - startedAt >= Self.rampSeconds { rampBytes = bytes; rampAt = now }
            return nil
        }
        return now - rampAt >= Self.settleSeconds ? rate(bytes: bytes, at: now) : nil
    }

    /// The final figure, over the post-ramp window only.
    public func finish(bytes: Int, at now: Double) -> Double { rate(bytes: bytes, at: now) }
}

public struct LinkQuality: Sendable, Equatable {
    public var latencyMs: Double?
    public var jitterMs: Double?
    public var lossPercent: Double?

    /// From the dish's PoP pings over the test window. Latency is the median, jitter the mean
    /// absolute difference between consecutive pings, loss the mean drop rate. Timing a fetch to
    /// Cloudflare would clock DNS, TCP and TLS setup instead of the link.
    public static func over(_ samples: [TelemetrySample], from start: Date?, to end: Date?) -> LinkQuality {
        guard let start else { return LinkQuality() }
        let window = samples.filter { $0.timestamp >= start && $0.timestamp <= (end ?? Date()) }
        let latencies = window.compactMap { $0.latencyMs.map(Double.init) }
        guard !latencies.isEmpty else { return LinkQuality() }
        var jitterSum = 0.0
        for index in latencies.indices.dropFirst() { jitterSum += abs(latencies[index] - latencies[index - 1]) }
        let sorted = latencies.sorted()
        return LinkQuality(
            latencyMs: sorted[sorted.count / 2],
            jitterMs: latencies.count > 1 ? jitterSum / Double(latencies.count - 1) : 0,
            lossPercent: window.map { Double($0.dropRate) }.reduce(0, +) / Double(window.count) * 100
        )
    }
}

private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func add(_ count: Int) { lock.withLock { total += count } }
    var value: Int { lock.withLock { total } }
}

/// Runs against Cloudflare's speed endpoints with several concurrent streams, since a single TCP
/// stream over Starlink's latency is limited by slow start and under-reads. User-initiated only.
public struct SpeedTester: Sendable {
    static let streams = 6
    static let downloadChunk = 25_000_000
    static let uploadChunk = 8_000_000
    static let holdSeconds = 0.9
    static let restSeconds = 1.1
    static let base = "https://speed.cloudflare.com"

    public init() {}

    private static func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

    private final class StreamDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
        let counter: ByteCounter
        let restart: @Sendable (URLSession) -> Void
        let stopped = ByteCounter() // 0 while running, 1 once the phase ended
        init(counter: ByteCounter, restart: @escaping @Sendable (URLSession) -> Void) { self.counter = counter; self.restart = restart }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { counter.add(data.count) }
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) { counter.add(Int(bytesSent)) }
        // Each stream asks again until the phase stops, so a fast link never runs out of bytes.
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if stopped.value == 0 { restart(session) }
        }
    }

    private func runPhase(makeRequest: @escaping @Sendable (URLSession) -> Void, onMbps: @escaping @Sendable (Double) -> Void) async throws -> Double {
        let counter = ByteCounter()
        let delegate = StreamDelegate(counter: counter, restart: makeRequest)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = Self.streams
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { delegate.stopped.add(1); session.invalidateAndCancel() }
        for _ in 0..<Self.streams { makeRequest(session) }

        var meter = PhaseMeter(startedAt: Self.uptime())
        while !meter.isDone(at: Self.uptime()) {
            try await Task.sleep(for: .milliseconds(250))
            if let live = meter.sample(bytes: counter.value, at: Self.uptime()) { onMbps(live) }
        }
        let result = meter.finish(bytes: counter.value, at: Self.uptime())
        if counter.value == 0 { throw URLError(.cannotLoadFromNetwork) }
        return result
    }

    private func measureDownload(onMbps: @escaping @Sendable (Double) -> Void) async throws -> Double {
        try await runPhase(makeRequest: { session in
            guard let url = URL(string: "\(Self.base)/__down?bytes=\(Self.downloadChunk)&r=\(Double.random(in: 0..<1))") else { return }
            session.dataTask(with: URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)).resume()
        }, onMbps: onMbps)
    }

    private func measureUpload(onMbps: @escaping @Sendable (Double) -> Void) async throws -> Double {
        // One buffer shared by every stream: it is only ever read. Incompressible head, zeros after.
        var payload = Data((0..<65_536).map { _ in UInt8.random(in: 0...255) })
        payload.append(Data(count: Self.uploadChunk - payload.count))
        let body = payload
        return try await runPhase(makeRequest: { session in
            guard let url = URL(string: "\(Self.base)/__up") else { return }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            session.uploadTask(with: request, from: body).resume()
        }, onMbps: onMbps)
    }

    /// Cancelling the surrounding Task stops every stream; a cancelled run reports nothing further.
    public func run(progress: @escaping @Sendable (SpeedTestProgress) -> Void) async {
        var state = SpeedTestProgress()
        state.phase = .download
        state.startedAt = Date()
        let report = { @Sendable (value: SpeedTestProgress) in if !Task.isCancelled { progress(value) } }
        report(state)
        do {
            let box = LockedBox(state)
            state.downloadMbps = try await measureDownload { live in report(box.update { $0.downloadMbps = live }) }
            report(state)
            try await Task.sleep(for: .seconds(Self.holdSeconds))
            state.phase = .upload; state.uploadMbps = nil
            box.set(state); report(state)
            try await Task.sleep(for: .seconds(Self.restSeconds))
            state.uploadMbps = try await measureUpload { live in report(box.update { $0.uploadMbps = live }) }
            // The window closes at the true end of upload; the idle holds below must not leak into the quality figures.
            state.endedAt = Date()
            report(state)
            try await Task.sleep(for: .seconds(Self.holdSeconds))
            state.phase = .resting; report(state)
            try await Task.sleep(for: .seconds(Self.restSeconds))
            state.phase = .done; report(state)
        } catch {
            if Task.isCancelled { return }
            state.phase = .error; report(state)
        }
    }
}

private final class LockedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: SpeedTestProgress
    init(_ value: SpeedTestProgress) { self.value = value }
    func set(_ new: SpeedTestProgress) { lock.withLock { value = new } }
    func update(_ change: (inout SpeedTestProgress) -> Void) -> SpeedTestProgress { lock.withLock { change(&value); return value } }
}
