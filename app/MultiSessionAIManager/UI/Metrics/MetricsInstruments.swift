import SwiftUI

/// The liquid moves only while visible and active; the fill always represents data.
struct MetricsLiquidGauge: View {
    let percent: Double?
    let color: Color
    var symbol = "internaldrive"
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var fraction: Double {
        guard let percent, percent.isFinite else { return 0 }
        return min(1, max(0, percent / 100))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20,
                                paused: reduceMotion || scenePhase != .active || fraction == 0 || fraction == 1)) { timeline in
            let phase = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                RoundedRectangle(cornerRadius: compact ? 9 : 18)
                    .fill(HerdrTheme.background)
                Canvas { context, size in
                    let level = size.height * (1 - fraction)
                    let amplitude = fraction > 0 && fraction < 1 ? min(3.0, size.height * 0.025) : 0
                    for layer in 0..<2 {
                        var wave = Path()
                        wave.move(to: CGPoint(x: 0, y: size.height))
                        for x in stride(from: 0.0, through: Double(size.width) + 2, by: 2) {
                            let angle = x / size.width * .pi * 2 + phase * (layer == 0 ? 1.3 : -1.0)
                            wave.addLine(to: CGPoint(x: x, y: level + sin(angle) * amplitude))
                        }
                        wave.addLine(to: CGPoint(x: size.width, y: size.height))
                        wave.closeSubpath()
                        context.fill(wave, with: .linearGradient(
                            Gradient(colors: [color.opacity(layer == 0 ? 0.3 : 0.65), color.opacity(0.15)]),
                            startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                    }
                    // Etched capacity marks make the container readable at a glance.
                    for tick in 1..<4 {
                        let y = size.height * Double(tick) / 4
                        var mark = Path()
                        mark.move(to: CGPoint(x: 5, y: y))
                        mark.addLine(to: CGPoint(x: compact ? 9 : 13, y: y))
                        context.stroke(mark, with: .color(HerdrTheme.text.opacity(0.3)), lineWidth: 1)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: compact ? 9 : 18))
                VStack(spacing: compact ? 4 : 10) {
                    Image(systemName: symbol)
                        .font(.system(size: compact ? 14 : 23, weight: .medium))
                        .foregroundStyle(color)
                    Text(percent.map(CPUMetrics.formatPercent) ?? "—")
                        .font(.system(size: compact ? 12 : 24, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(HerdrTheme.text)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 9 : 18)
                    .strokeBorder(color.opacity(0.35), lineWidth: 1)
            }
        }
        .frame(width: compact ? 52 : 98, height: compact ? 64 : 116)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Used capacity")
        .accessibilityValue(percent.map(CPUMetrics.formatPercent) ?? "Unavailable")
    }
}

/// A bounded dial is suited to CPU/GPU load; the adjacent history shows bursts.
struct MetricsLoadGauge: View {
    let percent: Double?
    let color: Color
    let symbol: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fraction: Double {
        guard let percent, percent.isFinite else { return 0 }
        return min(1, max(0, percent / 100))
    }

    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.75)
                .stroke(HerdrTheme.selection, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle().trim(from: 0, to: fraction * 0.75)
                .stroke(AngularGradient(colors: [color.opacity(0.35), color], center: .center,
                                        startAngle: .degrees(135), endAngle: .degrees(405)),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(135))
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.7), value: fraction)
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.title3).foregroundStyle(color)
                Text(percent.map(CPUMetrics.formatPercent) ?? "—")
                    .font(.system(size: 23, weight: .semibold, design: .rounded))
                    .foregroundStyle(HerdrTheme.text)
                    .monospacedDigit()
            }
            Text("LOAD")
                .font(HerdrTheme.mono(.caption2, weight: .bold))
                .foregroundStyle(HerdrTheme.subtext)
                .offset(y: 45)
        }
        .padding(6)
        .frame(width: 110, height: 116)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Utilization")
        .accessibilityValue(percent.map(CPUMetrics.formatPercent) ?? "Unavailable")
    }
}

struct MetricsCoreHeatmap: View {
    let cores: [Double]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func tint(_ usage: Double) -> Color {
        guard usage.isFinite else { return HerdrTheme.muted }
        if usage >= 85 { return .red }
        if usage >= 60 { return .orange }
        if usage >= 30 { return HerdrTheme.accent }
        return HerdrTheme.teal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            MetricsSectionTitle(title: "LOGICAL CORE MAP", detail: "\(cores.count) cores")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 48), spacing: 6)], spacing: 6) {
                ForEach(Array(cores.enumerated()), id: \.offset) { index, usage in
                    VStack(spacing: 5) {
                        Text(String(format: "%02d", index + 1))
                            .font(HerdrTheme.mono(.caption2))
                            .foregroundStyle(HerdrTheme.subtext)
                        Text(CPUMetrics.formatPercent(usage))
                            .font(HerdrTheme.mono(.caption2, weight: .bold))
                            .foregroundStyle(HerdrTheme.text)
                    }
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(tint(usage).opacity(usage.isFinite ? 0.08 + min(100, max(0, usage)) / 250 : 0.08),
                                in: RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5).strokeBorder(tint(usage).opacity(0.5), lineWidth: 1)
                    }
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.5), value: usage)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Logical core \(index + 1)")
                    .accessibilityValue(CPUMetrics.formatPercent(usage))
                }
            }
            .padding(12)
            .background(HerdrTheme.panel, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14).strokeBorder(HerdrTheme.selection, lineWidth: 1)
            }
            HStack(spacing: 6) {
                Text("IDLE")
                LinearGradient(colors: [HerdrTheme.teal, HerdrTheme.accent, .orange, .red],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 4).clipShape(Capsule())
                Text("BUSY")
            }
            .font(HerdrTheme.mono(.caption2))
            .foregroundStyle(HerdrTheme.subtext)
            Text("Logical activity · diagram does not represent physical die layout.")
                .font(HerdrTheme.mono(.caption2))
                .foregroundStyle(HerdrTheme.muted)
        }
    }
}

/// Flow direction and speed are visible without inventing a link-capacity percentage.
struct MetricsNetworkFlow: View {
    let speed: Double
    let peak: Double
    let color: Color
    let incoming: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20,
                                paused: reduceMotion || scenePhase != .active || speed <= 0)) { timeline in
            Canvas { context, size in
                let y = size.height / 2
                var track = Path()
                track.move(to: CGPoint(x: 0, y: y))
                track.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(track, with: .color(color.opacity(0.15)), lineWidth: 4)
                guard speed.isFinite, speed > 0 else { return }
                let intensity = min(1, max(0, speed / max(1, peak)))
                let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate * (0.15 + intensity * 0.55)
                for index in 0..<5 {
                    let progress = (time + Double(index) / 5).truncatingRemainder(dividingBy: 1)
                    let x = size.width * (incoming ? progress : 1 - progress)
                    let dot = CGRect(x: x - 3, y: y - 3, width: 6, height: 6)
                    context.fill(Path(ellipseIn: dot), with: .color(color.opacity(0.5 + intensity * 0.5)))
                }
            }
        }
        .frame(height: 24)
        .accessibilityHidden(true)
    }
}
