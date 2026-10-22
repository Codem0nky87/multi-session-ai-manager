import SwiftUI
import Foundation
import Observation

enum DiskPressure {
    case unknown, healthy, warning, critical

    var color: Color {
        switch self {
        case .unknown: return .gray
        case .healthy: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var label: String {
        switch self {
        case .unknown: return "Unavailable"
        case .healthy: return "Healthy"
        case .warning: return "Low space"
        case .critical: return "Critical"
        }
    }
}

struct DiskVolume: Decodable, Identifiable {
    var id: String
    var name: String
    var mountPoint: String
    var totalGB: Double
    var usedGB: Double
    /// Available to an ordinary user; excludes filesystem reserved blocks.
    var availableGB: Double?
    var isCriticalMount: Bool?

    var freeGB: Double { max(0, availableGB ?? (totalGB - usedGB)) }

    var freePercent: Double? {
        let usable = usedGB + freeGB
        guard totalGB > 0, usable > 0, usable.isFinite, freeGB.isFinite else { return nil }
        return min(100, max(0, 100 * freeGB / usable))
    }

    var usagePercent: Double? { freePercent.map { 100 - $0 } }

    var pressure: DiskPressure {
        guard let freePercent else { return .unknown }
        if freePercent < 10 { return .critical }
        if freePercent < 20 { return .warning }
        return .healthy
    }
}

struct DiskDeviceTemperature: Decodable, Identifiable {
    var id: String
    var model: String
    var temperature: Double
}

struct PhysicalDisk: Decodable, Identifiable {
    var id: String
    var model: String
    var volumes: [DiskVolume]
    /// SMART temperature in °C when the host service can report it (Linux
    /// hwmon). Optional so payloads from older collectors still decode.
    var temperature: Double?
    /// Hardware capacity and free space attributable to its mounted filesystems.
    /// Pool free space cannot always be attributed to a single physical member.
    var totalGB: Double?
    var availableGB: Double?
}

struct DiskMetrics: Decodable {
    var usagePercent: Double = 0.0
    var totalGB: Double = 0.0
    var usedGB: Double = 0.0
    var disks: [PhysicalDisk] = []
    // Additive fields: nil on collectors before 2.2.
    var platform: String?
    var temperatures: [DiskDeviceTemperature]?
    var physicalDisks: [PhysicalDisk]?

    var hardware: [PhysicalDisk] {
        if let physicalDisks { return physicalDisks }
        // Legacy payloads only identify hardware reliably through sensors.
        // Never relabel an LVM group or the Windows catch-all as a physical disk.
        return deviceTemperatures.map {
            PhysicalDisk(id: $0.id, model: $0.model, volumes: [], temperature: $0.temperature)
        }
    }

    var volumes: [DiskVolume] { disks.flatMap(\.volumes) }

    private var hostPlatform: String {
        if let platform { return platform }
        if volumes.contains(where: { $0.mountPoint.contains(":") }) { return "win32" }
        if disks.contains(where: { $0.id.hasPrefix("disk") && $0.model != "Linux Disk" })
            || volumes.contains(where: { $0.id.hasPrefix("/dev/disk") }) {
            return "darwin"
        }
        return "linux"
    }

    func isCritical(_ volume: DiskVolume) -> Bool {
        if let isCriticalMount = volume.isCriticalMount { return isCriticalMount }
        switch hostPlatform {
        case "win32":
            return volume.mountPoint.replacingOccurrences(of: "/", with: "\\")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\\")).uppercased() == "C:"
        case "darwin": return volume.mountPoint == "/"
        default: return true
        }
    }

    /// Linux watches every real mount; macOS watches / and Windows watches C:\.
    /// Rank by available percentage so a large empty disk cannot hide /data.
    var worstVolume: DiskVolume? {
        volumes.filter { isCritical($0) && $0.freePercent != nil }
            .min { ($0.freePercent ?? 100) < ($1.freePercent ?? 100) }
    }

    var pressure: DiskPressure { worstVolume?.pressure ?? .unknown }
    var displayUsagePercent: Double { worstVolume?.usagePercent ?? usagePercent }

    var deviceTemperatures: [DiskDeviceTemperature] {
        // New collectors resolve physical sensors independently of logical volumes.
        // Keep legacy temperatures usable, deduplicating identical device IDs.
        let candidates = temperatures ?? disks.compactMap { disk -> DiskDeviceTemperature? in
            guard let temperature = disk.temperature else { return nil }
            return DiskDeviceTemperature(id: disk.id, model: disk.model, temperature: temperature)
        }
        var devices: [String: DiskDeviceTemperature] = [:]
        for device in candidates where device.temperature.isFinite && device.temperature > 0 {
            if device.temperature >= (devices[device.id]?.temperature ?? 0) {
                devices[device.id] = device
            }
        }
        return devices.values.sorted {
            $0.temperature == $1.temperature ? $0.id < $1.id : $0.temperature > $1.temperature
        }
    }

    /// Hottest physical disk, or nil when no disk reports a temperature.
    var hottestTemperature: Double? {
        deviceTemperatures.map(\.temperature).max()
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
        return String(format: "%.0f%%", percent.rounded())
    }

    func totalUsagePercent(for process: ProcessStat) -> Double? {
        guard let coreCount, coreCount > 0, process.usage.isFinite else { return nil }
        return min(100, max(0, process.usage / Double(coreCount)))
    }
}

struct MemoryProcessStat: Identifiable, Decodable {
    let id: String
    let pid: Int
    let name: String
    let rssBytes: Double
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
    var topProcesses: [MemoryProcessStat]?
}

struct GPUMetrics: Decodable {
    var usagePercent: Double = 0.0
    var modelName: String = ""
    var cores: Int = 0
    var temperature: Double = 0.0
    var memoryUsed: Double = 0.0
    var memoryTotal: Double = 0.0
    var utilizationAvailable: Bool?

    var hasUtilization: Bool { utilizationAvailable ?? !modelName.isEmpty }
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
    var memoryHistory: [Double] = []
    var gpuHistory: [Double] = []
    var diskVolumeHistory: [String: [Double]] = [:]
    var downloadHistory: [Double] = []
    var uploadHistory: [Double] = []
    var hasNetworkSample = false

    private func history(_ values: [Double], appending value: Double) -> [Double] {
        guard value.isFinite else { return values }
        return Array((values + [value]).suffix(30))
    }
    
    func update(from payload: MetricsPayload) {
        if let newCPU = payload.cpu {
            cpu.temperature = newCPU.temperature
            cpu.utilization = newCPU.utilization
            cpu.history = history(cpu.history, appending: newCPU.utilization)
            
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
            memory.topProcesses = newMem.topProcesses
            memoryHistory = history(memoryHistory, appending: newMem.usagePercent)
        }
        
        if let newDisk = payload.disk {
            disk = newDisk
            var next: [String: [Double]] = [:]
            for volume in newDisk.volumes {
                if let usage = volume.usagePercent {
                    next[volume.id] = history(diskVolumeHistory[volume.id] ?? [], appending: usage)
                }
            }
            diskVolumeHistory = next
        }

        if let newGpu = payload.gpu {
            gpu.usagePercent = newGpu.usagePercent
            gpu.modelName = newGpu.modelName
            gpu.cores = newGpu.cores
            gpu.temperature = newGpu.temperature
            gpu.memoryUsed = newGpu.memoryUsed
            gpu.memoryTotal = newGpu.memoryTotal
            gpu.utilizationAvailable = newGpu.utilizationAvailable
            if newGpu.hasUtilization {
                gpuHistory = history(gpuHistory, appending: newGpu.usagePercent)
            } else {
                gpuHistory = []
            }
        }
        if let newNet = payload.network {
            network.downloadSpeed = newNet.downloadSpeed
            network.uploadSpeed = newNet.uploadSpeed
            network.downloadString = newNet.downloadString
            network.uploadString = newNet.uploadString
            hasNetworkSample = true
            downloadHistory = history(downloadHistory, appending: max(0, newNet.downloadSpeed))
            uploadHistory = history(uploadHistory, appending: max(0, newNet.uploadSpeed))
        }
    }
}
