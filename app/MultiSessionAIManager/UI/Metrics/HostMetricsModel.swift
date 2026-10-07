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
    /// SMART temperature in °C when the host service can report it (Linux
    /// hwmon). Optional so payloads from older collectors still decode.
    var temperature: Double?
}

struct DiskMetrics: Decodable {
    var usagePercent: Double = 0.0
    var totalGB: Double = 0.0
    var usedGB: Double = 0.0
    var disks: [PhysicalDisk] = []

    /// Hottest physical disk, or nil when no disk reports a temperature.
    var hottestTemperature: Double? {
        let values = disks.compactMap(\.temperature)
        return values.max()
    }

    /// Above this the disk tile and gauges turn red; between warm and hot, amber.
    static let hotTemperatureThreshold: Double = 50.0
    static let warmTemperatureThreshold: Double = 40.0

    static func temperatureColor(_ temperature: Double?) -> Color {
        guard let temperature, temperature.isFinite else { return .gray }
        if temperature >= hotTemperatureThreshold { return .red }
        if temperature >= warmTemperatureThreshold { return .orange }
        return .green
    }
}

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
    // Collectors already report aggregate usage on a 0...100 scale across all
    // logical cores. Only per-process usage needs normalization by core count.
    var utilization: Double = 0.0
    var loadAverage1m: Double = 0.0
    var loadAverage5m: Double = 0.0
    var loadAverage15m: Double = 0.0
    // Optional so collectors shipped with older apps and macOS still decode.
    var coreCount: Int?
    var loadPerCore: Double?
    var perCoreUsage: [Double]?
    
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

    var utilizationText: String { Self.formatPercent(utilization) }

    static func formatPercent(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        let percent = min(100, max(0, value))
        // Keep real activity visible instead of truncating sub-1% usage to zero.
        if percent > 0 && percent < 0.1 { return "<0.1%" }
        return String(format: "%.1f%%", percent)
    }

    func totalUsagePercent(for process: ProcessStat) -> Double? {
        guard let coreCount, coreCount > 0, process.usage.isFinite else { return nil }
        return min(100, max(0, process.usage / Double(coreCount)))
    }
}

struct MemoryMetrics: Decodable {
    var usagePercent: Double = 0.0
    var total: Double = 0.0
    var used: Double = 0.0
    var app: Double = 0.0
    var wired: Double = 0.0
    var compressed: Double = 0.0
    var free: Double = 0.0
    var swap: Double = 0.0
    var available: Double?
    var cache: Double?
}

struct GPUMetrics: Decodable {
    var usagePercent: Double = 0.0
    var modelName: String = ""
    var cores: Int = 0
    var temperature: Double = 0.0
    var memoryUsed: Double = 0.0
    var memoryTotal: Double = 0.0
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
        let disk: DiskMetrics?
        let network: NetworkMetrics?
    }
    
    var cpu = CPUMetrics()
    var memory = MemoryMetrics()
    var gpu = GPUMetrics()
    var disk = DiskMetrics()
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
            cpu.coreCount = newCPU.coreCount
            cpu.loadPerCore = newCPU.loadPerCore
            cpu.perCoreUsage = newCPU.perCoreUsage
            cpu.systemUsage = newCPU.systemUsage
            cpu.userUsage = newCPU.userUsage
            cpu.idleUsage = newCPU.idleUsage
            cpu.topProcesses = newCPU.topProcesses
            cpu.uptime = newCPU.uptime
        }
        if let newMem = payload.memory {
            memory.usagePercent = newMem.usagePercent
            memory.total = newMem.total
            memory.used = newMem.used
            memory.app = newMem.app
            memory.wired = newMem.wired
            memory.compressed = newMem.compressed
            memory.free = newMem.free
            memory.swap = newMem.swap
            memory.available = newMem.available
            memory.cache = newMem.cache
        }
        
        if let newDisk = payload.disk {
            self.disk.usagePercent = newDisk.usagePercent
            self.disk.totalGB = newDisk.totalGB
            self.disk.usedGB = newDisk.usedGB
            self.disk.disks = newDisk.disks
        }

        if let newGpu = payload.gpu {
            gpu.usagePercent = newGpu.usagePercent
            gpu.modelName = newGpu.modelName
            gpu.cores = newGpu.cores
            gpu.temperature = newGpu.temperature
            gpu.memoryUsed = newGpu.memoryUsed
            gpu.memoryTotal = newGpu.memoryTotal
        }
        if let newNet = payload.network {
            network.downloadSpeed = newNet.downloadSpeed
            network.uploadSpeed = newNet.uploadSpeed
            network.downloadString = newNet.downloadString
            network.uploadString = newNet.uploadString
        }
    }
}
