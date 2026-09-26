import SwiftUI

struct NetworkMetricsDetailView: View {
    var metrics: NetworkMetrics
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "network")
                    .foregroundStyle(HerdrTheme.subtext)
                Spacer()
                Text("Network")
                    .font(.headline)
                    .foregroundStyle(HerdrTheme.text)
                Spacer()
                Image(systemName: "arrow.up.arrow.down")
                    .foregroundStyle(HerdrTheme.subtext)
            }
            .padding(.bottom, 8)
            
            HStack(spacing: 24) {
                VStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                        .font(.title)
                    Text(metrics.downloadString)
                        .font(HerdrTheme.mono(.subheadline, weight: .semibold))
                }
                
                VStack {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(.red)
                        .font(.title)
                    Text(metrics.uploadString)
                        .font(HerdrTheme.mono(.subheadline, weight: .semibold))
                }
            }
            .padding(.bottom, 16)
        }
        .padding()
        .frame(width: 240)
        .background(HerdrTheme.background)
    }
}
