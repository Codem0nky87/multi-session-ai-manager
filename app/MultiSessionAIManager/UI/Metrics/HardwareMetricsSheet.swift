import SwiftUI

public struct HardwareMetricsSheet: View {
    public var metrics: HostMetricsModel
    @Environment(\.dismiss) private var dismiss

    public init(metrics: HostMetricsModel) {
        self.metrics = metrics
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // CPU Card
                    VStack(alignment: .leading, spacing: 8) {
                        Text("CPU")
                            .font(HerdrTheme.mono(.headline, weight: .bold))
                            .foregroundStyle(HerdrTheme.subtext)
                        CPUMetricsDetailView(metrics: metrics.cpu)
                    }
                    .padding()
                    .background(HerdrTheme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Memory Card
                    VStack(alignment: .leading, spacing: 8) {
                        Text("MEMORY")
                            .font(HerdrTheme.mono(.headline, weight: .bold))
                            .foregroundStyle(HerdrTheme.subtext)
                        MemoryMetricsDetailView(metrics: metrics.memory, history: metrics.memoryHistory)
                    }
                    .padding()
                    .background(HerdrTheme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // GPU Card
                    if metrics.gpu.utilizationAvailable || metrics.gpu.temperature != nil {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("GPU")
                                .font(HerdrTheme.mono(.headline, weight: .bold))
                                .foregroundStyle(HerdrTheme.subtext)
                            GPUMetricsDetailView(metrics: metrics.gpu, history: metrics.gpuHistory)
                        }
                        .padding()
                        .background(HerdrTheme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }

                    // Network Card
                    VStack(alignment: .leading, spacing: 8) {
                        Text("NETWORK")
                            .font(HerdrTheme.mono(.headline, weight: .bold))
                            .foregroundStyle(HerdrTheme.subtext)
                        NetworkMetricsDetailView(metrics: metrics.network, downloadHistory: metrics.downloadHistory, uploadHistory: metrics.uploadHistory)
                    }
                    .padding()
                    .background(HerdrTheme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Disk Card
                    VStack(alignment: .leading, spacing: 8) {
                        Text("STORAGE")
                            .font(HerdrTheme.mono(.headline, weight: .bold))
                            .foregroundStyle(HerdrTheme.subtext)
                        DiskMetricsDetailView(metrics: metrics.disk, volumeHistory: metrics.diskVolumeHistory)
                    }
                    .padding()
                    .background(HerdrTheme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .padding()
            }
            .background(HerdrTheme.background)
            .navigationTitle("Host Telemetry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(HerdrTheme.accent)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
