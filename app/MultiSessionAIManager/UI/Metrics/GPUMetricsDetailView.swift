import SwiftUI

struct GPUMetricsDetailView: View {
    var metrics: GPUMetrics
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "cpu")
                    .foregroundStyle(HerdrTheme.subtext)
                Spacer()
                Text("GPU")
                    .font(.headline)
                    .foregroundStyle(HerdrTheme.text)
                Spacer()
                Image(systemName: "display")
                    .foregroundStyle(HerdrTheme.subtext)
            }
            .padding(.bottom, 8)
            
            CircularGaugeView(value: metrics.usagePercent, max: 100, title: "\(Int(metrics.usagePercent))%", color: .purple)
                .scaleEffect(1.2)
                .padding(.bottom, 16)
        }
        .padding()
        .frame(width: 200)
        .background(HerdrTheme.background)
    }
}
