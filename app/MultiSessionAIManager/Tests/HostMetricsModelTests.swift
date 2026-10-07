import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct HostMetricsModelTests {
    private func payload(linux: Bool) throws -> HostMetricsModel.MetricsPayload {
        var cpu: [String: Any] = [
            "temperature": 35.0, "utilization": 6.0, "systemUsage": 2.0,
            "userUsage": 4.0, "idleUsage": 94.0, "efficiencyCoreUsage": 0.0,
            "performanceCoreUsage": 0.0, "uptime": "1 day", "freqAllCores": 0,
            "freqEfficiency": 0, "freqPerformance": 0, "history": [Double](),
            "loadAverage1m": 2.94, "loadAverage5m": 2.0, "loadAverage15m": 1.0,
            "topProcesses": [["id": "123:456", "name": "python3 server.py", "usage": 250.0]]
        ]
        var memory: [String: Any] = [
            "usagePercent": 15.0, "total": 256.0, "used": 39.0,
            "app": 25.0, "wired": 0.0, "compressed": 0.0, "free": 54.0, "swap": 0.0
        ]
        if linux {
            cpu["coreCount"] = 24
            cpu["loadPerCore"] = 2.94 / 24
            cpu["perCoreUsage"] = Array(repeating: 6.0, count: 24)
            memory["available"] = 217.0
            memory["cache"] = 152.0
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "cpu": cpu, "memory": memory,
            "gpu": ["usagePercent": 27.0, "modelName": "Apple M3", "cores": 10,
                    "temperature": 0.0, "memoryUsed": 128.0, "memoryTotal": 0.0],
            "disk": ["usagePercent": 50.0, "totalGB": 460.0, "usedGB": 230.0,
                     "disks": [["id": "disk3", "model": "Apple SSD", "volumes": [
                        ["id": "/dev/disk3s3s1", "name": "Macintosh HD", "mountPoint": "/",
                         "totalGB": 460.0, "usedGB": 230.0]]]]],
            "unknownFutureField": true
        ])
        return try JSONDecoder().decode(HostMetricsModel.MetricsPayload.self, from: data)
    }

    @Test @MainActor func linuxFieldsAndTotalProcessUsageReachTheUI() throws {
        let model = HostMetricsModel()
        model.update(from: try payload(linux: true))
        #expect(model.cpu.coreCount == 24)
        #expect(model.cpu.perCoreUsage?.count == 24)
        #expect(model.cpu.loadPerCore == 2.94 / 24)
        #expect(model.cpu.topProcesses.first?.usage == 250)
        let process = try #require(model.cpu.topProcesses.first)
        #expect(model.cpu.totalUsagePercent(for: process) == 250.0 / 24.0)
        #expect(model.cpu.utilization == 6) // Already normalized by the service.
        #expect(model.memory.free == 54)
        #expect(model.memory.available == 217)
        #expect(model.memory.cache == 152)
        #expect(model.gpu.modelName == "Apple M3")
        #expect(model.gpu.usagePercent == 27)
        #expect(model.disk.disks.first?.volumes.first?.usedGB == 230)
    }

    @Test @MainActor func legacyAndMacPayloadsStillDecodeAndClearOptionalFields() throws {
        let model = HostMetricsModel()
        model.update(from: try payload(linux: true))
        model.update(from: try payload(linux: false))
        #expect(model.cpu.coreCount == nil)
        #expect(model.cpu.loadPerCore == nil)
        #expect(model.cpu.perCoreUsage == nil)
        #expect(model.memory.available == nil)
        #expect(model.memory.cache == nil)
        #expect(model.cpu.history == [6, 6])
        #expect(model.disk.totalGB == 460)
        let process = try #require(model.cpu.topProcesses.first)
        #expect(model.cpu.totalUsagePercent(for: process) == nil)
    }

    @Test(arguments: [(1, 100.0, 100.0), (8, 100.0, 12.5), (8, 800.0, 100.0),
                      (32, 215.1, 6.721875), (8, 0.0, 0.0)])
    func processUsageIsShareOfAllLogicalCores(cores: Int, usage: Double, expected: Double) throws {
        var cpu = CPUMetrics()
        cpu.coreCount = cores
        let result = try #require(cpu.totalUsagePercent(for: ProcessStat(id: "1", name: "worker", usage: usage)))
        #expect(abs(result - expected) < 0.000001)
    }

    @Test func invalidCoreCountsAndProcessSamplesDoNotDisplayMisleadingUsage() {
        var cpu = CPUMetrics()
        let process = ProcessStat(id: "1", name: "worker", usage: 100)
        for cores: Int? in [nil, 0, -1] {
            cpu.coreCount = cores
            #expect(cpu.totalUsagePercent(for: process) == nil)
        }
        cpu.coreCount = 8
        for usage in [Double.nan, Double.infinity] {
            #expect(cpu.totalUsagePercent(for: ProcessStat(id: "1", name: "worker", usage: usage)) == nil)
        }
        #expect(cpu.totalUsagePercent(for: ProcessStat(id: "1", name: "worker", usage: -1)) == 0)
        #expect(cpu.totalUsagePercent(for: ProcessStat(id: "1", name: "worker", usage: 801)) == 100)
    }

    @Test(arguments: [(0.0, "0.0%"), (0.04, "<0.1%"), (0.1, "0.1%"),
                      (0.7359849671155653, "0.7%"), (0.8144087705559906, "0.8%"),
                      (0.986069807481609, "1.0%"), (1.8495297805642634, "1.8%"),
                      (12.5, "12.5%"), (100.0, "100.0%")])
    @MainActor func cpuDisplayPreservesLowUtilization(value: Double, expected: String) throws {
        let model = HostMetricsModel()
        var sample = try payload(linux: true)
        var cpu = try #require(sample.cpu)
        cpu.utilization = value
        sample = HostMetricsModel.MetricsPayload(cpu: cpu, memory: nil, gpu: nil, disk: nil, network: nil)
        model.update(from: sample)
        #expect(model.cpu.utilization == value)
        #expect(model.cpu.history == [value])
        #expect(model.cpu.utilizationText == expected)
    }

    @Test func invalidCPUPercentagesDoNotCrashOrDisplayImpossibleValues() {
        #expect(CPUMetrics.formatPercent(.nan) == "—")
        #expect(CPUMetrics.formatPercent(.infinity) == "—")
        #expect(CPUMetrics.formatPercent(-1) == "0.0%")
        #expect(CPUMetrics.formatPercent(101) == "100.0%")
    }
}
