import SwiftUI
import Charts

struct NetworkMetricsDetailView: View {
    var metrics: NetworkMetrics
    var downloadHistory: [Double] = []
    var uploadHistory: [Double] = []
    var hasSample = false

    private var peak: Double {
        max(1, (downloadHistory + uploadHistory).filter(\.isFinite).max() ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MetricsDetailHeader(title: "NETWORK", symbol: "network", value: "",
                                subtitle: "Live traffic · physical interfaces", color: .blue, showsValue: false)
            flowCard(title: "DOWNLOAD", symbol: "arrow.down", speed: metrics.downloadSpeed,
                     color: .blue, incoming: true, history: downloadHistory)
            flowCard(title: "UPLOAD", symbol: "arrow.up", speed: metrics.uploadSpeed,
                     color: .red, incoming: false, history: uploadHistory)
            Text(hasSample
                 ? "Both charts share a scale. Flow reflects current traffic; it is not a percentage of link capacity."
                 : "Waiting for network samples…")
                .font(HerdrTheme.mono(.caption2))
                .foregroundStyle(HerdrTheme.subtext)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .metricsPopoverBody(width: MetricsPopoverMetrics.detailWidth)
    }

    private func flowCard(title: String, symbol: String, speed: Double, color: Color,
                          incoming: Bool, history: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: symbol)
                    .font(HerdrTheme.mono(.caption2, weight: .bold))
                    .foregroundStyle(color)
                Spacer()
                Text(hasSample ? rate(speed) : "—")
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .foregroundStyle(HerdrTheme.text)
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
            MetricsNetworkFlow(speed: hasSample ? speed : 0, peak: peak, color: color, incoming: incoming)
            if history.count > 1 {
                Chart {
                    ForEach(Array(history.filter(\.isFinite).enumerated()), id: \.offset) { index, value in
                        AreaMark(x: .value("Sample", index), y: .value("Bytes / second", value))
                            .foregroundStyle(LinearGradient(colors: [color.opacity(0.25), color.opacity(0.01)],
                                                            startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Sample", index), y: .value("Bytes / second", value))
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                .chartYScale(domain: 0...peak)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 52)
                .accessibilityLabel("\(title) recent rate")
                .accessibilityValue(rate(speed))
            }
            HStack {
                Text("RECENT PEAK")
                Spacer()
                Text(history.max().map(rate) ?? "—").monospacedDigit()
            }
            .font(HerdrTheme.mono(.caption2))
            .foregroundStyle(HerdrTheme.subtext)
        }
        .padding(14)
        .background(HerdrTheme.panel, in: RoundedRectangle(cornerRadius: 14))
    }

    private func rate(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "—" }
        if value >= 1_073_741_824 { return String(format: "%.1f GiB/s", value / 1_073_741_824) }
        if value >= 1_048_576 { return String(format: "%.1f MiB/s", value / 1_048_576) }
        if value >= 1024 { return String(format: "%.0f KiB/s", value / 1024) }
        return String(format: "%.0f B/s", value)
    }
}

#Preview {
    NetworkMetricsDetailView(metrics: NetworkMetrics(downloadSpeed: 2_700_000, uploadSpeed: 180_000),
                             downloadHistory: [0, 100_000, 900_000, 500_000, 2_700_000],
                             uploadHistory: [0, 50_000, 20_000, 220_000, 180_000], hasSample: true)
}
