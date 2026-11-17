import SwiftUI

struct HostMetricsBarView: View {
    var metricsModel: HostMetricsModel
    /// The host whose port-forwarding state this bar reflects. Pass nil to
    /// omit the tunnel indicator (previews, hosts without saved tunnels).
    var hostID: UUID? = nil
    /// The host's largest-files lists, shown when a volume is expanded in the
    /// storage detail. Nil leaves the volumes as plain rows.
    var volumeUsage: VolumeUsageModel? = nil

    @Environment(\.portForwardingManager) private var portForwarding
    @State private var showingCPUDetail = false
    @State private var showingMemoryDetail = false
    @State private var showingGPUDetail = false
    @State private var showingNetworkDetail = false
    @State private var showingDiskDetail = false
    @State private var showingForwards = false
    @State private var showingPowerDetail = false

    var body: some View {
        HStack(spacing: 16) {
            // Live port-forward indicator: how many forwards run for this host,
            // and behind it the list of them. Hidden when nothing runs.
            if let hostID, let session = portForwarding?.sessions[hostID], session.activeTunnelCount > 0 {
                PortForwardsPill(session: session, isShowingForwards: $showingForwards) {
                    await portForwarding?.remove(hostID: hostID)
                }
            }

            Button {
                showingCPUDetail.toggle()
            } label: {
                VStack(spacing: 0) {
                    Text("CPU")
                        .font(HerdrTheme.mono(.caption2, weight: .bold))
                    Text(metricsModel.cpu.utilizationText)
                        .font(HerdrTheme.mono(.caption, weight: .bold))
                }
                .foregroundStyle(HerdrTheme.subtext)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingCPUDetail, arrowEdge: .top) {
                CPUMetricsDetailView(metrics: metricsModel.cpu)
                    .presentationCompactAdaptation(.popover)
            }
            
            Button {
                showingGPUDetail.toggle()
            } label: {
                VStack(spacing: 0) {
                    Text("GPU")
                        .font(HerdrTheme.mono(.caption2, weight: .bold))
                    Text(metricsModel.gpu.hasUtilization ? CPUMetrics.formatPercent(metricsModel.gpu.usagePercent) : "—")
                        .font(HerdrTheme.mono(.caption, weight: .bold))
                }
                .foregroundStyle(metricsModel.gpu.modelName.isEmpty ? HerdrTheme.muted : HerdrTheme.subtext)
            }
            .buttonStyle(.plain)
            .disabled(metricsModel.gpu.modelName.isEmpty)
            .accessibilityIdentifier("metrics.gpu")
            .popover(isPresented: $showingGPUDetail, arrowEdge: .top) {
                GPUMetricsDetailView(metrics: metricsModel.gpu, history: metricsModel.gpuHistory)
                    .presentationCompactAdaptation(.popover)
            }
            
            Button {
                showingMemoryDetail.toggle()
            } label: {
                VStack(spacing: 0) {
                    Text("RAM")
                        .font(HerdrTheme.mono(.caption2, weight: .bold))
                    Text(CPUMetrics.formatPercent(metricsModel.memory.usagePercent))
                        .font(HerdrTheme.mono(.caption, weight: .bold))
                }
                .foregroundStyle(HerdrTheme.subtext)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingMemoryDetail, arrowEdge: .top) {
                MemoryMetricsDetailView(metrics: metricsModel.memory, history: metricsModel.memoryHistory)
                    .presentationCompactAdaptation(.popover)
            }

            Button {
                showingDiskDetail.toggle()
            } label: {
                VStack(spacing: 0) {
                    Text("DSK")
                        .font(HerdrTheme.mono(.caption2, weight: .bold))
                    Text(CPUMetrics.formatPercent(metricsModel.disk.displayUsagePercent))
                        .font(HerdrTheme.mono(.caption, weight: .bold))
                    if let hottest = metricsModel.disk.hottestTemperature,
                       hottest >= DiskMetrics.hotTemperatureThreshold {
                        // Only surface heat in the bar when it is actually hot;
                        // the popover carries the per-disk detail.
                        Text("\(Int(hottest))°C")
                            .font(HerdrTheme.mono(.caption2, weight: .bold))
                            .foregroundStyle(.red)
                    }
                }
                .foregroundStyle(metricsModel.disk.pressure.color)
            }
            .buttonStyle(.plain)
            .disabled(metricsModel.disk.totalGB == 0 && metricsModel.disk.hardware.isEmpty)
            .accessibilityIdentifier("metrics.disk")
            .accessibilityLabel("Disk, \(metricsModel.disk.pressure.label)")
            .accessibilityValue(metricsModel.disk.worstVolume.map {
                "\($0.mountPoint), \(CPUMetrics.formatPercent($0.freePercent ?? 0)) available"
            } ?? "Capacity unavailable")
            .popover(isPresented: $showingDiskDetail, arrowEdge: .top) {
                DiskMetricsDetailView(metrics: metricsModel.disk, usage: volumeUsage)
                    .presentationCompactAdaptation(.popover)
            }

            Button {
                showingNetworkDetail.toggle()
            } label: {
                HStack(spacing: 4) {
                    VStack(spacing: 2) {
                        Image(systemName: "arrow.down").foregroundStyle(.blue).font(.system(size: 8, weight: .bold))
                        Image(systemName: "arrow.up").foregroundStyle(.red).font(.system(size: 8, weight: .bold))
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(metricsModel.network.downloadString)
                            .font(HerdrTheme.mono(.caption2, weight: .bold))
                        Text(metricsModel.network.uploadString)
                            .font(HerdrTheme.mono(.caption2, weight: .bold))
                    }
                }
                .foregroundStyle(HerdrTheme.subtext)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingNetworkDetail, arrowEdge: .top) {
                NetworkMetricsDetailView(metrics: metricsModel.network,
                                         downloadHistory: metricsModel.downloadHistory,
                                         uploadHistory: metricsModel.uploadHistory,
                                         hasSample: metricsModel.hasNetworkSample)
                    .presentationCompactAdaptation(.popover)
            }

            Button {
                showingPowerDetail.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(metricsModel.power.hasPower ? Color.yellow : HerdrTheme.muted)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("PWR")
                            .font(HerdrTheme.mono(.caption2, weight: .bold))
                        Text(metricsModel.power.formattedTotalWatts)
                            .font(HerdrTheme.mono(.caption, weight: .bold))
                    }
                }
                .foregroundStyle(metricsModel.power.hasPower ? HerdrTheme.subtext : HerdrTheme.muted)
            }
            .buttonStyle(.plain)
            .disabled(!metricsModel.power.hasPower)
            .accessibilityIdentifier("metrics.power")
            .popover(isPresented: $showingPowerDetail, arrowEdge: .top) {
                PowerMetricsDetailView(metrics: metricsModel.power, history: metricsModel.powerHistory)
                    .presentationCompactAdaptation(.popover)
            }

        }
        .padding(.horizontal, 16)
    }
}

#Preview {
    HostMetricsBarView(metricsModel: HostMetricsModel())
        .background(HerdrTheme.panel)
}
