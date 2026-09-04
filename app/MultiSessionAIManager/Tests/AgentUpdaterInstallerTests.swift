import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct AgentUpdaterInstallerTemplateTests {
    @Test func platformProbeParsesDarwinLinuxAndUnknown() throws {
        #expect(try AgentUpdaterInstaller.parseHostContext("MSAM_HOME=/Users/alice\nMSAM_OS=Darwin\nMSAM_UID=501")
            == AgentUpdaterHostContext(home: "/Users/alice", platform: .macOS, uid: 501))
        #expect(try AgentUpdaterInstaller.parseHostContext("MSAM_HOME=/home/alice\nMSAM_OS=Linux\nMSAM_UID=1000")
            == AgentUpdaterHostContext(home: "/home/alice", platform: .linux, uid: 1000))
        #expect(try AgentUpdaterInstaller.parseHostContext("MSAM_HOME=/home/alice\nMSAM_OS=FreeBSD\nMSAM_UID=1000")
            == AgentUpdaterHostContext(home: "/home/alice", platform: .unsupported("FreeBSD"), uid: 1000))
    }

    @Test func serviceFilesArePerUserAndContainNoPrivilegeOrSecretMechanism() {
        let mac = AgentUpdaterInstaller.launchAgent(
            helperPath: "/Users/alice/.local/libexec/msam-agent-updater",
            statePath: "/Users/alice/.local/state/msam-agent-updater"
        )
        let linux = AgentUpdaterInstaller.systemdUnit(
            helperPath: "/home/alice/.local/libexec/msam-agent-updater",
            statePath: "/home/alice/.local/state/msam-agent-updater"
        )
        let combined = (mac + linux).lowercased()

        #expect(mac.contains("com.codem0nky87.msam-agent-updater"))
        #expect(linux.contains("ExecStart=/home/alice/.local/libexec/msam-agent-updater service"))
        #expect(!combined.contains("sudo"))
        #expect(!combined.contains("password"))
        #expect(!combined.contains("user=root"))
        #expect(!combined.contains("/library/launchdaemons"))
    }

    @Test func servicePathsAreOwnedByTheSSHUser() {
        let context = AgentUpdaterHostContext(home: "/Users/alice", platform: .macOS, uid: 501)
        #expect(AgentUpdaterInstaller.helperPath(for: context)
            == "/Users/alice/.local/libexec/msam-agent-updater")
        #expect(AgentUpdaterInstaller.servicePath(for: context)
            == "/Users/alice/Library/LaunchAgents/com.codem0nky87.msam-agent-updater.plist")

        let linux = AgentUpdaterHostContext(home: "/home/alice", platform: .linux, uid: 1000)
        #expect(AgentUpdaterInstaller.servicePath(for: linux)
            == "/home/alice/.config/systemd/user/msam-agent-updater.service")
    }
}

