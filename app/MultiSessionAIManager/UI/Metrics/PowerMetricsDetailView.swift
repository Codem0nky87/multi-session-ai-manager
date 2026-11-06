import SwiftUI

struct PowerMetricsDetailView: View {
    var metrics: PowerMetrics
    var history: [Double] = []
    private let accent = Color.yellow

    var peakWatts: Double? {
        let finiteHistory = history.filter(\.isFinite)
        let candidates = finiteHistory + [metrics.totalWatts].compactMap { $0?.isFinite == true ? $0 : nil }
        guard let maxVal = candidates.max(), maxVal > 0 else { return nil }
        return maxVal
    }

    var powerPercent: Double? {
        guard let total = metrics.totalWatts, total.isFinite, total >= 0 else { return nil }
        let ceiling = max(100.0, peakWatts ?? 0.0)
        return min(100.0, max(0.0, (total / ceiling) * 100.0))
    }

    var otherWatts: Double? {
        guard let total = metrics.totalWatts,
              (metrics.cpuWatts != nil || metrics.gpuWatts != nil) else {
            return nil
        }
        return max(0, total - (metrics.cpuWatts ?? 0) - (metrics.gpuWatts ?? 0))
    }

    private var subtitleText: String {
        guard let total = metrics.totalWatts, total.isFinite, total >= 0 else {
            return "Total system power draw"
        }
        if let peak = peakWatts, peak > total {
            return "\(metrics.formattedTotalWatts) draw · \(PowerMetrics.formatWatts(peak)) peak"
        } else {
            return "\(metrics.formattedTotalWatts) total system draw"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MetricsDetailHeader(
                title: "POWER",
                symbol: "bolt.fill",
                value: metrics.formattedTotalWatts,
                subtitle: subtitleText,
                color: accent,
                showsValue: false
            )

            HStack(spacing: 16) {
                MetricsLiquidGauge(
                    percent: powerPercent,
                    color: accent,
                    symbol: "bolt.fill"
                )
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
                if let peakWatts {
                    MetricsStat(
                        label: "Peak draw",
                        value: PowerMetrics.formatWatts(peakWatts)
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
