import sys

with open('app/MultiSessionAIManager/UI/Metrics/HostMetricsModel.swift', 'r') as f:
    code = f.read()

structs = """struct DiskVolume: Decodable, Identifiable {
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
"""

if structs in code:
    code = code.replace(structs, "")
    code = structs + "\\n" + code

with open('app/MultiSessionAIManager/UI/Metrics/HostMetricsModel.swift', 'w') as f:
    f.write(code)

