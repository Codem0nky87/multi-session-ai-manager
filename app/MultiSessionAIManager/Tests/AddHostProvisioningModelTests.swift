import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite @MainActor
struct AddHostProvisioningModelTests {
    @Test func discoveryDoesNotInstallAnythingAndServicesWaitForHerdr() async throws {
        let (model, transport) = try await fixture()
        stub(transport, ["", "/usr/bin/curl"])
        await model.discover()
        #expect(model.herdr.state == .absent(curlAvailable: true))
        #expect(!model.herdrReady)
        let commands = transport.commandsRun
        await model.installServices()
        #expect(transport.commandsRun == commands)
        #expect(transport.writtenFiles.isEmpty)
        #expect(!model.canContinue)
    }

    @Test func missingHerdrIsInstalledAndVerifiedBeforeServiceSetup() async throws {
        let (model, transport) = try await fixture()
        stub(transport, ["", "/usr/bin/curl"])
        await model.discover()
        stub(transport, ["installed", "herdr 0.8.2"])
        await model.installHerdr()
        #expect(model.herdrReady)
        #expect(transport.writtenFiles.isEmpty)
        stub(transport, ["/home/alice", "", context, "present", verification()])
        await model.installServices()
        #expect(model.canContinue)
        #expect(model.updaterSetup == .ready)
        #expect(transport.writtenFiles["/home/alice/.local/bin/msam-metrics"] != nil)
        let commands = transport.commandsRun
        let install = try #require(commands.firstIndex { $0.contains("herdr.dev/install.sh") })
        let metrics = try #require(commands.firstIndex { $0.contains("mkdir -p") })
        #expect(install < metrics)
    }

    @Test func compatibleHerdrIsReusedWithoutReinstallation() async throws {
        let (model, transport) = try await fixture()
        stub(transport, ["herdr 0.10.0"])
        await model.discover()
        await model.installHerdr()
        #expect(model.herdrReady)
        #expect(!transport.commandsRun.contains { $0.contains("herdr.dev/install.sh") || $0.contains("herdr update") })
        #expect(!model.canContinue)
    }

    @Test func oldHerdrMustBeUpdatedBeforeServices() async throws {
        let (model, transport) = try await fixture()
        stub(transport, ["herdr 0.7.9"])
        await model.discover()
        #expect(!model.herdrReady)
        await model.installServices()
        #expect(transport.writtenFiles.isEmpty)
        stub(transport, ["updated", "herdr 0.8.2"])
        await model.installHerdr()
        #expect(model.herdrReady)
        #expect(transport.commandsRun.contains { $0.contains("herdr update --handoff") })
    }

    @Test func failedInstallDoesNotUnlockServicesOrNext() async throws {
        let (model, transport) = try await fixture()
        stub(transport, ["", "/usr/bin/curl"])
        await model.discover()
        stub(transport, ["download failed", "herdr: command not found"])
        await model.installHerdr()
        await model.installServices()
        #expect(!model.herdrReady)
        #expect(!model.canContinue)
        #expect(transport.writtenFiles.isEmpty)
    }

    @Test func missingCurlPreventsInstallation() async throws {
        let (model, transport) = try await fixture()
        stub(transport, ["", ""])
        await model.discover()
        let commands = transport.commandsRun
        await model.installHerdr()
        #expect(transport.commandsRun == commands)
        #expect(!model.canContinue)
    }

    @Test func metricsFailureDoesNotStartUpdaterOrReportSuccess() async throws {
        let (model, transport) = try await fixture()
        stub(transport, ["herdr 0.8.2"])
        await model.discover()
        stub(transport, ["not a home directory"])
        await model.installServices()
        #expect(!model.canContinue)
        #expect(model.updater.state == .idle)
        guard case .failed = model.metricsState else {
            Issue.record("Metrics upload should report its failure")
            return
        }
    }

    @Test func missingServiceIsInstalledAndVerified() async throws {
        let (model, transport) = try await fixture()
        stub(transport, ["herdr 0.8.2"])
        await model.discover()
        transport.structuredCommandResults = [
            result("/home/alice"), result(""), result(context), result("", exit: 1),
            result(context), result("prepared"), result("started"), result(verification())
        ]
        await model.installServices()
        #expect(model.canContinue)
        #expect(transport.writtenFiles["/home/alice/.local/libexec/msam-agent-updater"] != nil)
        #expect(transport.writtenFiles["/home/alice/.config/systemd/user/msam-agent-updater.service"] != nil)
    }

