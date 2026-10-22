import SwiftUI

struct DiskMetricsDetailView: View {
    var metrics: DiskMetrics

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MetricsDetailHeader(
                title: "STORAGE", symbol: "internaldrive", value: "",
                subtitle: "Hardware & mounted volumes", color: metrics.pressure.color,
                status: metrics.pressure.label, showsValue: false)

            VStack(alignment: .leading, spacing: 12) {
                MetricsSectionTitle(title: "PHYSICAL DISKS", detail: "\(metrics.hardware.count)")
                if metrics.hardware.isEmpty {
                    empty("Physical inventory unavailable from this host service.")
                }
                ForEach(metrics.hardware) { disk in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "internaldrive.fill")
                                .foregroundStyle(HerdrTheme.accent)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(disk.model)
                                    .font(HerdrTheme.mono(.caption, weight: .semibold))
                                    .foregroundStyle(HerdrTheme.text)
                                Text(disk.id)
                                    .font(HerdrTheme.mono(.caption2))
                                    .foregroundStyle(HerdrTheme.subtext)
                            }
                            Spacer(minLength: 0)
                            Label(temperature(disk.temperature), systemImage: "thermometer.medium")
                                .font(HerdrTheme.mono(.caption2, weight: .semibold))
                                .foregroundStyle(DiskMetrics.temperatureColor(disk.temperature))
                                .fixedSize()
                        }
                        HStack {
                            column("Size", gib(disk.totalGB))
                            Spacer()
                            column("Free in volumes", gib(disk.availableGB))
                        }
                    }
                    .padding(12)
                    .background(HerdrTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                }
            }

            Divider().overlay(HerdrTheme.selection)
            VStack(alignment: .leading, spacing: 12) {
                MetricsSectionTitle(title: "LOGICAL VOLUMES", detail: "\(metrics.volumes.count)")
                if metrics.volumes.isEmpty { empty("No mounted volumes reported.") }
                ForEach(metrics.volumes.sorted { $0.mountPoint.localizedStandardCompare($1.mountPoint) == .orderedAscending }) { volume in
                    HStack(spacing: 12) {
                        MetricsLiquidGauge(percent: volume.usagePercent, color: volume.pressure.color, compact: true)
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(volume.mountPoint.isEmpty ? volume.name : volume.mountPoint)
                                    .font(HerdrTheme.mono(.subheadline, weight: .semibold))
                                    .foregroundStyle(HerdrTheme.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                Text(volume.pressure.label)
                                    .font(HerdrTheme.mono(.caption2))
                                    .foregroundStyle(volume.pressure.color)
                            }
                            HStack {
                                column("Size", gib(volume.totalGB))
                                Spacer(minLength: 4)
                                column("Free", gib(volume.freeGB), color: volume.pressure.color)
                            }
                        }
                    }
                    .padding(12)
                    .background(HerdrTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            empty("Liquid shows used space. Free space below 20% is amber; below 10% is red. — means unavailable or shared across physical disks.")
        }
        .padding(20)
        .metricsPopoverBody(width: MetricsPopoverMetrics.detailWidth)
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(HerdrTheme.mono(.caption2))
            .foregroundStyle(HerdrTheme.subtext)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func column(_ label: String, _ value: String, color: Color = HerdrTheme.text) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).foregroundStyle(HerdrTheme.subtext)
            Text(value).foregroundStyle(color).monospacedDigit()
        }
        .font(HerdrTheme.mono(.caption2))
    }

    private func gib(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        return String(format: "%.1f GiB", value)
    }

    private func temperature(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "—" }
        return String(format: "%.0f°C", value)
    }
}

#Preview {
    DiskMetricsDetailView(metrics: DiskMetrics(disks: [
        PhysicalDisk(id: "nvme0", model: "Samsung 990 PRO", volumes: [
            DiskVolume(id: "/dev/nvme0n1p1", name: "Root", mountPoint: "/", totalGB: 931, usedGB: 412),
            DiskVolume(id: "/dev/sda1", name: "Data", mountPoint: "/data", totalGB: 1000, usedGB: 820)
        ])
    ], physicalDisks: [
        PhysicalDisk(id: "nvme0n1", model: "Samsung 990 PRO", volumes: [], temperature: 38,
                     totalGB: 1000, availableGB: 519),
        PhysicalDisk(id: "sda", model: "WDC WD40EFRX", volumes: [], temperature: 42,
                     totalGB: 1000, availableGB: 180)
    ]))
}
