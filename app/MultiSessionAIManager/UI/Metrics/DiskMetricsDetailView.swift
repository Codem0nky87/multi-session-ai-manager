import SwiftUI

struct DiskMetricsDetailView: View {
    var metrics: DiskMetrics
    
    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                Image(systemName: "internaldrive.fill")
                    .foregroundStyle(HerdrTheme.subtext)
                Spacer()
                Text("STORAGE")
                    .font(.headline)
                    .foregroundStyle(HerdrTheme.text)
                Spacer()
                Image(systemName: "externaldrive")
                    .foregroundStyle(HerdrTheme.subtext)
            }
            .padding(.bottom, 8)
            
            HStack(spacing: 24) {
                CircularGaugeView(value: metrics.usagePercent, max: 100, title: "\(Int(metrics.usagePercent))%", color: .blue)
                    .scaleEffect(1.2)
            }
            .padding(.bottom, 16)
            
            Divider().background(HerdrTheme.selection)
            Text("DISKS & VOLUMES")
                .font(HerdrTheme.mono(.caption, weight: .bold))
                .foregroundStyle(HerdrTheme.subtext)
            
            ScrollView {
                VStack(spacing: 16) {
                    ForEach(metrics.disks) { disk in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(disk.model)
                                .font(HerdrTheme.mono(.subheadline, weight: .bold))
                                .foregroundStyle(HerdrTheme.text)
                            
                            ForEach(disk.volumes) { volume in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Text(volume.name.isEmpty ? volume.mountPoint : volume.name)
                                            .font(HerdrTheme.mono(.caption, weight: .semibold))
                                            .foregroundStyle(HerdrTheme.text)
                                        Spacer()
                                        Text(String(format: "%.1f / %.1f GB", volume.usedGB, volume.totalGB))
                                            .font(HerdrTheme.mono(.caption2))
                                            .foregroundStyle(HerdrTheme.subtext)
                                    }
                                    
                                    GeometryReader { geo in
                                        ZStack(alignment: .leading) {
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(HerdrTheme.panel)
                                            
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(Color.blue)
                                                .frame(width: max(0, min(1, volume.usedGB / max(volume.totalGB, 1))) * geo.size.width)
                                        }
                                    }
                                    .frame(height: 8)
                                }
                                .padding(.leading, 12)
                                .padding(.top, 4)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                }
            }
            .frame(maxHeight: 250)
        }
        .padding()
        .frame(width: 340)
        .background(HerdrTheme.background)
    }
}
