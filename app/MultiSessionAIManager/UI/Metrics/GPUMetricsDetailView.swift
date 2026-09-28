import SwiftUI

struct GPUMetricsDetailView: View {
    var metrics: GPUMetrics
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(HerdrTheme.subtext)
                Spacer()
                Text("GPU")
                    .font(.headline)
                    .foregroundStyle(HerdrTheme.text)
                Spacer()
                Image(systemName: "command")
                    .foregroundStyle(HerdrTheme.subtext)
            }
            .padding(.bottom, 8)
            
            HStack(spacing: 24) {
                if metrics.temperature > 0 {
                    CircularGaugeView(value: metrics.temperature, max: 100, title: "\(Int(metrics.temperature))°C", color: .blue)
                }
                
                CircularGaugeView(value: metrics.usagePercent, max: 100, title: "\(Int(metrics.usagePercent))%", color: .blue)
                    .scaleEffect(1.2)
                    
                if metrics.memoryTotal > 0 {
                    let memPercent = (metrics.memoryUsed / metrics.memoryTotal) * 100.0
                    CircularGaugeView(value: memPercent, max: 100, title: "\(Int(memPercent))%", color: .blue)
                }
            }
            .padding(.bottom, 16)
            
            Divider().background(HerdrTheme.selection)
            Text("DETAILS")
                .font(HerdrTheme.mono(.caption, weight: .bold))
                .foregroundStyle(HerdrTheme.subtext)
            
            VStack(spacing: 8) {
                detailRow(label: "Model:", value: metrics.modelName.isEmpty ? "Unknown" : metrics.modelName)
                if metrics.cores > 0 {
                    detailRow(label: "Cores:", value: "\(metrics.cores)")
                }
                detailRow(label: "Utilization:", value: "\(Int(metrics.usagePercent))%")
                if metrics.memoryTotal > 0 {
                    detailRow(label: "VRAM Used:", value: String(format: "%.1f / %.1f GB", metrics.memoryUsed / 1024.0, metrics.memoryTotal / 1024.0))
                }
            }
        }
        .padding()
        .frame(width: 320)
        .background(HerdrTheme.background)
    }
    
    private func detailRow(label: String, value: String) -> some View {
        HStack {
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

