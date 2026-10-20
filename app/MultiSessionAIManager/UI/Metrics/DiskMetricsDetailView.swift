import SwiftUI

struct DiskMetricsDetailView: View {
    var metrics: DiskMetrics
    var volumeHistory: [String: [Double]] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MetricsDetailHeader(
                title: "STORAGE", symbol: "internaldrive",
                value: CPUMetrics.formatPercent(metrics.displayUsagePercent),
                subtitle: primaryDescription, color: metrics.pressure.color,
                status: metrics.pressure.label)
            if !metrics.deviceTemperatures.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    MetricsSectionTitle(title: "DEVICE TEMPERATURES")
                    ForEach(metrics.deviceTemperatures) { device in
                        HStack(spacing: 12) {
                            Image(systemName: "internaldrive")
                                .foregroundStyle(HerdrTheme.subtext)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.model)
                                    .font(HerdrTheme.mono(.caption, weight: .semibold))
                                    .foregroundStyle(HerdrTheme.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(device.id)
                                    .font(HerdrTheme.mono(.caption2))
                                    .foregroundStyle(HerdrTheme.subtext)
                            }
                            Spacer(minLength: 4)
                            Text(String(format: "%.0f°C", device.temperature))
                                .font(HerdrTheme.mono(.subheadline, weight: .bold))
                                .foregroundStyle(DiskMetrics.temperatureColor(device.temperature))
                                .fixedSize()
                        }
                    }
                }
            }

            if let volume = metrics.worstVolume {
                MetricsHistoryView(values: volumeHistory[volume.id] ?? [], color: metrics.pressure.color,
                                   title: "USAGE · \(volume.mountPoint)")
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                    MetricsStat(label: "Available", value: gib(volume.freeGB), color: metrics.pressure.color)
                    MetricsStat(label: "Used", value: gib(volume.usedGB))
                    MetricsStat(label: "Capacity", value: gib(volume.totalGB))
                    MetricsStat(label: "Mounts monitored", value: "\(metrics.volumes.filter { metrics.isCritical($0) }.count)")
                }
            }

            Divider().overlay(HerdrTheme.selection)
            MetricsSectionTitle(title: "DEVICES & MOUNTS", detail: "Available space")
            ForEach(metrics.disks) { disk in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(disk.model)
                            .font(HerdrTheme.mono(.caption, weight: .bold))
                            .foregroundStyle(HerdrTheme.text)
                        Spacer(minLength: 8)
                        Text(disk.id)
                            .font(HerdrTheme.mono(.caption2))
                            .foregroundStyle(HerdrTheme.subtext)
                    }
                    ForEach(disk.volumes.sorted { ($0.freePercent ?? 100) < ($1.freePercent ?? 100) }) { volume in
                        mountRow(volume)
                    }
                }
                .padding(12)
                .background(HerdrTheme.panel, in: RoundedRectangle(cornerRadius: 12))
            }
            Text("Below 20% available: warning · Below 10%: critical. Status follows the lowest available space on monitored mounts.")
                .font(HerdrTheme.mono(.caption2))
                .foregroundStyle(HerdrTheme.subtext)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .metricsPopoverBody(width: MetricsPopoverMetrics.detailWidth)
    }

    private var primaryDescription: String {
        guard let volume = metrics.worstVolume else { return "Mounted storage · aggregate usage" }
        return "Used on \(volume.mountPoint) · \(volume.freePercent.map(CPUMetrics.formatPercent) ?? "—") free"
    }

    private func gib(_ value: Double) -> String { String(format: "%.1f GiB", value) }

    private func mountRow(_ volume: DiskVolume) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(volume.mountPoint.isEmpty ? volume.name : volume.mountPoint)
                    .font(HerdrTheme.mono(.subheadline, weight: .semibold))
                    .foregroundStyle(HerdrTheme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(volume.pressure.label)
                    .font(HerdrTheme.mono(.caption2, weight: .semibold))
                    .foregroundStyle(volume.pressure.color)
            }
            MetricsUsageTrack(percent: volume.usagePercent ?? 0, color: volume.pressure.color)
            HStack {
                Text("\(gib(volume.freeGB)) free")
                    .foregroundStyle(volume.pressure.color)
                Spacer()
                Text("\(gib(volume.usedGB)) / \(gib(volume.totalGB)) used")
                    .foregroundStyle(HerdrTheme.subtext)
            }
            .font(HerdrTheme.mono(.caption2))
            .monospacedDigit()
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    DiskMetricsDetailView(metrics: DiskMetrics(disks: [
        PhysicalDisk(id: "nvme0", model: "Samsung 990 PRO", volumes: [
            DiskVolume(id: "/dev/nvme0n1p1", name: "Root", mountPoint: "/", totalGB: 931, usedGB: 412)
        ], temperature: 38),
        PhysicalDisk(id: "sda", model: "WDC WD40EFRX", volumes: [
            DiskVolume(id: "/dev/sda1", name: "data", mountPoint: "/data", totalGB: 1000, usedGB: 820)
        ], temperature: 42)
    ]))
}
