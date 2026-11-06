import SwiftUI

struct PowerMetricsDetailView: View {
    var metrics: PowerMetrics
    var history: [Double] = []
    @State private var showingPsuInfo = false
    private let accent = Color.yellow

    static var psuInfoTitle: String { PowerMetricsPsuInfoView.title }
    static var psuInfoFormula: String { PowerMetricsPsuInfoView.formula }
    static var psuInfoExplanation: String { PowerMetricsPsuInfoView.explanation }

    var psuCeiling: Double {
        metrics.effectivePsuWatts
    }

    var peakWatts: Double? {
        let finiteHistory = history.filter(\.isFinite)
        let candidates = finiteHistory + [metrics.totalWatts].compactMap { $0?.isFinite == true ? $0 : nil }
        guard let maxVal = candidates.max(), maxVal > 0 else { return nil }
        return maxVal
    }

    var powerPercent: Double? {
        guard let total = metrics.totalWatts, total.isFinite, total >= 0 else { return nil }
        return min(100.0, max(0.0, (total / psuCeiling) * 100.0))
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
                showsValue: true
            )

            HStack(spacing: 16) {
                MetricsLiquidGauge(
                    percent: powerPercent,
                    color: accent,
                    symbol: "bolt.fill",
                    displayValue: metrics.formattedTotalWatts,
                    caption: "of " + PowerMetrics.formatWatts(psuCeiling)
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
                if let cpuTdp = metrics.cpuTdpWatts {
                    MetricsStat(
                        label: "CPU TDP",
                        value: PowerMetrics.formatWatts(cpuTdp)
                    )
                }
                if let gpuTdp = metrics.gpuTdpWatts {
                    MetricsStat(
                        label: "GPU TDP",
                        value: PowerMetrics.formatWatts(gpuTdp)
                    )
                }
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Text("PSU capacity")
                            .font(HerdrTheme.mono(.caption2))
                            .foregroundStyle(HerdrTheme.subtext)
                        Button {
                            showingPsuInfo = true
                        } label: {
                            Image(systemName: "info.circle")
                                .font(HerdrTheme.mono(.caption2))
                                .foregroundStyle(HerdrTheme.subtext)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Recommended PSU info")
                        .popover(isPresented: $showingPsuInfo) {
                            PowerMetricsPsuInfoView()
                        }
                    }
                    Text(PowerMetrics.formatWatts(psuCeiling))
                        .font(HerdrTheme.mono(.subheadline, weight: .semibold))
                        .foregroundStyle(HerdrTheme.text)
                        .monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
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

struct PowerMetricsPsuInfoView: View {
    static let title = "Recommended PSU Capacity"
    static let formula = "(CPU TDP + GPU TDP + 80W) × 1.4"
    static let explanation = "Because standard power supplies do not expose digital sensors over system buses, this capacity ceiling is estimated as:\n(CPU TDP + GPU TDP + 80W) × 1.4\nrounded up to standard PSU sizes (e.g. 650W, 750W, 850W, 1000W) to accommodate transient spikes and motherboard/drive draw."

    private let accent = Color.yellow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .foregroundStyle(accent)
                Text(Self.title)
                    .font(HerdrTheme.mono(.caption, weight: .bold))
                    .foregroundStyle(HerdrTheme.text)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("ESTIMATED CEILING")
                    .font(HerdrTheme.mono(.caption2, weight: .bold))
                    .foregroundStyle(HerdrTheme.subtext)
                    .tracking(1)
                Text(Self.formula)
                    .font(HerdrTheme.mono(.caption, weight: .semibold))
                    .foregroundStyle(accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(HerdrTheme.panel, in: RoundedRectangle(cornerRadius: 6))
            }

            Text(Self.explanation)
                .font(HerdrTheme.mono(.caption2))
                .foregroundStyle(HerdrTheme.subtext)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 280)
        .background(HerdrTheme.background)
        .presentationCompactAdaptation(.popover)
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
