import SwiftUI

struct HostMetricsBarView: View {
    var metricsModel: HostMetricsModel
    /// The host whose port-forwarding state this bar reflects. Pass nil to
    /// omit the tunnel indicator (previews, hosts without saved tunnels).
    var hostID: UUID? = nil

    @Environment(\.portForwardingManager) private var portForwarding
    @State private var showingCPUDetail = false
    @State private var showingMemoryDetail = false
    @State private var showingGPUDetail = false
    @State private var showingNetworkDetail = false
    @State private var showingDiskDetail = false
    @State private var showingTunnels = false

    var body: some View {
        HStack(spacing: 16) {
            // Live port-forward indicator: a modern pill showing how many
            // proxy address runners are active for this host. Tapping it
            // reopens that host's port manager. Hidden when nothing runs.
            if let hostID, portForwarding?.activeTunnelCount(for: hostID) ?? 0 > 0 {
                Button {
                    showingTunnels = true
                } label: {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Theme.success)
                            .frame(width: 7, height: 7)
                        Image(systemName: "network")
                            .font(.system(size: 10, weight: .bold))
                        Text("\(portForwarding?.activeTunnelCount(for: hostID) ?? 0)")
                            .font(HerdrTheme.mono(.caption, weight: .bold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(HerdrTheme.selection))
                    .foregroundStyle(HerdrTheme.text)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("1 port forward running. Tap to manage.")
                .accessibilityIdentifier("metrics.port-forwards")
                .popover(isPresented: $showingTunnels, arrowEdge: .bottom) {
                    // The sheet is full-screen-ish; a compact popover body
                    // showing status plus a stop control keeps the bar usable.
                    VStack(alignment: .leading, spacing: 12) {
                        Text("PORT FORWARDS")
                            .font(HerdrTheme.mono(.caption, weight: .bold))
                            .foregroundStyle(HerdrTheme.subtext)
                        if let session = portForwarding?.sessions[hostID] {
                            switch session.model.status {
                            case .connecting:
                                Label("Connecting…", systemImage: "arrow.triangle.2.circlepath")
                                    .font(HerdrTheme.mono(.subheadline))
                                    .foregroundStyle(HerdrTheme.subtext)
                            case .listening(let port), .open(let port):
                                Label("127.0.0.1:\(port) live", systemImage: "checkmark.circle.fill")
                                    .font(HerdrTheme.mono(.subheadline))
                                    .foregroundStyle(HerdrTheme.green)
                            case .failed(let message):
                                Label(message, systemImage: "xmark.circle.fill")
                                    .font(HerdrTheme.mono(.subheadline))
                                    .foregroundStyle(HerdrTheme.red)
                            case .idle:
                                EmptyView()
                            }
                            Button(role: .destructive) {
                                Task { await portForwarding?.remove(hostID: hostID) }
                            } label: {
                                Label("Stop tunnel", systemImage: "stop.circle")
                                    .font(HerdrTheme.mono(.subheadline))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(HerdrTheme.red)
                        }
                    }
                    .padding()
                    .frame(width: 260)
                    .background(HerdrTheme.background)
                    .presentationCompactAdaptation(.popover)
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
                    .metricsPopoverBody(width: 320)
                    .presentationCompactAdaptation(.popover)
            }
            
            Button {
                showingGPUDetail.toggle()
            } label: {
                VStack(spacing: 0) {
                    Text("GPU")
                        .font(HerdrTheme.mono(.caption2, weight: .bold))
                    Text(metricsModel.gpu.modelName.isEmpty ? "--%" : "\(Int(metricsModel.gpu.usagePercent))%")
                        .font(HerdrTheme.mono(.caption, weight: .bold))
                }
                .foregroundStyle(metricsModel.gpu.modelName.isEmpty ? HerdrTheme.muted : HerdrTheme.subtext)
            }
            .buttonStyle(.plain)
            .disabled(metricsModel.gpu.modelName.isEmpty)
            .accessibilityIdentifier("metrics.gpu")
            .popover(isPresented: $showingGPUDetail, arrowEdge: .top) {
                GPUMetricsDetailView(metrics: metricsModel.gpu)
                    .metricsPopoverBody(width: 320)
                    .presentationCompactAdaptation(.popover)
            }
            
            Button {
                showingMemoryDetail.toggle()
            } label: {
                VStack(spacing: 0) {
                    Text("RAM")
                        .font(HerdrTheme.mono(.caption2, weight: .bold))
                    Text("\(Int(metricsModel.memory.usagePercent))%")
                        .font(HerdrTheme.mono(.caption, weight: .bold))
                }
                .foregroundStyle(HerdrTheme.subtext)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingMemoryDetail, arrowEdge: .top) {
                MemoryMetricsDetailView(metrics: metricsModel.memory)
                    .metricsPopoverBody(width: 320)
                    .presentationCompactAdaptation(.popover)
            }

            Button {
                showingDiskDetail.toggle()
            } label: {
                VStack(spacing: 0) {
                    Text("DSK")
                        .font(HerdrTheme.mono(.caption2, weight: .bold))
                    Text("\(Int(metricsModel.disk.usagePercent))%")
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
                .foregroundStyle(metricsModel.disk.totalGB > 0 ? HerdrTheme.subtext : HerdrTheme.muted)
            }
            .buttonStyle(.plain)
            .disabled(metricsModel.disk.totalGB == 0)
            .accessibilityIdentifier("metrics.disk")
            .popover(isPresented: $showingDiskDetail, arrowEdge: .top) {
                DiskMetricsDetailView(metrics: metricsModel.disk)
                    .metricsPopoverBody(width: 340)
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
                NetworkMetricsDetailView(metrics: metricsModel.network)
                    .metricsPopoverBody(width: 320)
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
