import SwiftUI

struct DiskMetricsDetailView: View {
    var metrics: DiskMetrics
    /// The host's largest-files lists. Without it (previews, a host that is not
    /// connected through a session) volumes are plain rows that do not expand.
    var usage: VolumeUsageModel? = nil
    /// Volumes whose file list is showing, by volume id. Kept here so a reopened
    /// popover starts collapsed; the lists themselves outlive it in `usage`.
    @State private var expanded: Set<String> = []

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
                    VStack(alignment: .leading, spacing: 10) {
                        if let usage, !volume.mountPoint.isEmpty {
                            Button {
                                toggle(volume, in: usage)
                            } label: {
                                summary(of: volume, isExpanded: expanded.contains(volume.id))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("metrics.disk.volume.\(volume.mountPoint)")
                            .accessibilityHint(expanded.contains(volume.id)
                                               ? "Hides the largest files"
                                               : "Lists the files using the most space on this volume")
                            if expanded.contains(volume.id) {
                                VolumeLargestFilesView(mountPoint: volume.mountPoint, usage: usage)
                            }
                        } else {
                            summary(of: volume, isExpanded: nil)
                        }
                    }
                    .padding(12)
                    .background(HerdrTheme.panel, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            empty("Liquid shows used space. Free space below 20% is amber; below 10% is red. — means unavailable or shared across physical disks."
                  + (usage == nil ? "" : " Tap a volume to list its largest files."))
        }
        .padding(20)
        .metricsPopoverBody(width: MetricsPopoverMetrics.detailWidth)
    }

    /// - Parameter isExpanded: nil for a volume that cannot be expanded, which
    ///   shows no chevron.
    private func summary(of volume: DiskVolume, isExpanded: Bool?) -> some View {
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
                    if let isExpanded {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(HerdrTheme.subtext)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                HStack {
                    column("Size", gib(volume.totalGB))
                    Spacer(minLength: 4)
                    column("Free", gib(volume.freeGB), color: volume.pressure.color)
                }
            }
        }
    }

    private func toggle(_ volume: DiskVolume, in usage: VolumeUsageModel) {
        if expanded.remove(volume.id) != nil { return }
        expanded.insert(volume.id)
        Task { await usage.load(volume.mountPoint) }
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
