import SwiftUI

struct MemoryMetricsDetailView: View {
    var metrics: MemoryMetrics
    var history: [Double] = []
    private let accent = HerdrTheme.teal

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MetricsDetailHeader(
                title: "MEMORY", symbol: "memorychip",
                value: CPUMetrics.formatPercent(metrics.usagePercent),
                subtitle: String(format: "%.1f GiB used of %.1f GiB", metrics.used, metrics.total),
                color: accent, showsValue: false)
            HStack(spacing: 16) {
                MetricsLiquidGauge(percent: metrics.total > 0 ? metrics.usagePercent : nil,
                                   color: accent, symbol: "memorychip")
                MetricsHistoryView(values: history, color: accent, title: "RECENT USAGE")
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                MetricsStat(label: "Available", value: gib(metrics.available ?? metrics.free), color: accent)
                MetricsStat(label: "Free", value: gib(metrics.free))
                MetricsStat(label: "App / anonymous", value: gib(metrics.app))
                if let cache = metrics.cache {
                    MetricsStat(label: "Cache", value: gib(cache))
                }
                if metrics.wired > 0 {
                    MetricsStat(label: "Wired", value: gib(metrics.wired))
                }
                if metrics.compressed > 0 {
                    MetricsStat(label: "Compressed", value: gib(metrics.compressed))
                }
                MetricsStat(label: "Swap used", value: gib(metrics.swap))
            }

            Divider().overlay(HerdrTheme.selection)
            VStack(alignment: .leading, spacing: 8) {
                MetricsSectionTitle(title: "TOP PROCESSES", detail: "Resident memory")
                if let processes = metrics.topProcesses {
                    ForEach(Array(processes.sorted { $0.rssBytes > $1.rssBytes }.enumerated()), id: \.element.id) { index, process in
                        MetricsRankedRow(
                            rank: index + 1, name: process.name, detail: "PID \(process.pid)",
                            value: rss(process.rssBytes), color: accent)
                    }
                    Text(processes.isEmpty ? "No readable process memory reported." : "RSS includes shared resident pages.")
                        .font(HerdrTheme.mono(.caption2))
                        .foregroundStyle(HerdrTheme.subtext)
                } else {
                    Text("Process memory unavailable from this host service.")
                        .font(HerdrTheme.mono(.caption))
                        .foregroundStyle(HerdrTheme.subtext)
                }
            }
        }
        .padding(20)
        .metricsPopoverBody(width: MetricsPopoverMetrics.detailWidth)
    }

    private func gib(_ value: Double) -> String { String(format: "%.1f GiB", value) }

    private func rss(_ bytes: Double) -> String {
        bytes >= 1_073_741_824
            ? String(format: "%.2f GiB", bytes / 1_073_741_824)
            : String(format: "%.1f MiB", bytes / 1_048_576)
    }
}
