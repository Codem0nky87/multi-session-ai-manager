import SwiftUI

struct PowerMetricsDetailView: View {
    var metrics: PowerMetrics
    var history: [Double] = []
    private let accent = Color.yellow

    var otherWatts: Double? {
        guard let total = metrics.totalWatts,
              (metrics.cpuWatts != nil || metrics.gpuWatts != nil) else {
            return nil
        }
        return max(0, total - (metrics.cpuWatts ?? 0) - (metrics.gpuWatts ?? 0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MetricsDetailHeader(
                title: "POWER",
                symbol: "bolt.fill",
                value: metrics.formattedTotalWatts,
                subtitle: "Total system power draw",
                color: accent,
                showsValue: true
            )

            if !history.isEmpty {
                MetricsHistoryView(values: history, color: accent, title: "RECENT DRAW")
            }

            if !metrics.hasPower {
                Text("Power telemetry unavailable from this host service.")
                    .font(HerdrTheme.mono(.caption2))
                    .foregroundStyle(HerdrTheme.subtext)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                MetricsStat(
                    label: "CPU draw",
                    value: metrics.cpuWatts.map { PowerMetrics.formatWatts($0) } ?? "—"
                )
                MetricsStat(
                    label: "GPU draw",
                    value: metrics.gpuWatts.map { PowerMetrics.formatWatts($0) } ?? "—"
                )
                if let otherWatts {
                    MetricsStat(
                        label: "Board / other",
                        value: PowerMetrics.formatWatts(otherWatts)
                    )
                }
                MetricsStat(
                    label: "Source",
                    value: metrics.source ?? "—"
                )
            }
        }
        .padding(20)
        .metricsPopoverBody(width: MetricsPopoverMetrics.detailWidth)
    }
}

#Preview {
    PowerMetricsDetailView(
        metrics: PowerMetrics(
            totalWatts: 65.4,
            cpuWatts: 25.1,
            gpuWatts: 18.2,
            source: "rapl+nvml"
        ),
        history: [45.0, 52.0, 65.4]
    )
}
