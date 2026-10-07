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
            
            HStack(spacing: 24) {
                CircularGaugeView(value: metrics.usagePercent, max: 100, title: "\(Int(metrics.usagePercent))%", color: .blue)
                    .scaleEffect(1.2)
            }
            .padding(.bottom, 16)
            
            Divider().background(HerdrTheme.selection)
            Text("DETAILS")
                .font(HerdrTheme.mono(.caption, weight: .bold))
                .foregroundStyle(HerdrTheme.subtext)
            
            VStack(spacing: 8) {
                HStack {
                    Text("Used:")
                    Spacer()
                    Text(String(format: "%.2f GB", metrics.used)).bold()
                }
                .font(HerdrTheme.mono(.subheadline))
                

                GeometryReader { geo in
                    let safeTotal = metrics.total > 0 ? metrics.total : 1
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(HerdrTheme.panel)
                            
                        HStack(spacing: 0) {
                            if metrics.available == nil && (metrics.app > 0 || metrics.wired > 0 || metrics.compressed > 0) {
                                Rectangle().fill(.blue).frame(width: geo.size.width * (metrics.app / safeTotal))
                                Rectangle().fill(.orange).frame(width: geo.size.width * (metrics.wired / safeTotal))
                                Rectangle().fill(.red).frame(width: geo.size.width * (metrics.compressed / safeTotal))
                            } else {
                                Rectangle().fill(.blue).frame(width: geo.size.width * (metrics.used / safeTotal))
                            }
                        }
                        .frame(height: 8)
                        .clipShape(Capsule())
                    }
                }
                .frame(height: 8)
                .padding(.vertical, 4)
                
                if metrics.app > 0 { detailRow(label: "App:", value: String(format: "%.2f GB", metrics.app), color: .blue) }
                if metrics.wired > 0 { detailRow(label: "Wired:", value: String(format: "%.2f GB", metrics.wired), color: .orange) }
                if metrics.compressed > 0 { detailRow(label: "Compressed:", value: String(format: "%.2f GB", metrics.compressed), color: .red) }
                detailRow(label: "Free:", value: String(format: "%.2f GB", metrics.free), color: .gray.opacity(0.3))
                if let available = metrics.available {
                    detailRow(label: "Available:", value: String(format: "%.2f GB", available), color: .clear)
                }
                if let cache = metrics.cache {
                    detailRow(label: "Cache:", value: String(format: "%.2f GB", cache), color: .clear)
                }
                if metrics.swap > 0 { detailRow(label: "Swap:", value: String(format: "%.2f GB", metrics.swap), color: .clear) }
            }
        }
        .padding()
        .frame(width: 320)
        .background(HerdrTheme.background)
    }
    
    private func detailRow(label: String, value: String, color: Color) -> some View {
        HStack {
            if color != .clear {
                Circle().fill(color).frame(width: 8, height: 8)
            } else {
                Spacer().frame(width: 8)
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
    
    private func processRow(name: String, usage: String) -> some View {
        HStack {
            Image(systemName: "square.fill").foregroundStyle(HerdrTheme.subtext).font(.system(size: 10))
            Text(name).font(HerdrTheme.mono(.subheadline)).foregroundStyle(HerdrTheme.text)
            Spacer()
            Text(usage).font(HerdrTheme.mono(.subheadline, weight: .bold)).foregroundStyle(HerdrTheme.text)
        }
    }
}
