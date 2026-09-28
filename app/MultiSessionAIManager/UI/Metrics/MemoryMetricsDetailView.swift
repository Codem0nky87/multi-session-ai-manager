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
            
            HStack(spacing: 32) {
                // Real pressure gauge
                VStack {
                    ZStack {
                        Circle()
                            .trim(from: 0.5, to: 1.0)
                            .stroke(HerdrTheme.panel, lineWidth: 8)
                        Circle()
                            .trim(from: 0.5, to: 0.5 + (metrics.usagePercent / 100.0) * 0.5)
                            .stroke(metrics.usagePercent > 80 ? Color.red : (metrics.usagePercent > 60 ? Color.orange : Color.green), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                        
                        Text(metrics.usagePercent > 80 ? "Critical" : (metrics.usagePercent > 60 ? "Warning" : "Normal"))
                            .font(HerdrTheme.mono(.caption2, weight: .bold))
                            .foregroundStyle(metrics.usagePercent > 80 ? Color.red : (metrics.usagePercent > 60 ? Color.orange : Color.green))
                            .rotationEffect(.degrees(180))
                            .offset(y: -16)
                    }
                    .frame(width: 64, height: 64)
                    .rotationEffect(.degrees(180))
                }
                
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
                    HStack(spacing: 0) {
                        let totalShown = metrics.app + metrics.wired + metrics.compressed > 0 ? (metrics.app + metrics.wired + metrics.compressed) : metrics.used
                        let usedRatio = totalShown > 0 ? metrics.used / totalShown : 1.0
                        
                        if metrics.app > 0 || metrics.wired > 0 || metrics.compressed > 0 {
                            Rectangle().fill(.blue).frame(width: geo.size.width * (metrics.app / totalShown) * (metrics.used / metrics.total))
                            Rectangle().fill(.orange).frame(width: geo.size.width * (metrics.wired / totalShown) * (metrics.used / metrics.total))
                            Rectangle().fill(.red).frame(width: geo.size.width * (metrics.compressed / totalShown) * (metrics.used / metrics.total))
                        } else {
                            Rectangle().fill(.blue).frame(width: geo.size.width * (metrics.used / (metrics.total > 0 ? metrics.total : 1)))
                        }
                    }
                    .frame(height: 8)
                    .clipShape(Capsule())
                }

                .frame(height: 8)
                .padding(.vertical, 4)
                
                if metrics.app > 0 { detailRow(label: "App:", value: String(format: "%.2f GB", metrics.app), color: .blue) }
                if metrics.wired > 0 { detailRow(label: "Wired:", value: String(format: "%.2f GB", metrics.wired), color: .orange) }
                if metrics.compressed > 0 { detailRow(label: "Compressed:", value: String(format: "%.2f GB", metrics.compressed), color: .red) }
                detailRow(label: "Free:", value: String(format: "%.2f GB", metrics.free), color: .gray.opacity(0.3))
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

