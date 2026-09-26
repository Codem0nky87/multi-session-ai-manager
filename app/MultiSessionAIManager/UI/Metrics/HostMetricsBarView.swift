import SwiftUI

struct HostMetricsBarView: View {
    var metricsModel: HostMetricsModel
    
    @State private var showingCPUDetail = false
    @State private var showingMemoryDetail = false
    @State private var showingGPUDetail = false
    
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
            
            // Network indicator
            VStack(spacing: 2) {
                HStack(spacing: 2) {
                    Image(systemName: "circle.fill").foregroundStyle(.red).font(.system(size: 6))
                    Image(systemName: "circle.fill").foregroundStyle(.blue).font(.system(size: 6))
                }
                HStack(spacing: 2) {
                    Image(systemName: "circle.fill").foregroundStyle(.blue).font(.system(size: 6))
                    Image(systemName: "circle.fill").foregroundStyle(.blue).font(.system(size: 6))
                }
            }
        }
        .padding(.horizontal, 16)
    }
}

#Preview {
    HostMetricsBarView(metricsModel: HostMetricsModel())
        .background(HerdrTheme.panel)
}
