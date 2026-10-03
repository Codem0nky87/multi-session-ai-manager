import Foundation
import Observation

struct ProcessStat: Identifiable, Decodable {
    let id: String
    let name: String
    let usage: Double
    
    enum CodingKeys: String, CodingKey {
        case id, name, usage
    }
}

struct CPUMetrics: Decodable {
    var temperature: Double = 0.0
    var utilization: Double = 0.0
    var loadAverage1m: Double = 0.0
    var loadAverage5m: Double = 0.0
    var loadAverage15m: Double = 0.0
    
    var systemUsage: Double = 0.0
    var userUsage: Double = 0.0
    var idleUsage: Double = 0.0
    var efficiencyCoreUsage: Double = 0.0
    var performanceCoreUsage: Double = 0.0
    var uptime: String = ""
    
    var freqAllCores: Int = 0
    var freqEfficiency: Int = 0
    var freqPerformance: Int = 0
    
    var history: [Double] = []
    var topProcesses: [ProcessStat] = []
}

struct MemoryMetrics: Decodable {
    var usagePercent: Double = 0.0
}

struct GPUMetrics: Decodable {
    var usagePercent: Double = 0.0
    var modelName: String = ""
    var cores: Int = 0
}

struct NetworkMetrics: Decodable {
    var downloadSpeed: Double = 0.0
    var uploadSpeed: Double = 0.0
    var downloadString: String = "0 KB/s"
    var uploadString: String = "0 KB/s"
}

@Observable
final class HostMetricsModel {
    struct MetricsPayload: Decodable {
        let cpu: CPUMetrics?
        let memory: MemoryMetrics?
        let gpu: GPUMetrics?
        let network: NetworkMetrics?
    }
    
    var cpu = CPUMetrics()
    var memory = MemoryMetrics()
    var gpu = GPUMetrics()
    var network = NetworkMetrics()
    
    func update(from payload: MetricsPayload) {
        if let newCPU = payload.cpu {
            cpu.temperature = newCPU.temperature
            cpu.utilization = newCPU.utilization
            cpu.history.append(newCPU.utilization)
            if cpu.history.count > 20 { cpu.history.removeFirst() }
            
            cpu.loadAverage1m = newCPU.loadAverage1m
            cpu.loadAverage5m = newCPU.loadAverage5m
            cpu.loadAverage15m = newCPU.loadAverage15m
            cpu.systemUsage = newCPU.systemUsage
            cpu.userUsage = newCPU.userUsage
            cpu.idleUsage = newCPU.idleUsage
            cpu.topProcesses = newCPU.topProcesses
            cpu.uptime = newCPU.uptime
        }
        if let newMem = payload.memory {
            memory.usagePercent = newMem.usagePercent
        }
        if let newGpu = payload.gpu {
            gpu.usagePercent = newGpu.usagePercent
            gpu.modelName = newGpu.modelName
            gpu.cores = newGpu.cores
        }
        if let newNet = payload.network {
            network.downloadSpeed = newNet.downloadSpeed
            network.uploadSpeed = newNet.uploadSpeed
            network.downloadString = newNet.downloadString
            network.uploadString = newNet.uploadString
        }
    }
}

