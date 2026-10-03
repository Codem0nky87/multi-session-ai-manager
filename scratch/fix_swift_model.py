import sys

with open('app/MultiSessionAIManager/UI/Metrics/HostMetricsModel.swift', 'r') as f:
    code = f.read()

if 'let disk: DiskMetrics?' not in code:
    code = code.replace('let gpu: GPUMetrics?', 'let gpu: GPUMetrics?\\n        let disk: DiskMetrics?')

if '@Published var disk' not in code:
    code = code.replace('@Published var gpu', '@Published var disk = DiskMetrics()\\n    @Published var gpu')

if 'disk.usagePercent = newDisk' in code:
    code = code.replace('            disk.usagePercent', '            self.disk.usagePercent')
    code = code.replace('            disk.totalGB', '            self.disk.totalGB')
    code = code.replace('            disk.usedGB', '            self.disk.usedGB')
    code = code.replace('            disk.disks', '            self.disk.disks')

with open('app/MultiSessionAIManager/UI/Metrics/HostMetricsModel.swift', 'w') as f:
    f.write(code)