    @Test func serviceApprovalBlocksNextAndCanBeRetested() async throws {
        let (model, transport) = try await fixture()
        stub(transport, ["herdr 0.8.2"])
        await model.discover()
        stub(transport, ["/home/alice", "", context, "present", verification(linger: "no")])
        await model.installServices()
        #expect(!model.canContinue)
        #expect(model.updaterSetup == .failed)
        guard case .approvalRequired(.linuxLingerDisabled) = model.updater.state else {
            Issue.record("Expected actionable linger instructions")
            return
        }
        stub(transport, [context, "present", verification()])
        await model.installServices()
        #expect(model.canContinue)
        #expect(model.updaterSetup == .ready)
    }

    @Test func failedServiceVerificationDoesNotReportCompletion() async throws {
        let (model, transport) = try await fixture()
        stub(transport, ["herdr 0.8.2"])
        await model.discover()
        stub(transport, ["/home/alice", "", context, "present", verification(selfTest: "no"),
                         context, "prepared", "started", verification(selfTest: "no")])
        await model.installServices()
        #expect(!model.canContinue)
        #expect(model.updaterSetup == .failed)
    }

    @Test func cancelledOperationDoesNotStartServiceCommands() async throws {
        let (model, transport) = try await fixture()
        stub(transport, ["herdr 0.8.2"])
        await model.discover()
        let commands = transport.commandsRun
        let task = Task { @MainActor in await model.installServices() }
        task.cancel()
        await task.value
        #expect(transport.commandsRun == commands)
        #expect(!model.canContinue)
    }

    @Test func explicitSkipPreservesAUsableHostWithoutClaimingUpdaterReadiness() async throws {
        let (model, transport) = try await fixture()
        model.skipUpdater()
        #expect(!model.canContinue)
        #expect(model.updaterSetup == .unchecked)
        stub(transport, ["herdr 0.8.2"])
        await model.discover()
        stub(transport, ["/home/alice", "", context, "present", verification(linger: "no")])
        await model.installServices()
        #expect(!model.canContinue)
        model.skipUpdater()
        #expect(model.canContinue)
        #expect(model.updaterSetup == .skipped)
        stub(transport, [context, "present", verification()])
        await model.installServices()
        #expect(model.updaterSetup == .ready)
    }

    @Test func disconnectInvalidatesReadiness() async throws {
        let (model, transport) = try await fixture()
        stub(transport, ["herdr 0.8.2"])
        await model.discover()
        stub(transport, ["/home/alice", "", context, "present", verification()])
        await model.installServices()
        #expect(model.canContinue)
        await model.connection.disconnect()
        #expect(!model.canContinue)
    }

    private let context = "MSAM_HOME=/home/alice\nMSAM_OS=Linux\nMSAM_UID=1000"

    private func verification(linger: String = "yes", selfTest: String = "yes") -> String {
        "MSAM_VERIFY_BEGIN\nprotocol=1\nservice=active\nwritable=yes\nselftest=\(selfTest)\nplatform=Linux\nlinger=\(linger)\nMSAM_VERIFY_END"
    }

    private func result(_ output: String, exit: Int32 = 0) -> Result<SSHCommandResult, SSHCommandExecutionError> {
        .success(.init(exitStatus: exit, stdout: Data(output.utf8), stderr: Data()))
    }

    private func stub(_ transport: FakeSSHTransport, _ outputs: [String]) {
        transport.structuredCommandResults = outputs.map { result($0) }
    }

    private func fixture() async throws -> (AddHostProvisioningModel, FakeSSHTransport) {
        let keys = KeyStore(backing: InMemoryKeychain())
        let id = try keys.generateEd25519(label: "wizard")
        let transport = FakeSSHTransport()
        let connection = HostConnection(
            host: Host(name: "Test", address: "192.0.2.10", username: "alice", keyID: id, defaultWorkdir: ""),
            keyStore: keys,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: "wizard.\(UUID())")!),
            transport: transport
        )
        await connection.connect()
        return (AddHostProvisioningModel(connection: connection), transport)
    }
}
