import Observation
import StarPulseCore
import SwiftUI

@MainActor @Observable
final class SpeedTestModel {
    var progress = SpeedTestProgress()
    /// Full-scale of the dial in Mbps. It only steps up during a run, so the needle never jumps back.
    var gaugeMax = 100.0
    /// Whether the last run went through Starlink (Dishylink issue #71); nil until known.
    var onStarlink: Bool?
    private var task: Task<Void, Never>?

    static let scales = [50.0, 100, 250, 500, 1000, 2000]

    /// The Mbps the needle shows: the phase in progress, then rest at zero between phases.
    var liveMbps: Double {
        switch progress.phase {
        case .download: progress.downloadMbps ?? 0
        case .upload: progress.uploadMbps ?? 0
        default: 0
        }
    }

    var isRunning: Bool { progress.phase == .download || progress.phase == .upload || progress.phase == .resting }

    func start() {
        guard !isRunning else { return }
        progress = SpeedTestProgress()
        gaugeMax = 100
        onStarlink = nil
        Task { [weak self] in
            let result = await StarlinkNetwork.isThisMacOnStarlink()
            self?.onStarlink = result
        }
        task = Task { [weak self] in
            await SpeedTester().run { update in
                Task { @MainActor in
                    guard let self else { return }
                    self.progress = update
                    let peak = max(update.downloadMbps ?? 0, update.uploadMbps ?? 0)
                    if let next = Self.scales.first(where: { peak <= $0 * 0.9 }), next > self.gaugeMax { self.gaugeMax = next }
                }
            }
        }
    }

    /// Leaving the screen must stop the streams, or they keep saturating the link unseen.
    func cancel() {
        task?.cancel()
        task = nil
        if isRunning { progress = SpeedTestProgress() }
    }
}

struct SpeedTestView: View {
    var model: SpeedTestModel
    var store: TelemetryStore
    @State private var showAdvanced = false

    #if DEBUG
    // Development aid: lets the dial be looked at without spending the plan's data on a real run.
    private var gaugeValue: Double { UserDefaults.standard.double(forKey: "debugGaugeValue") > 0 ? UserDefaults.standard.double(forKey: "debugGaugeValue") : model.liveMbps }
    private var gaugeMaximum: Double { UserDefaults.standard.double(forKey: "debugGaugeValue") > 0 ? 250 : model.gaugeMax }
    #else
    private var gaugeValue: Double { model.liveMbps }
    private var gaugeMaximum: Double { model.gaugeMax }
    #endif

