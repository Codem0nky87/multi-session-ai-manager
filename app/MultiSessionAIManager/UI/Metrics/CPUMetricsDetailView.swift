import SwiftUI

struct CPUMetricsDetailView: View {
    var metrics: CPUMetrics
    private let accent = HerdrTheme.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MetricsDetailHeader(
                title: "CPU", symbol: "cpu", value: metrics.utilizationText,
                subtitle: metrics.coreCount.map { "Total capacity · \($0) logical cores" } ?? "Total CPU capacity",
                color: accent)
            MetricsHistoryView(values: metrics.history, color: accent)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                MetricsStat(label: "CPU temperature",
                            value: metrics.temperature > 0 ? String(format: "%.0f°C", metrics.temperature) : "Unavailable")
                MetricsStat(label: "Load / core",
                            value: metrics.loadPerCore.map { String(format: "%.2f", $0) } ?? "—")
                MetricsStat(label: "User", value: CPUMetrics.formatPercent(metrics.userUsage), color: accent)
                MetricsStat(label: "System", value: CPUMetrics.formatPercent(metrics.systemUsage))
                MetricsStat(label: "Idle", value: CPUMetrics.formatPercent(metrics.idleUsage))
                MetricsStat(label: "Load · 1 / 5 / 15 min",
                            value: String(format: "%.2f / %.2f / %.2f",
                                          metrics.loadAverage1m, metrics.loadAverage5m, metrics.loadAverage15m))
            }
            if !metrics.uptime.isEmpty {
                MetricsStat(label: "Uptime", value: metrics.uptime)
            }

            if let cores = metrics.perCoreUsage, !cores.isEmpty {
                Divider().overlay(HerdrTheme.selection)
                MetricsSectionTitle(title: "LOGICAL CORES", detail: "\(cores.count)")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 60))], spacing: 12) {
                    ForEach(Array(cores.enumerated()), id: \.offset) { index, usage in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(CPUMetrics.formatPercent(usage))
                                .font(HerdrTheme.mono(.caption, weight: .semibold))
                                .foregroundStyle(HerdrTheme.text)
                            MetricsUsageTrack(percent: usage, color: accent)
                        }
                        .accessibilityLabel("Logical core \(index + 1)")
                        .accessibilityValue(CPUMetrics.formatPercent(usage))
                    }
                }
            }

            Divider().overlay(HerdrTheme.selection)
            VStack(alignment: .leading, spacing: 8) {
                MetricsSectionTitle(title: "TOP PROCESSES", detail: "CPU")
                ForEach(Array(metrics.topProcesses.sorted { $0.usage > $1.usage }.enumerated()), id: \.element.id) { index, process in
                    MetricsRankedRow(
                        rank: index + 1, name: process.name, detail: "",
                        value: metrics.totalUsagePercent(for: process).map(CPUMetrics.formatPercent) ?? "—",
                        color: accent)
                }
                Text(metrics.topProcesses.isEmpty ? "No active processes reported." : processUsageExplanation)
                    .font(HerdrTheme.mono(.caption2))
                    .foregroundStyle(HerdrTheme.subtext)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .metricsPopoverBody(width: MetricsPopoverMetrics.detailWidth)
    }

    private var processUsageExplanation: String {
        guard let coreCount = metrics.coreCount, coreCount > 0 else {
            return "CPU core count unavailable. Update the host service to show total CPU usage."
        }
        return "Share of total capacity across \(coreCount) logical \(coreCount == 1 ? "core" : "cores")."
    }
}

#Preview {
    CPUMetricsDetailView(metrics: HostMetricsModel().cpu)
}
