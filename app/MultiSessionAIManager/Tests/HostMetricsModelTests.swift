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
            memory["topProcesses"] = [
                ["id": "42:100", "pid": 42, "name": "worker", "rssBytes": 8388608]
            ]
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
        #expect(model.memory.topProcesses?.first?.pid == 42)
        #expect(model.memory.topProcesses?.first?.rssBytes == 8388608)
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
        #expect(model.memory.topProcesses == nil)
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

    @Test(arguments: [(0.0, "0%"), (0.04, "0%"), (0.1, "0%"), (0.5, "1%"),
                      (0.7359849671155653, "1%"), (0.8144087705559906, "1%"),
                      (0.986069807481609, "1%"), (1.8495297805642634, "2%"),
                      (12.5, "13%"), (100.0, "100%")])
    @MainActor func cpuDisplayRoundsButPreservesSamplePrecision(value: Double, expected: String) throws {
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
        #expect(CPUMetrics.formatPercent(-1) == "0%")
        #expect(CPUMetrics.formatPercent(101) == "100%")
    }

    @Test @MainActor func linuxDataMountDrivesStatusAndHistoryDespiteHealthyAggregate() throws {
        let data = Data(#"""
        {"usagePercent": 2, "usedGB": 182, "totalGB": 10100, "platform": "linux",
         "temperatures": [{"id": "nvme0", "model": "Samsung SSD", "temperature": 41}],
         "disks": [{"id": "nvme0", "model": "Samsung SSD", "volumes": [
            {"id": "root", "name": "Root", "mountPoint": "/", "usedGB": 100, "totalGB": 10000,
             "availableGB": 9900, "isCriticalMount": true},
            {"id": "data", "name": "data", "mountPoint": "/data", "usedGB": 82, "totalGB": 100,
             "availableGB": 18, "isCriticalMount": true}]}]}
        """#.utf8)
        let disk = try JSONDecoder().decode(DiskMetrics.self, from: data)
        #expect(disk.worstVolume?.mountPoint == "/data")
        #expect(disk.pressure == .warning)
        #expect(disk.displayUsagePercent == 82)
        #expect(disk.deviceTemperatures.count == 1)
        #expect(disk.deviceTemperatures.first?.model == "Samsung SSD")
        let model = HostMetricsModel()
        model.update(from: .init(cpu: nil, memory: nil, gpu: nil, disk: disk, network: nil))
        #expect(model.diskVolumeHistory["data"] == [82])
        #expect(model.diskVolumeHistory["root"] == [1])
    }

    @Test(arguments: [(20.0, DiskPressure.healthy), (18.0, .warning),
                      (10.0, .warning), (9.0, .critical), (0.0, .critical)])
    func volumePressureUsesAvailableSpace(free: Double, expected: DiskPressure) {
        let volume = DiskVolume(id: "data", name: "data", mountPoint: "/data",
                                totalGB: 110, usedGB: 100 - free, availableGB: free)
        #expect(volume.pressure == expected) // 10 GiB reserved is not available.
        #expect(abs((volume.freePercent ?? -1) - free) < 0.000001)
    }

    @Test func legacyVolumesUseOSCriticalMountsAndFallbackFreeSpace() throws {
        for (platform, root, other, diskID) in [
            ("win32", "C:\\", "D:\\", "win_disks"),
            ("darwin", "/", "/Volumes/External", "disk3")
        ] {
            let primary = DiskVolume(id: "primary", name: "System", mountPoint: root,
                                     totalGB: 100, usedGB: 10)
            let secondary = DiskVolume(id: "other", name: "Other", mountPoint: other,
                                       totalGB: 100, usedGB: 99)
            var disk = DiskMetrics(disks: [
                PhysicalDisk(id: diskID, model: "Disk", volumes: [primary, secondary])
            ])
            // Older payloads omit the platform and new per-volume fields.
            #expect(disk.worstVolume?.id == "primary")
            #expect(disk.pressure == .healthy)
            disk.platform = platform
            #expect(disk.worstVolume?.id == "primary")
            #expect(secondary.pressure == .critical)
        }
        let unknown = DiskVolume(id: "empty", name: "", mountPoint: "/", totalGB: 0, usedGB: 0)
        #expect(unknown.freePercent == nil)
        #expect(unknown.pressure == .unknown)
    }

    @Test @MainActor func historiesAreBoundedAndMissingPayloadsDoNotInventSamples() throws {
        let model = HostMetricsModel()
        let sample = try payload(linux: true)
        for _ in 0..<35 { model.update(from: sample) }
        #expect(model.cpu.history.count == 30)
        #expect(model.memoryHistory.count == 30)
        #expect(model.gpuHistory.count == 30)
        #expect(model.diskVolumeHistory["/dev/disk3s3s1"]?.count == 30)
        model.update(from: .init(cpu: nil, memory: nil, gpu: nil, disk: nil, network: nil))
        #expect(model.memoryHistory.count == 30)
        #expect(model.gpuHistory.count == 30)
    }

    @Test func newPayloadFieldsCanBeNull() throws {
        let data = Data(#"""
        {"memory": {"usagePercent": 25, "total": 16, "used": 4, "app": 4,
                    "wired": 0, "compressed": 0, "free": 12, "swap": 0, "topProcesses": null},
         "disk": {"usagePercent": 50, "totalGB": 100, "usedGB": 50, "platform": null,
                  "temperatures": null, "disks": [{"id": "sda", "model": "Disk",
                  "volumes": [{"id": "/dev/sda1", "name": "Root", "mountPoint": "/",
                               "totalGB": 100, "usedGB": 50, "availableGB": null,
                               "isCriticalMount": null}]}]}}
        """#.utf8)
        let sample = try JSONDecoder().decode(HostMetricsModel.MetricsPayload.self, from: data)
        #expect(sample.memory?.topProcesses == nil)
        #expect(sample.disk?.temperatures == nil)
        #expect(sample.disk?.worstVolume?.freePercent == 50)
        #expect(sample.disk?.pressure == .healthy)
    }

    @Test func physicalInventoryDoesNotDuplicateLogicalVolumesOrInferPoolFreeSpace() throws {
        let data = Data(#"""
        {"usagePercent": 82, "totalGB": 100, "usedGB": 82, "platform": "linux",
         "physicalDisks": [
            {"id": "sda", "model": "SSD", "volumes": [], "totalGB": 200,
             "availableGB": null, "temperature": 42},
            {"id": "sdb", "model": "SSD", "volumes": [], "totalGB": 200,
             "availableGB": null, "temperature": null}],
         "disks": [{"id": "mapper/pool", "model": "Logical Volume", "volumes": [
            {"id": "data", "name": "Data", "mountPoint": "/data", "totalGB": 100,
             "usedGB": 82, "availableGB": 18}]}]}
        """#.utf8)
        let disk = try JSONDecoder().decode(DiskMetrics.self, from: data)
        #expect(disk.hardware.map(\.id) == ["sda", "sdb"])
        #expect(disk.hardware.first?.totalGB == 200)
        #expect(disk.hardware.first?.availableGB == nil)
        #expect(disk.volumes.count == 1)
        #expect(disk.pressure == .warning)
        #expect(disk.worstVolume?.freeGB == 18)
    }

    @Test func legacyDiskGroupIsNotPresentedAsPhysicalHardware() {
        let disk = DiskMetrics(disks: [PhysicalDisk(id: "win_disks", model: "Windows Disks", volumes: [])])
        #expect(disk.hardware.isEmpty)
    }

    @Test @MainActor func networkHistoryUsesRatesAndMissingSamplesDoNotInventTraffic() {
        let model = HostMetricsModel()
        #expect(!model.hasNetworkSample)
        for value in 0..<35 {
            model.update(from: .init(cpu: nil, memory: nil, gpu: nil, disk: nil,
                                    network: NetworkMetrics(downloadSpeed: Double(value), uploadSpeed: 0)))
        }
        #expect(model.hasNetworkSample)
        #expect(model.downloadHistory == (5..<35).map(Double.init))
        #expect(model.uploadHistory == Array(repeating: 0, count: 30))
        model.update(from: .init(cpu: nil, memory: nil, gpu: nil, disk: nil, network: nil))
        #expect(model.downloadHistory.count == 30)
        #expect(model.downloadHistory.last == 34)
    }

    @Test @MainActor func gpuIdentityWithoutTelemetryClearsLoadHistory() {
        let model = HostMetricsModel()
        model.update(from: .init(cpu: nil, memory: nil,
                                gpu: GPUMetrics(usagePercent: 25, modelName: "GPU"), disk: nil, network: nil))
        #expect(model.gpuHistory == [25])
        model.update(from: .init(cpu: nil, memory: nil,
                                gpu: GPUMetrics(modelName: "GPU", utilizationAvailable: false), disk: nil, network: nil))
        #expect(!model.gpu.hasUtilization)
        #expect(model.gpuHistory.isEmpty)
    }
}
