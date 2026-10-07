import SwiftUI
import Charts

struct CircularGaugeView: View {
    let value: Double
    let max: Double
    let title: String
    let color: Color
    
    var body: some View {
        VStack {
            ZStack {
                Circle()
                    .stroke(HerdrTheme.panel, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: CGFloat(Swift.min(1, Swift.max(0, value / Swift.max(1, max)))))
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(title)
                    .font(HerdrTheme.mono(.subheadline, weight: .semibold))
                    .foregroundStyle(HerdrTheme.text)
            }
            .frame(width: 64, height: 64)
        }
    }
}

struct CPUMetricsDetailView: View {
    var metrics: CPUMetrics
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(HerdrTheme.subtext)
                Spacer()
                Text("CPU")
                    .font(.headline)
                    .foregroundStyle(HerdrTheme.text)
                Spacer()
                Image(systemName: "command")
                    .foregroundStyle(HerdrTheme.subtext)
            }
            .padding(.bottom, 8)
            
            // Gauges
            HStack(spacing: 24) {
                CircularGaugeView(value: metrics.temperature, max: 100, title: "\(Int(metrics.temperature))°C", color: .blue)
                CircularGaugeView(value: metrics.utilization, max: 100, title: metrics.utilizationText, color: .blue)
                    .scaleEffect(1.2) // Make the center one slightly larger
                if let coreCount = metrics.coreCount, coreCount > 0 {
                    CircularGaugeView(value: metrics.loadAverage1m, max: Double(coreCount), title: String(format: "%.2f", metrics.loadAverage1m), color: .blue)
                }
            }
            .padding(.bottom, 8)
            
            Divider().background(HerdrTheme.selection)
            Text("USAGE HISTORY")
                .font(HerdrTheme.mono(.caption, weight: .bold))
                .foregroundStyle(HerdrTheme.subtext)
            
            // History Graph
            Chart {
                ForEach(Array(metrics.history.enumerated()), id: \.offset) { index, value in
                    LineMark(
                        x: .value("Time", index),
                        y: .value("Usage", value)
                    )
                    .foregroundStyle(.blue.gradient)
                    .interpolationMethod(.monotone)
                    
                    AreaMark(
                        x: .value("Time", index),
                        y: .value("Usage", value)
                    )
                    .foregroundStyle(LinearGradient(gradient: Gradient(colors: [.blue.opacity(0.4), .blue.opacity(0.0)]), startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .frame(height: 80)
            
            Divider().background(HerdrTheme.selection)
            Text("DETAILS")
                .font(HerdrTheme.mono(.caption, weight: .bold))
                .foregroundStyle(HerdrTheme.subtext)
            
            // Details List
            VStack(spacing: 8) {
                detailRow(label: "System:", value: CPUMetrics.formatPercent(metrics.systemUsage), color: .red)
                detailRow(label: "User:", value: CPUMetrics.formatPercent(metrics.userUsage), color: .blue)
                detailRow(label: "Idle:", value: CPUMetrics.formatPercent(metrics.idleUsage), color: .gray)
                if metrics.efficiencyCoreUsage > 0 || metrics.performanceCoreUsage > 0 { detailRow(label: "Efficiency cores:", value: CPUMetrics.formatPercent(metrics.efficiencyCoreUsage), color: .cyan) }
                if metrics.efficiencyCoreUsage > 0 || metrics.performanceCoreUsage > 0 { detailRow(label: "Performance cores:", value: CPUMetrics.formatPercent(metrics.performanceCoreUsage), color: .indigo) }
                
                HStack {
                    Text("Uptime:")
                        .font(HerdrTheme.mono(.subheadline))
                        .foregroundStyle(HerdrTheme.text)
                    Spacer()
                    Text(metrics.uptime)
                        .font(HerdrTheme.mono(.subheadline))
                        .foregroundStyle(HerdrTheme.text)
                }
            }
            
            Divider().background(HerdrTheme.selection)
            Text("AVERAGE LOAD")
                .font(HerdrTheme.mono(.caption, weight: .bold))
                .foregroundStyle(HerdrTheme.subtext)
            
            VStack(spacing: 8) {
                detailRow(label: "1 minute:", value: String(format: "%.2f", metrics.loadAverage1m))
                detailRow(label: "5 minutes:", value: String(format: "%.2f", metrics.loadAverage5m))
                detailRow(label: "15 minutes:", value: String(format: "%.2f", metrics.loadAverage15m))
                if let coreCount = metrics.coreCount, coreCount > 0 {
                    detailRow(label: "Logical cores:", value: String(coreCount))
                }
                if let loadPerCore = metrics.loadPerCore {
                    detailRow(label: "Load per core:", value: String(format: "%.2f", loadPerCore))
                }
            }
            
            Divider().background(HerdrTheme.selection)
            Text("TOP PROCESSES")
                .font(HerdrTheme.mono(.caption, weight: .bold))
                .foregroundStyle(HerdrTheme.subtext)
            
            VStack(spacing: 8) {
                HStack {
                    Text("Process")
                        .font(HerdrTheme.mono(.caption, weight: .bold))
                        .foregroundStyle(HerdrTheme.subtext)
                    Spacer()
                    Text("CPU usage")
                        .font(HerdrTheme.mono(.caption, weight: .bold))
                        .foregroundStyle(HerdrTheme.subtext)
                }
                
                ForEach(metrics.topProcesses) { process in
                    HStack {
                        Image(systemName: "square.fill")
                            .foregroundStyle(HerdrTheme.subtext)
                            .font(.system(size: 10))
                        Text(process.name)
                            .font(HerdrTheme.mono(.subheadline))
                            .foregroundStyle(HerdrTheme.text)
                        Spacer()
                        Text(metrics.totalUsagePercent(for: process).map(CPUMetrics.formatPercent) ?? "—")
                            .font(HerdrTheme.mono(.subheadline, weight: .bold))
                            .foregroundStyle(HerdrTheme.text)
                    }
                }

                Text(processUsageExplanation)
                    .font(HerdrTheme.mono(.caption))
                    .foregroundStyle(HerdrTheme.subtext)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(width: 320)
        .background(HerdrTheme.background)
    }

    private var processUsageExplanation: String {
        guard let coreCount = metrics.coreCount, coreCount > 0 else {
            return "CPU core count unavailable. Update the host service to show total CPU usage."
        }
        return "Percentage of total CPU capacity (\(coreCount) logical \(coreCount == 1 ? "core" : "cores"))."
    }
    
    private func detailRow(label: String, value: String, color: Color? = nil) -> some View {
        HStack {
            if let color = color {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(label)
                .font(HerdrTheme.mono(.subheadline))
                .foregroundStyle(HerdrTheme.text)
            Spacer()
            Text(value)
                .font(HerdrTheme.mono(.subheadline, weight: .semibold))
                .foregroundStyle(HerdrTheme.text)
        }
    }
}

#Preview {
    CPUMetricsDetailView(metrics: HostMetricsModel().cpu)
}
