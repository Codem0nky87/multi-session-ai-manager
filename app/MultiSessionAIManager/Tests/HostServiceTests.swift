import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite @MainActor struct HostServiceTests {
    private let ready = #"MSAM_HOST_STATUS={"installed":true,"running":true,"disabled":false,"version":"1.0.0","metrics":true,"updates":true,"agents":true}"#

    @Test func statusIgnoresShellNoiseAndRemovedServiceStaysRemoved() throws {
        let status = try HostServiceInstaller.parseStatus("Welcome\n" + ready + "\n")
        #expect(status.running)
        #expect(status.metrics == true)
        let removed = try HostServiceInstaller.parseStatus(#"MSAM_HOST_STATUS={"installed":false,"running":false,"disabled":true,"version":"1.0.0"}"#)
        #expect(!removed.installed)
        #expect(removed.disabled)
    }

    @Test func componentVersionsDecodeAndOldAgentsStillParse() throws {
        let withComponents = try HostServiceInstaller.parseStatus(
            #"MSAM_HOST_STATUS={"installed":true,"running":true,"disabled":false,"version":"1.1.0","components":{"service":"1.1.0","metrics":"2.1.1"}}"#)
        #expect(withComponents.components?["metrics"] == "2.1.1")
        // Agents older than 1.1.0 send no components key at all.
        let legacy = try HostServiceInstaller.parseStatus(ready)
        #expect(legacy.components == nil)
    }

    @Test func manifestComparisonIdentifiesOutdatedHostScripts() throws {
        let expected = ["msam-metrics.py": "hash_v2", "msam-host-agent.py": "hash_v1"]
        let matching = ["msam-metrics.py": "hash_v2", "msam-host-agent.py": "hash_v1"]
        let outdated = ["msam-metrics.py": "hash_v1", "msam-host-agent.py": "hash_v1"]

        #expect(!HostServiceInstaller.isManifestOutdated(manifest: matching, expected: expected))
        #expect(HostServiceInstaller.isManifestOutdated(manifest: outdated, expected: expected))
        #expect(HostServiceInstaller.isManifestOutdated(manifest: nil, expected: expected))
        #expect(!HostServiceInstaller.isManifestOutdated(manifest: matching, expected: nil))
        #expect(!HostServiceInstaller.isManifestOutdated(manifest: matching, expected: [:]))
    }

    @Test func windowsCommandIsEncodedAndPreservesArguments() throws {
        let command = HostServiceInstaller.python("print('ok')", arguments: ["C:\\Users\\a's folder\\file"], isWindows: true)
        let encoded = try #require(command.split(separator: " ").last)
        let data = try #require(Data(base64Encoded: String(encoded)))
        let script = try #require(String(data: data, encoding: .utf16LittleEndian))
        #expect(script.contains("a''s folder"))
        #expect(script.contains("exit $LASTEXITCODE"))
    }

    @Test func windowsContextKeepsItsUserProfile() throws {
        let context = try AgentUpdaterInstaller.parseHostContext("MSAM_HOME=C:\\Users\\alice\nMSAM_OS=Windows_NT\nMSAM_UID=0")
        #expect(context.platform == .windows)
        #expect(context.home == "C:\\Users\\alice")
    }

    @Test func missingStatusPreservesHostDiagnostics() {
        do {
            _ = try HostServiceInstaller.parseStatus("", stderr: "python3: command not found")
            Issue.record("Missing status must not be accepted")
        } catch {
            #expect(error.localizedDescription.contains("python3: command not found"))
        }
        do {
            _ = try HostServiceInstaller.parseStatus("")
            Issue.record("Empty output must not be accepted")
        } catch {
            #expect(error.localizedDescription.contains("No command output was received"))
        }
    }

    @Test func refreshPublishesReadinessAndFailedProbeClearsStaleStatus() async throws {
        let (connection, transport) = try await connectedHost()
        var verified: [HostAgentUpdaterSetup] = []
        let manager = HostServiceManager(connection: connection) { verified.append($0.setupState) }
        transport.defaultCommandResponse = ready
        await manager.refresh()
        #expect(manager.installation?.running == true)
        #expect(verified == [.ready])

        transport.structuredCommandResults = [.success(.init(exitStatus: 0, stdout: Data(),
            stderr: Data("Python runtime unavailable".utf8)))]
        await manager.refresh()
        #expect(manager.installation == nil, "A failed check must not leave a stale installed/not-installed label")
        #expect(manager.error?.contains("Python runtime unavailable") == true)
        #expect(verified == [.ready], "Unknown status must not overwrite the saved setup flag")

        transport.defaultCommandResponse = #"MSAM_HOST_STATUS={"installed":true,"running":false,"disabled":false,"version":"1.0.0"}"#
        await manager.refresh()
        #expect(verified == [.ready, .unchecked])
        #expect(manager.error == nil)
        await connection.disconnect()
    }

    @Test func failedManagementClearsPreviousNotInstalledResultAndKeepsExitDetail() async throws {
        let (connection, transport) = try await connectedHost()
        var verified: [HostAgentUpdaterSetup] = []
        let manager = HostServiceManager(connection: connection) { verified.append($0.setupState) }
        transport.defaultCommandResponse = #"MSAM_HOST_STATUS={"installed":false,"running":false,"disabled":false,"version":""}"#
        await manager.refresh()
        transport.structuredCommandResults = [.success(.init(exitStatus: 1, stdout: Data(),
            stderr: Data("Failed to connect to user bus".utf8)))]
        await manager.perform("start")
        #expect(manager.installation == nil)
        #expect(manager.error?.contains("status 1") == true)
        #expect(manager.error?.contains("Failed to connect to user bus") == true)
        #expect(verified == [.unchecked])
        await connection.disconnect()
    }

    private func connectedHost() async throws -> (HostConnection, FakeSSHTransport) {
        let keyStore = KeyStore(backing: InMemoryKeychain())
        let key = try keyStore.generateEd25519(label: "host-service-status")
        let host = Host(name: "status-test", address: "198.51.100.25", username: "service-test", keyID: key, defaultWorkdir: "")
        let transport = FakeSSHTransport()
        let connection = HostConnection(host: host, keyStore: keyStore,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!), transport: transport)
        await connection.connect()
        return (connection, transport)
    }

    @Test @MainActor func lifecycleWithUpdateClearsStateOnFailureAndCooldownWorks() async throws {
        let host = Host(name: "cooldown-test", address: "198.51.100.30", username: "test", keyID: UUID().uuidString, defaultWorkdir: "")
        #expect(!HostMetricsLifecycle.shared.isUpdating(host))
        #expect(!HostMetricsLifecycle.shared.hasRecentFailure(host))

        do {
            try await HostMetricsLifecycle.shared.withUpdate(host) {
                #expect(HostMetricsLifecycle.shared.isUpdating(host))
                throw MSAMMetricsInstaller.Failure.uploadFailed("Simulated network timeout")
            }
            Issue.record("Expected error")
        } catch {
            #expect(!HostMetricsLifecycle.shared.isUpdating(host), "Lock must be released on failure")
        }

        HostMetricsLifecycle.shared.recordRecentFailure(host)
        #expect(HostMetricsLifecycle.shared.hasRecentFailure(host))
        HostMetricsLifecycle.shared.clearRecentFailure(host)
        #expect(!HostMetricsLifecycle.shared.hasRecentFailure(host))
    }

    @Test func maintenanceReplacesOnlyMetricsChannelsAndReconnectDoesNotUpload() async throws {
        let keyStore = KeyStore(backing: InMemoryKeychain())
        let key = try keyStore.generateEd25519(label: "host-service")
        let host = Host(name: "host-service", address: "198.51.100.25", username: "service-test", keyID: key, defaultWorkdir: "")
        let transport = FakeSSHTransport()
        let connection = HostConnection(host: host, keyStore: keyStore,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!), transport: transport)
        let session = HerdrHostSession(connection: connection, sessionName: nil)
        await session.start()
        let terminal = try #require(transport.openedPTYs.last)
        transport.defaultCommandResponse = ready
        await session.ensureMetricsStream()
        let metrics = try #require(transport.openedPTYs.last)
        #expect(metrics !== terminal)
        #expect(transport.writtenFiles.isEmpty)
        try await HostMetricsLifecycle.shared.begin(host)
        #expect(metrics.closed)
        #expect(!terminal.closed)
        await session.ensureMetricsStream()
        #expect(transport.openedPTYs.last === metrics)
        await HostMetricsLifecycle.shared.finish(host)
        #expect(transport.openedPTYs.last !== metrics)
        #expect(!terminal.closed)
        #expect(transport.writtenFiles.isEmpty)
        await session.stop()
    }

    @Test func metricsReportCommandFormatsProperlyForUnixAndWindows() throws {
        let unixAll = HostServiceInstaller.metricsReportCommand(period: nil, isWindows: false)
        #expect(unixAll.contains("msam-host-agent\" report --format json"))
        #expect(!unixAll.contains("--period"))

        let unix24h = HostServiceInstaller.metricsReportCommand(period: "24h", isWindows: false)
        #expect(unix24h.contains("report --format json --period '24h'"))

        let win7d = HostServiceInstaller.metricsReportCommand(period: "7d", isWindows: true)
        #expect(win7d.hasPrefix("powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand "))
        let encoded = try #require(win7d.split(separator: " ").last)
        let data = try #require(Data(base64Encoded: String(encoded)))
        let script = try #require(String(data: data, encoding: .utf16LittleEndian))
        #expect(script.contains("msam-host-agent.cmd\" report --format json --period '7d'"))
        #expect(script.contains("exit $LASTEXITCODE"))
    }

    @Test func openMonitorSpaceRunsExpectedCommand() async throws {
        let keyStore = KeyStore(backing: InMemoryKeychain())
        let key = try keyStore.generateEd25519(label: "host-service")
        let host = Host(name: "host-service", address: "198.51.100.25", username: "service-test", keyID: key, defaultWorkdir: "")
        let transport = FakeSSHTransport()
        let connection = HostConnection(host: host, keyStore: keyStore,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!), transport: transport)
        await connection.connect()
        let service = try #require(connection.provisioningCommandRunner)
        transport.defaultCommandResponse = "ok\n"
        try await HostServiceInstaller.openMonitorSpace(using: service)
        let lastCommand = try #require(transport.commandsRun.last)
        #expect(lastCommand.contains("python3"))
        #expect(lastCommand.contains("base64"))
    }

    @Test func hardwareDatabaseResourceIsBundledAndValid() throws {
        #expect(HostServiceInstaller.resources.contains("msam-hardware-db.json"))
        let data: Data
        if let bundleData = try? HostServiceInstaller.resource("msam-hardware-db.json") {
            data = bundleData
        } else {
            let projectURL = URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/msam-hardware-db.json")
            data = try Data(contentsOf: projectURL)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let root = try #require(json)
        #expect(root["version"] as? String == "2026.11.06.1")
        let systems = try #require(root["systems"] as? [String: Any])
        #expect(systems["NVIDIA DGX Spark"] != nil)
        let spark = try #require(systems["NVIDIA DGX Spark"] as? [String: Any])
        #expect(spark["soc_name"] as? String == "NVIDIA GB10")
        #expect(spark["soc_tdp_watts"] as? Double == 140.0)
        #expect(spark["psu_capacity_watts"] as? Double == 240.0)
        let cpu = try #require(root["cpu"] as? [String: Any])
        let amd = try #require(cpu["amd"] as? [String: Any])
        #expect(amd["Ryzen 9 9950X3D2"] != nil)
        let gpu = try #require(root["gpu"] as? [String: Any])
        let nvidia = try #require(gpu["nvidia"] as? [String: Any])
        #expect(nvidia["RTX 5090"] != nil)
    }
}