    var body: some View {
        let progress = model.progress
        let quality = LinkQuality.over(store.samples, from: progress.startedAt, to: progress.endedAt)
        let bloat = Bufferbloat.measure(store.samples, progress: progress)
        VStack(spacing: 14) {
            SpeedGauge(value: gaugeValue, maximum: gaugeMaximum, color: progress.phase == .upload ? Theme.up : Theme.down)
                .frame(height: 200)
            Text("STARLINK").font(Theme.ui(13, .bold)).tracking(8).foregroundStyle(Theme.ink)
            if let onStarlink = model.onStarlink {
                Label(onStarlink ? "Measured over Starlink" : "Not measured over Starlink",
                      systemImage: onStarlink ? "checkmark.seal" : "exclamationmark.triangle")
                    .font(Theme.ui(11, .medium)).foregroundStyle(onStarlink ? Theme.good : Theme.warm)
                    .help(onStarlink ? "This Mac's public address belongs to SpaceX's network (AS14593)"
                                     : "This Mac reached Cloudflare through another network, such as a VPN or another connection")
            }
            HStack(alignment: .top) {
                figure(progress.downloadMbps, "arrow.down.to.line", "Mbps", measured: progress.downloadMbps != nil)
                figure(progress.uploadMbps, "arrow.up.to.line", "Mbps", measured: progress.uploadMbps != nil)
                figure(quality.latencyMs, "clock", "ms", measured: quality.latencyMs != nil)
            }
            Text(statusText(progress.phase)).font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary).frame(minHeight: 14)
            Button {
                if model.isRunning { model.cancel() } else { model.start() }
            } label: {
                Text(model.isRunning ? "Stop" : (progress.phase == .done ? "Run again" : "Start"))
                    .font(Theme.ui(13, .semibold)).foregroundStyle(.black).frame(maxWidth: .infinity).padding(.vertical, 9)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain).help(model.isRunning ? "Stop the test" : "Measure download and upload against Cloudflare")
            Button { withAnimation(.easeOut(duration: 0.15)) { showAdvanced.toggle() } } label: {
                Label("Advanced", systemImage: showAdvanced ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.appCompact)
            .help(showAdvanced ? "Hide latency, jitter, loss and bufferbloat" : "Show latency, jitter, loss and bufferbloat for the run")
            if showAdvanced {
                VStack(spacing: 6) {
                    detail("Latency", quality.latencyMs.map { String(format: "%.0f ms", $0) }, "Median of the dish's pings during the test")
                    detail("Jitter", quality.jitterMs.map { String(format: "%.1f ms", $0) }, "Mean change between consecutive pings")
                    detail("Loss", quality.lossPercent.map { String(format: "%.1f %%", $0) }, "Share of pings lost during the test")
                    detail("Idle latency", bloat.map { String(format: "%.0f ms", $0.idleMs) }, "Average of the dish's pings in the 30 seconds before the test")
                    detail("Latency under load", bloat.map { b in
                        [b.downloadMs.map { String(format: "↓ %.0f", $0) }, b.uploadMs.map { String(format: "↑ %.0f", $0) }]
                            .compactMap { $0 }.joined(separator: "  ") + " ms"
                    }, "Average of the dish's pings while download and upload ran")
                    detail("Bufferbloat", bloat.map { String(format: "%@ · +%.0f ms", $0.grade, $0.increaseMs) },
                           "Largest rise over idle latency, graded A+ to F on Waveform's scale")
                    Text("Measured against Cloudflare. It may read lower than tests to a nearby server. The test runs about 11 seconds each way and uses data from your plan. Latency, jitter and loss come from the dish and fill in a few seconds after the run.")
                        .font(Theme.ui(10)).foregroundStyle(Theme.inkSecondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 8)
            }
        }
        .onDisappear { model.cancel() }
    }

    private func statusText(_ phase: SpeedTestProgress.Phase) -> String {
        switch phase {
        case .idle: ""
        case .download: "Testing download…"
        case .upload: "Testing upload…"
        case .resting: "Finishing…"
        case .done: "Done."
        case .error: "The test failed. Check the connection and try again."
        }
    }

    private func figure(_ value: Double?, _ symbol: String, _ unit: String, measured: Bool) -> some View {
        VStack(spacing: 2) {
            Text(value.map { $0 >= 100 ? String(format: "%.0f", $0) : String(format: "%.1f", $0) } ?? "0")
                .font(Theme.ui(26, .bold)).foregroundStyle(measured ? Theme.ink : Theme.inkMuted)
            HStack(spacing: 3) { Image(systemName: symbol); Text(unit) }
                .font(Theme.ui(11, .semibold)).foregroundStyle(Theme.inkSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func detail(_ label: String, _ value: String?, _ help: String) -> some View {
        HStack {
            Text(label).font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary)
            Spacer()
            Text(value ?? "--").font(Theme.mono(11)).foregroundStyle(Theme.ink)
        }
        .help(help)
    }
}

/// Speedometer: a 240 degree dial with ticks and a needle, over faint concentric rings.
/// Angles are screen angles in degrees, increasing clockwise; the dial runs from lower left over the top to lower right.
struct SpeedGauge: View {
    var value: Double
    var maximum: Double
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let startDegrees = 150.0
    private static let sweepDegrees = 240.0

    var body: some View {
        let fraction = max(0, min(1, value / maximum))
        GeometryReader { proxy in
            // The dial's top sits above the centre and its ends dip below it, so both bound the radius.
            let radius = min(proxy.size.width / 2 - 8, proxy.size.height * 0.62 - 8)
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height * 0.62)
            ZStack {
                ForEach(1..<4) { ring in
                    DialArc(from: 0, to: 1, center: center, radius: radius * (0.38 + 0.14 * Double(ring)))
                        .stroke(Theme.hairline, lineWidth: 0.6)
                }
                DialArc(from: 0, to: 1, center: center, radius: radius).stroke(Theme.hairline, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                DialArc(from: 0, to: fraction, center: center, radius: radius).stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                ForEach(0...10, id: \.self) { tick in
                    Tick(fraction: Double(tick) / 10, center: center, outer: radius - 11, inner: radius - (tick.isMultiple(of: 5) ? 20 : 16))
                        .stroke(Theme.inkSecondary, lineWidth: tick.isMultiple(of: 5) ? 1.4 : 0.8)
                }
                ForEach([0.0, 0.5, 1.0], id: \.self) { mark in
                    Text(label(maximum * mark)).font(Theme.mono(10)).foregroundStyle(Theme.inkSecondary)
                        .position(point(center: center, radius: radius - 32, fraction: mark))
                }
                Needle(fraction: fraction, center: center, length: radius - 24).stroke(Theme.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                Circle().fill(Theme.ink).frame(width: 10, height: 10).position(center)
                Text(String(format: value >= 100 ? "%.0f" : "%.1f", value)).font(Theme.ui(22, .bold)).foregroundStyle(Theme.ink)
                    .position(x: center.x, y: center.y + radius * 0.4)
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.35), value: fraction)
        }
        .accessibilityElement()
        .accessibilityLabel("Speed gauge")
        .accessibilityValue(String(format: "%.0f megabits per second", value))
    }

    private func label(_ mbps: Double) -> String { mbps >= 1000 ? String(format: "%.0fG", mbps / 1000) : String(format: "%.0f", mbps) }

    private func point(center: CGPoint, radius: Double, fraction: Double) -> CGPoint {
        let angle = (Self.startDegrees + Self.sweepDegrees * fraction) * .pi / 180
        return CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    }

    private struct DialArc: Shape {
        var from: Double, to: Double
        var center: CGPoint, radius: Double
        var animatableData: Double { get { to } set { to = newValue } }
        func path(in rect: CGRect) -> Path {
            var path = Path()
            let steps = max(2, Int(120 * max(0.02, to - from)))
            for step in 0...steps {
                let fraction = from + (to - from) * Double(step) / Double(steps)
                let angle = (SpeedGauge.startDegrees + SpeedGauge.sweepDegrees * fraction) * .pi / 180
                let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            return path
        }
    }

    private struct Tick: Shape {
        var fraction: Double, center: CGPoint, outer: Double, inner: Double
        func path(in rect: CGRect) -> Path {
            let angle = (SpeedGauge.startDegrees + SpeedGauge.sweepDegrees * fraction) * .pi / 180
            var path = Path()
            path.move(to: CGPoint(x: center.x + inner * cos(angle), y: center.y + inner * sin(angle)))
            path.addLine(to: CGPoint(x: center.x + outer * cos(angle), y: center.y + outer * sin(angle)))
            return path
        }
    }

    private struct Needle: Shape {
        var fraction: Double, center: CGPoint, length: Double
        var animatableData: Double { get { fraction } set { fraction = newValue } }
        func path(in rect: CGRect) -> Path {
            let angle = (SpeedGauge.startDegrees + SpeedGauge.sweepDegrees * fraction) * .pi / 180
            var path = Path()
            path.move(to: center)
            path.addLine(to: CGPoint(x: center.x + length * cos(angle), y: center.y + length * sin(angle)))
            return path
        }
    }
}
