import SwiftUI

struct GPUMetricsDetailView: View {
    var metrics: GPUMetrics
    var history: [Double] = []
    private let accent = Color.purple

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MetricsDetailHeader(
                title: "GPU", symbol: "display",
                value: metrics.hasUtilization ? CPUMetrics.formatPercent(metrics.usagePercent) : "—",
                subtitle: metrics.modelName.isEmpty ? "No GPU reported" : metrics.modelName,
                color: accent, showsValue: false)
            HStack(spacing: 16) {
                MetricsLoadGauge(percent: metrics.hasUtilization ? metrics.usagePercent : nil,
                                 color: accent, symbol: "square.stack.3d.up")
                MetricsHistoryView(values: history, color: accent, title: "RECENT LOAD")
            }
            if !metrics.hasUtilization {
                Text("GPU utilization unavailable from this host service.")
                    .font(HerdrTheme.mono(.caption2))
                    .foregroundStyle(HerdrTheme.subtext)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                MetricsStat(label: "GPU temperature",
                            value: metrics.temperature > 0 ? String(format: "%.0f°C", metrics.temperature) : "Unavailable")
                if metrics.cores > 0 {
                    MetricsStat(label: "GPU cores", value: "\(metrics.cores)")
                }
                if metrics.memoryTotal > 0 {
                    MetricsStat(label: "VRAM used", value: String(format: "%.2f GiB", metrics.memoryUsed / 1024))
                    MetricsStat(label: "VRAM capacity", value: String(format: "%.2f GiB", metrics.memoryTotal / 1024))
                } else if metrics.memoryUsed > 0 {
                    MetricsStat(label: "GPU memory used", value: String(format: "%.0f MiB", metrics.memoryUsed))
                }
            }
            if metrics.memoryTotal > 0 {
                VStack(alignment: .leading, spacing: 10) {
                    MetricsSectionTitle(title: "VIDEO MEMORY",
                                        detail: CPUMetrics.formatPercent(100 * metrics.memoryUsed / metrics.memoryTotal))
                    HStack(spacing: 12) {
                        MetricsLiquidGauge(percent: 100 * metrics.memoryUsed / metrics.memoryTotal,
                                           color: accent, symbol: "memorychip", compact: true)
                        MetricsStat(label: "VRAM free", value: String(format: "%.2f GiB",
                            max(0, metrics.memoryTotal - metrics.memoryUsed) / 1024), color: accent)
                    }
                }
            }
        }
        .padding(20)
        .metricsPopoverBody(width: MetricsPopoverMetrics.detailWidth)
    }
}
