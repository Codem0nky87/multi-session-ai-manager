import SwiftUI

struct GPUMetricsDetailView: View {
    var metrics: GPUMetrics
    var history: [Double] = []
    private let accent = Color.purple

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MetricsDetailHeader(
                title: "GPU", symbol: "display",
                value: metrics.modelName.isEmpty ? "—" : CPUMetrics.formatPercent(metrics.usagePercent),
                subtitle: metrics.modelName.isEmpty ? "No GPU reported" : metrics.modelName,
                color: accent)
            MetricsHistoryView(values: history, color: accent)
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
                    MetricsUsageTrack(percent: 100 * metrics.memoryUsed / metrics.memoryTotal, color: accent)
                }
            }
        }
        .padding(20)
        .metricsPopoverBody(width: MetricsPopoverMetrics.detailWidth)
    }
}
