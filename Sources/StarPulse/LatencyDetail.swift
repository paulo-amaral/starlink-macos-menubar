import Charts
import StarPulseCore
import SwiftUI

struct LatencyDetail: View {
    var store: TelemetryStore
    @State private var range = HistoryRange.m15

    var body: some View {
        let window = store.latencyHistory.window(range, dishSamples: store.samples, now: Date())
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 28) {
                figure("Average", window.average)
                figure("Current", window.current)
                if let router = store.routerStatus?.popLatencyMs { figure("Router now", Double(router)) }
                Spacer()
                RangePicker(range: $range)
            }
            Chart {
                ForEach(Array(window.starlink.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value("Time", point.date), y: .value("ms", point.ms), series: .value("s", "Starlink")).foregroundStyle(Theme.ink)
                }
                ForEach(Array(window.router.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value("Time", point.date), y: .value("ms", point.ms), series: .value("s", "Router")).foregroundStyle(Theme.warm)
                }
            }
            .chartForegroundStyleScale(["Starlink": Theme.ink, "Router": Theme.warm])
            .chartYScale(domain: 0...max(25, ((window.starlink + window.router).map(\.ms).max() ?? 0) * 1.1))
            .frame(height: 220)
            if range != .m15 && window.coverage < 0.99 {
                Text("Collected \(Int(window.coverage * 100))% of this window. History builds while the app is open and is kept in memory only; nothing is written to disk.")
                    .font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
            }
            Text("Latency distribution").font(Theme.ui(15, .semibold)).foregroundStyle(Theme.ink)
            Text("over the selected window").font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
            histogram(window.starlinkHistogram, color: Theme.ink, label: "Starlink")
            histogram(window.routerHistogram, color: Theme.warm, label: "Router")
            VStack(alignment: .leading, spacing: 6) {
                Text("What is latency?").font(Theme.ui(13, .semibold)).foregroundStyle(Theme.ink)
                Text("The Starlink dish and router both send test pings to the internet many times per minute. Latency measures how long, in milliseconds, a request takes to go to the internet and back. High latency may affect online gaming, video calls and web browsing. It may be caused by extreme weather or periods of high network usage.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary)
            }
            .padding(14).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline))
        }
    }

    private func figure(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value.map { String(Int($0.rounded())) } ?? "--").font(Theme.ui(22, .bold)).foregroundStyle(Theme.ink)
                Text("ms").font(Theme.ui(12)).foregroundStyle(Theme.inkSecondary)
            }
            Text(label).font(Theme.ui(11)).foregroundStyle(Theme.inkSecondary)
        }
    }

    private func histogram(_ bins: [Double], color: Color, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(label)\(bins.isEmpty ? "" : String(format: " · %.1f%% max", bins.max() ?? 0))").font(Theme.mono(10)).foregroundStyle(Theme.inkSecondary)
            Chart(Array(bins.enumerated()), id: \.offset) { index, percent in
                BarMark(x: .value("ms", index * 5), y: .value("%", percent), width: .fixed(10)).foregroundStyle(color)
            }
            .chartXScale(domain: 0...105)
            .chartXAxis { AxisMarks(values: [0, 50, 100]) { value in AxisValueLabel { Text((value.as(Int.self) ?? 0) == 100 ? "100+ ms" : "\(value.as(Int.self) ?? 0) ms").font(Theme.mono(10)) } } }
            .chartYAxis(.hidden)
            .frame(height: 90)
        }
    }
}
