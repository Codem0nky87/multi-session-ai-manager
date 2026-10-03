import sys

with open('app/MultiSessionAIManager/UI/Metrics/HostMetricsBarView.swift', 'r') as f:
    code = f.read()

if '@State private var showingDiskDetail = false' not in code:
    code = code.replace('@State private var showingNetworkDetail = false', '@State private var showingNetworkDetail = false\n    @State private var showingDiskDetail = false')

disk_button = '''
            Button {
                showingDiskDetail.toggle()
            } label: {
                VStack(spacing: 0) {
                    Text("DSK")
                        .font(HerdrTheme.mono(.caption2, weight: .bold))
                    Text("\(Int(metricsModel.disk.usagePercent))%")
                        .font(HerdrTheme.mono(.caption, weight: .bold))
                }
                .foregroundStyle(metricsModel.disk.totalGB > 0 ? HerdrTheme.subtext : HerdrTheme.muted)
            }
            .buttonStyle(.plain)
            .disabled(metricsModel.disk.totalGB == 0)
            .popover(isPresented: $showingDiskDetail, arrowEdge: .top) {
                DiskMetricsDetailView(metrics: metricsModel.disk)
                    .presentationCompactAdaptation(.popover)
            }
'''

if 'Text("DSK")' not in code:
    # insert before RAM
    code = code.replace('            Button {\n                showingMemoryDetail.toggle()', disk_button + '\n            Button {\n                showingMemoryDetail.toggle()')

with open('app/MultiSessionAIManager/UI/Metrics/HostMetricsBarView.swift', 'w') as f:
    f.write(code)

