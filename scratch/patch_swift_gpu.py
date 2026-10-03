import sys

with open('app/MultiSessionAIManager/UI/Metrics/HostMetricsModel.swift', 'r') as f:
    code = f.read()

old_struct = '''struct GPUMetrics: Decodable {
    var usagePercent: Double = 0.0
    var modelName: String = ""
    var cores: Int = 0
}'''
new_struct = '''struct GPUMetrics: Decodable {
    var usagePercent: Double = 0.0
    var modelName: String = ""
    var cores: Int = 0
    var temperature: Double = 0.0
    var memoryUsed: Double = 0.0
    var memoryTotal: Double = 0.0
}'''
code = code.replace(old_struct, new_struct)

old_update = '''        if let newGpu = payload.gpu {
            gpu.usagePercent = newGpu.usagePercent
            gpu.modelName = newGpu.modelName
            gpu.cores = newGpu.cores
        }'''
new_update = '''        if let newGpu = payload.gpu {
            gpu.usagePercent = newGpu.usagePercent
            gpu.modelName = newGpu.modelName
            gpu.cores = newGpu.cores
            gpu.temperature = newGpu.temperature
            gpu.memoryUsed = newGpu.memoryUsed
            gpu.memoryTotal = newGpu.memoryTotal
        }'''
code = code.replace(old_update, new_update)

with open('app/MultiSessionAIManager/UI/Metrics/HostMetricsModel.swift', 'w') as f:
    f.write(code)

