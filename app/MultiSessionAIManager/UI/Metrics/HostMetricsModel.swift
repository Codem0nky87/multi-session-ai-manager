import Foundation
import Observation

struct ProcessStat: Identifiable {
    let id = UUID()
    let name: String
    let usage: Double
}

struct CPUMetrics {
    var temperature: Double
    var utilization: Double
    var loadAverage1m: Double
    var loadAverage5m: Double
    var loadAverage15m: Double
    
    var systemUsage: Double
    var userUsage: Double
    var idleUsage: Double
    var efficiencyCoreUsage: Double
    var performanceCoreUsage: Double
    var uptime: String
    
    var freqAllCores: Int
    var freqEfficiency: Int
    var freqPerformance: Int
    
    var history: [Double]
    var topProcesses: [ProcessStat]
}

struct MemoryMetrics {
    var usagePercent: Double
}

struct GPUMetrics {
    var usagePercent: Double
}

@Observable
final class HostMetricsModel {
    var cpu = CPUMetrics(
        temperature: 48.0,
        utilization: 43.0,
        loadAverage1m: 2.31,
        loadAverage5m: 2.59,
        loadAverage15m: 2.50,
        systemUsage: 9.0,
        userUsage: 33.0,
        idleUsage: 56.0,
        efficiencyCoreUsage: 40.0,
        performanceCoreUsage: 44.0,
        uptime: "9 days, 5 hours",
        freqAllCores: 2607,
        freqEfficiency: 1951,
        freqPerformance: 3264,
        history: [10, 15, 30, 20, 15, 10, 45, 25, 20, 15, 55, 30, 25, 20, 15, 40, 25],
        topProcesses: [
            ProcessStat(name: "Docker", usage: 295.3),
            ProcessStat(name: "WindowServer", usage: 37.4),
            ProcessStat(name: "ScreensharingAgent", usage: 25.5),
            ProcessStat(name: "agy", usage: 15.2),
            ProcessStat(name: "wdavdaemon", usage: 13.0),
            ProcessStat(name: "claude", usage: 9.0),
            ProcessStat(name: "Stats", usage: 6.6)
        ]
    )
    
    var memory = MemoryMetrics(usagePercent: 83.0)
    var gpu = GPUMetrics(usagePercent: 39.0)
    
    // In the future, we'll have a timer or stream updating this.
    // For now, it's static mock data.
}