@Suite @MainActor struct AgentUpdaterInstallerOperationTests {
    @Test func macOSInstallUploadsHelperAndLaunchAgentThenVerifies() async throws {
        let (installer, transport) = try await makeInstaller()
        stub(transport, [
            "MSAM_HOME=/Users/alice\nMSAM_OS=Darwin\nMSAM_UID=501",
            "login domain ready",
            "prepared",
            "bootstrapped",
            readyVerification(platform: "Darwin", linger: "n/a")
        ])

        await installer.installOrRepair(policy: .manualApproval)

        #expect(installer.state == .ready(AgentUpdaterServiceStatus(
            platform: .macOS, helperProtocol: 1, serviceActive: true,
            stateWritable: true, selfTestPassed: true, lingerEnabled: nil
        )))
        #expect(transport.writtenFiles["/Users/alice/.local/libexec/msam-agent-updater"]
            == Data("#!/bin/sh\nprintf ok\n".utf8))
        let plist = try #require(transport.writtenFiles[
            "/Users/alice/Library/LaunchAgents/com.codem0nky87.msam-agent-updater.plist"
        ])
        #expect(String(decoding: plist, as: UTF8.self).contains("LimitLoadToSessionType"))
        #expect(transport.structuredCommandsRun.allSatisfy {
            $0.timeout > .zero && $0.outputLimit == AgentUpdaterInstaller.outputLimit
        })
    }

    @Test func linuxInstallUsesSystemdUserAndReportsLingerDisabledSeparately() async throws {
        let (installer, transport) = try await makeInstaller()
        stub(transport, [
            "MSAM_HOME=/home/alice\nMSAM_OS=Linux\nMSAM_UID=1000",
            "prepared",
            "started",
            readyVerification(platform: "Linux", linger: "no")
        ])

        await installer.installOrRepair(policy: .manualApproval)

        guard case .approvalRequired(.linuxLingerDisabled(let instructions)) = installer.state else {
            Issue.record("expected Linux linger approval, got \(installer.state)")
            return
        }
        #expect(instructions.joined(separator: " ").contains("loginctl enable-linger alice"))
        #expect(transport.writtenFiles[
            "/home/alice/.config/systemd/user/msam-agent-updater.service"
        ] != nil)
        #expect(transport.commandsRun.contains { $0.contains("systemctl --user enable --now") })
    }

    @Test func unsupportedPlatformProducesInstructionsWithoutWritingFiles() async throws {
        let (installer, transport) = try await makeInstaller()
        stub(transport, ["MSAM_HOME=/home/alice\nMSAM_OS=FreeBSD\nMSAM_UID=1000"])

        await installer.installOrRepair(policy: .manualApproval)

        guard case .approvalRequired(.unsupportedPlatform(let message)) = installer.state else {
            Issue.record("expected unsupported platform, got \(installer.state)")
            return
        }
        #expect(message.contains("FreeBSD"))
        #expect(transport.writtenFiles.isEmpty)
    }

    @Test func finalVerificationNotCommandCompletionControlsReadyState() async throws {
        let (installer, transport) = try await makeInstaller()
        stub(transport, [
            "MSAM_HOME=/Users/alice\nMSAM_OS=Darwin\nMSAM_UID=501",
            "login domain ready",
            "prepared",
            "bootstrapped",
            "MSAM_VERIFY_BEGIN\nprotocol=1\nservice=active\nwritable=yes\nselftest=no\nplatform=Darwin\nlinger=n/a\nMSAM_VERIFY_END"
        ])

        await installer.installOrRepair(policy: .manualApproval)

        guard case .failed(let message) = installer.state else {
            Issue.record("expected verification failure, got \(installer.state)")
            return
        }
        #expect(message.contains("self-test"))
    }

    @Test func ambiguousDisconnectStillRunsFinalVerification() async throws {
        let (installer, transport) = try await makeInstaller()
        transport.structuredCommandResults = [
            result("MSAM_HOME=/Users/alice\nMSAM_OS=Darwin\nMSAM_UID=501"),
            result("login domain ready"),
            result("prepared"),
            .failure(.ambiguousDisconnect),
            result(readyVerification(platform: "Darwin", linger: "n/a"))
        ]

        await installer.installOrRepair(policy: .manualApproval)

        guard case .ready = installer.state else {
            Issue.record("final verification should be authoritative, got \(installer.state)")
            return
        }
        #expect(transport.structuredCommandsRun.count == 5)
    }

    @Test func macOSWithoutALoginDomainExplainsHowToApproveAndWritesNothing() async throws {
        let (installer, transport) = try await makeInstaller()
        transport.structuredCommandResults = [
            result("MSAM_HOME=/Users/alice\nMSAM_OS=Darwin\nMSAM_UID=501"),
            result("", exitStatus: 1)
        ]

        await installer.installOrRepair(policy: .manualApproval)

        guard case .approvalRequired(.macOSLoginDomain(let instructions)) = installer.state else {
            Issue.record("expected macOS login-domain approval, got \(installer.state)")
            return
        }
        #expect(instructions.joined(separator: " ").contains("Sign in"))
        #expect(instructions.joined(separator: " ").contains("Test Again"))
        #expect(transport.writtenFiles.isEmpty)
    }

    @Test func probeReportsAnAbsentHelperAsInstallable() async throws {
        let (installer, transport) = try await makeInstaller()
        transport.structuredCommandResults = [
            result("MSAM_HOME=/home/alice\nMSAM_OS=Linux\nMSAM_UID=1000"),
            result("", exitStatus: 1)
        ]

        await installer.probe()

        #expect(installer.state == .absent(.init(home: "/home/alice", platform: .linux, uid: 1000)))
    }

    private func makeInstaller() async throws -> (AgentUpdaterInstaller, FakeSSHTransport) {
        let keyStore = KeyStore(backing: InMemoryKeychain())
        let keyID = try keyStore.generateEd25519(label: "updater")
        let transport = FakeSSHTransport()
        let connection = HostConnection(
            host: Host(name: "h", address: "192.0.2.44", username: "alice",
                       keyID: keyID, defaultWorkdir: "/home/alice"),
            keyStore: keyStore,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: "msam.updater.\(UUID())")!),
            transport: transport
        )
        await connection.connect()
        return (AgentUpdaterInstaller(
            connection: connection,
            helperLoader: { Data("#!/bin/sh\nprintf ok\n".utf8) }
        ), transport)
    }

    private func stub(_ transport: FakeSSHTransport, _ outputs: [String]) {
        transport.structuredCommandResults = outputs.map { result($0) }
    }

    private func result(
        _ output: String,
        exitStatus: Int32 = 0
    ) -> Result<SSHCommandResult, SSHCommandExecutionError> {
        .success(.init(exitStatus: exitStatus, stdout: Data(output.utf8), stderr: Data()))
    }

    private func readyVerification(platform: String, linger: String) -> String {
        """
        shell noise
        MSAM_VERIFY_BEGIN
        protocol=1
        service=active
        writable=yes
        selftest=yes
        platform=\(platform)
        linger=\(linger)
        MSAM_VERIFY_END
        """
    }
}
