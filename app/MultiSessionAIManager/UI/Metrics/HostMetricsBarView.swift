import SwiftUI

struct HostMetricsBarView: View {
    var metricsModel: HostMetricsModel
    
    @State private var showingCPUDetail = false
    @State private var showingMemoryDetail = false
    @State private var showingGPUDetail = false
    @State private var showingNetworkDetail = false
    
    var body: some View {
        HStack(spacing: 16) {
            Button {
                showingCPUDetail.toggle()
            } label: {
                VStack(spacing: 0) {
                    Text("CPU")
                        .font(HerdrTheme.mono(.caption2, weight: .bold))
                    Text("\(Int(metricsModel.cpu.utilization))%")
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
                    Text("\(Int(metricsModel.gpu.usagePercent))%")
                        .font(HerdrTheme.mono(.caption, weight: .bold))
                }
                .foregroundStyle(HerdrTheme.subtext)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showingGPUDetail, arrowEdge: .top) {
                GPUMetricsDetailView(metrics: metricsModel.gpu)
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
