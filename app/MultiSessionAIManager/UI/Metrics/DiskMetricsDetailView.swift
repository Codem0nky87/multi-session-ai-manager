import SwiftUI

/// Compact circular gauge for per-disk temperatures; smaller than the main
/// `CircularGaugeView` so several fit beside the disk list.
struct DiskTemperatureGaugeView: View {
    let temperature: Double?

    var body: some View {
        ZStack {
            Circle()
                .stroke(HerdrTheme.panel, lineWidth: 5)
            if let temperature {
                Circle()
                    .trim(from: 0, to: CGFloat(Swift.min(1, Swift.max(0, temperature / 80))))
                    .stroke(DiskMetrics.temperatureColor(temperature),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                if let temperature {
                    Text("\(Int(temperature))°")
                        .font(HerdrTheme.mono(.caption2, weight: .bold))
                        .foregroundStyle(DiskMetrics.temperatureColor(temperature))
                } else {
                    Image(systemName: "thermometer")
                        .font(.system(size: 11))
                        .foregroundStyle(HerdrTheme.muted)
                }
            }
        }
        .frame(width: 44, height: 44)
        .accessibilityLabel(temperature.map { "Disk temperature \(Int($0)) degrees Celsius" } ?? "Disk temperature unavailable")
    }
}

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
                if let hottest = metrics.hottestTemperature {
                    // At-a-glance worst case across all physical disks.
                    HStack(spacing: 3) {
                        Image(systemName: "thermometer.medium")
                            .font(.system(size: 10))
                        Text("\(Int(hottest))°C")
                            .font(HerdrTheme.mono(.caption, weight: .bold))
                    }
                    .foregroundStyle(DiskMetrics.temperatureColor(hottest))
                } else {
                    Image(systemName: "externaldrive")
                        .foregroundStyle(HerdrTheme.subtext)
                }
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

            VStack(spacing: 16) {
                ForEach(metrics.disks) { disk in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            Text(disk.model)
                                .font(HerdrTheme.mono(.subheadline, weight: .bold))
                                .foregroundStyle(HerdrTheme.text)
                                .lineLimit(1)
                            Spacer()
                            DiskTemperatureGaugeView(temperature: disk.temperature)
                        }

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
        .padding()
        .frame(width: 340)
        .background(HerdrTheme.background)
    }
}

#Preview {
    DiskMetricsDetailView(metrics: DiskMetrics(disks: [
        PhysicalDisk(id: "nvme0", model: "Samsung 990 PRO", volumes: [
            DiskVolume(id: "/dev/nvme0n1p1", name: "Root", mountPoint: "/", totalGB: 931, usedGB: 412)
        ], temperature: 38),
        PhysicalDisk(id: "sda", model: "WDC WD40EFRX", volumes: [
            DiskVolume(id: "/dev/sda1", name: "data", mountPoint: "/data", totalGB: 3726, usedGB: 2900)
        ], temperature: 52),
    ]))
}
