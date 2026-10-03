import sys

with open('app/MultiSessionAIManager/UI/Metrics/HostMetricsModel.swift', 'r') as f:
    code = f.read()

disk_structs = '''
struct DiskVolume: Decodable, Identifiable {
    var id: String
    var name: String
    var mountPoint: String
    var totalGB: Double
    var usedGB: Double
}

struct PhysicalDisk: Decodable, Identifiable {
    var id: String
    var model: String
    var volumes: [DiskVolume]
}

struct DiskMetrics: Decodable {
    var usagePercent: Double = 0.0
    var totalGB: Double = 0.0
    var usedGB: Double = 0.0
    var disks: [PhysicalDisk] = []
}
'''

if 'struct DiskVolume' not in code:
    code = code.replace('struct MetricsPayload: Decodable {', disk_structs + '\nstruct MetricsPayload: Decodable {')

if 'var disk: DiskMetrics?' not in code:
    code = code.replace('var gpu: GPUMetrics?', 'var gpu: GPUMetrics?\n    var disk: DiskMetrics?')

if '@Published var disk' not in code:
    code = code.replace('@Published var gpu', '@Published var disk = DiskMetrics()\n    @Published var gpu')

disk_update = '''
        if let newDisk = payload.disk {
            disk.usagePercent = newDisk.usagePercent
            disk.totalGB = newDisk.totalGB
            disk.usedGB = newDisk.usedGB
            disk.disks = newDisk.disks
        }
'''

if 'disk.usagePercent =' not in code:
    code = code.replace('if let newGpu = payload.gpu {', disk_update + '\n        if let newGpu = payload.gpu {')

with open('app/MultiSessionAIManager/UI/Metrics/HostMetricsModel.swift', 'w') as f:
    f.write(code)

