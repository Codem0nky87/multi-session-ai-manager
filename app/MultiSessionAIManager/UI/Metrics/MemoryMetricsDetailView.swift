import SwiftUI
import Charts

struct MemoryMetricsDetailView: View {
    var metrics: MemoryMetrics
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "memorychip")
                    .foregroundStyle(HerdrTheme.subtext)
                Spacer()
                Text("RAM")
                    .font(.headline)
                    .foregroundStyle(HerdrTheme.text)
                Spacer()
                Image(systemName: "chart.pie.fill")
                    .foregroundStyle(HerdrTheme.subtext)
            }
            .padding(.bottom, 8)
            
            CircularGaugeView(value: metrics.usagePercent, max: 100, title: "\(Int(metrics.usagePercent))%", color: .green)
                .scaleEffect(1.2)
                .padding(.bottom, 16)
        }
        .padding()
        .frame(width: 200)
        .background(HerdrTheme.background)
    }
}
