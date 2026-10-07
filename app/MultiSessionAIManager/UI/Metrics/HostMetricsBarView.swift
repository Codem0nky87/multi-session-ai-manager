import SwiftUI

struct HostMetricsBarView: View {
    var metricsModel: HostMetricsModel
    
    @State private var showingCPUDetail = false
    @State private var showingMemoryDetail = false
    @State private var showingGPUDetail = false
    @State private var showingNetworkDetail = false
    @State private var showingDiskDetail = false
    
    var body: some View {
        HStack(spacing: 16) {
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
