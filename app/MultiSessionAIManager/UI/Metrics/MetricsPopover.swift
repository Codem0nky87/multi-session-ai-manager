import SwiftUI
import UIKit
import Charts

/// Shared chrome for the metrics-bar popovers.
///
/// The detail views are fixed-width with unbounded height, which on a short
/// landscape window (e.g. an ultra-wide iPad) grows taller than the popover
/// area and gets clipped. This caps the content to a fraction of the screen
/// height and lets anything longer scroll instead of overflowing.
@MainActor enum MetricsPopoverMetrics {
    static let detailWidth: CGFloat = 360
    /// Fraction of the screen height a popover may occupy. Leaves room for the
    /// status bar, the metrics bar itself, and the popover arrow/margins.
    static let maxHeightFraction: CGFloat = 0.78
    static let minHeight: CGFloat = 240

    /// Height cap derived from the live screen, so a landscape ultra-wide gets
    /// a short cap and a portrait window a tall one. In any orientation the
    /// vertical extent is the shorter screen dimension.
    static var maxHeight: CGFloat {
        let vertical = min(UIScreen.main.bounds.height, UIScreen.main.bounds.width)
        return max(minHeight, vertical * maxHeightFraction)
    }
}

extension View {
    /// Wraps a metrics detail view in a width-fixed, screen-height-capped,
    /// scrollable popover body so long panels always fit on short windows.
    @MainActor func metricsPopoverBody(width: CGFloat) -> some View {
        ScrollView(.vertical) {
            self
                .frame(width: width)
                .background(HerdrTheme.background)
        }
        .frame(width: width)
        .frame(maxHeight: MetricsPopoverMetrics.maxHeight)
        .background(HerdrTheme.background)
    }
}

/// Shared visual vocabulary for the existing CPU, GPU, RAM and disk surfaces.
struct MetricsDetailHeader: View {
    let title: String
    let symbol: String
    let value: String
    let subtitle: String
    let color: Color
    var status: String? = nil
    var showsValue = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(color)
                Text(title)
                    .font(HerdrTheme.mono(.caption, weight: .bold))
                    .foregroundStyle(HerdrTheme.text)
                    .tracking(2)
                Spacer()
                if let status {
                    Text(status)
                        .font(HerdrTheme.mono(.caption2, weight: .semibold))
                        .foregroundStyle(color)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(color.opacity(0.12), in: Capsule())
                }
            }
            if showsValue {
                Text(value)
                    .font(.system(size: 46, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(HerdrTheme.text)
                    .contentTransition(.numericText())
            }
            Text(subtitle)
                .font(HerdrTheme.mono(.caption))
                .foregroundStyle(HerdrTheme.subtext)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MetricsHistoryView: View {
    let values: [Double]
    let color: Color
    var title: String = "RECENT UTILIZATION"

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            MetricsSectionTitle(title: title, detail: "\(values.count) samples")
            if values.count > 1 {
                Chart {
                    ForEach(Array(values.filter(\.isFinite).enumerated()), id: \.offset) { index, value in
                        AreaMark(x: .value("Sample", index), y: .value("Usage", value))
                            .foregroundStyle(LinearGradient(
                                colors: [color.opacity(0.25), color.opacity(0.01)],
                                startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Sample", index), y: .value("Usage", value))
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .frame(height: 64)
                .accessibilityLabel(title)
                .accessibilityValue(values.last.map(CPUMetrics.formatPercent) ?? "Unavailable")
            } else {
                Text("Collecting history…")
                    .font(HerdrTheme.mono(.caption))
                    .foregroundStyle(HerdrTheme.muted)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
            }
        }
    }
}

struct MetricsSectionTitle: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(HerdrTheme.mono(.caption2, weight: .bold))
                .tracking(1)
            Spacer()
            if let detail {
                Text(detail).font(HerdrTheme.mono(.caption2))
            }
        }
        .foregroundStyle(HerdrTheme.subtext)
    }
}

struct MetricsStat: View {
    let label: String
    let value: String
    var color: Color = HerdrTheme.text

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(HerdrTheme.mono(.caption2))
                .foregroundStyle(HerdrTheme.subtext)
            Text(value)
                .font(HerdrTheme.mono(.subheadline, weight: .semibold))
                .foregroundStyle(color)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

struct MetricsUsageTrack: View {
    let percent: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(HerdrTheme.selection.opacity(0.5))
                Capsule().fill(color.gradient)
                    .frame(width: geometry.size.width * (percent.isFinite ? min(100, max(0, percent)) / 100 : 0))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

struct MetricsRankedRow: View {
    let rank: Int
    let name: String
    let detail: String
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(String(format: "%02d", rank))
                .font(HerdrTheme.mono(.caption2, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(HerdrTheme.mono(.caption, weight: .semibold))
                    .foregroundStyle(HerdrTheme.text)
                    .lineLimit(2)
                if !detail.isEmpty {
                    Text(detail)
                        .font(HerdrTheme.mono(.caption2))
                        .foregroundStyle(HerdrTheme.subtext)
                }
            }
            Spacer(minLength: 8)
            Text(value)
                .font(HerdrTheme.mono(.caption, weight: .bold))
                .foregroundStyle(HerdrTheme.text)
                .monospacedDigit()
                .fixedSize()
        }
        .padding(.vertical, 5)
    }
}
