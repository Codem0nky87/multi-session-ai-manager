import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite @MainActor
struct HerdrInstallerTests {
    // MARK: - Fixtures

    private func makeInstaller(
        transport: FakeSSHTransport,
        function: String = #function
    ) throws -> (HerdrInstaller, FakeSSHTransport) {
        let keyStore = KeyStore(backing: InMemoryKeychain())
        let keyID = try keyStore.generateEd25519(label: "herdr-installer")
        let suite = "msam.herdr-installer.\(function)"
        UserDefaults().removePersistentDomain(forName: suite)
        let connection = HostConnection(
            host: Host(
                name: "mac",
                address: "192.0.2.10",
                username: "alice",
                keyID: keyID,
                defaultWorkdir: "/Users/alice"
            ),
            keyStore: keyStore,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: suite)!),
            transport: transport
        )
        return (HerdrInstaller(connection: connection), transport)
    }

    private func ok(_ stdout: String, exit: Int32 = 0) -> Result<SSHCommandResult, SSHCommandExecutionError> {
        .success(SSHCommandResult(exitStatus: exit, stdout: Data(stdout.utf8), stderr: Data()))
    }

    private func fail(_ stderr: String, exit: Int32 = 1) -> Result<SSHCommandResult, SSHCommandExecutionError> {
        .success(SSHCommandResult(exitStatus: exit, stdout: Data(), stderr: Data(stderr.utf8)))
    }

    // MARK: - Version parsing

    @Test func parsesTheVersionHerdrActuallyPrints() {
        #expect(HerdrInstaller.parseVersion("herdr 0.8.2") == "0.8.2")
        #expect(HerdrInstaller.parseVersion("herdr 0.10.0\n") == "0.10.0")
        #expect(HerdrInstaller.parseVersion("  herdr 1.2.3  ") == "1.2.3")
        #expect(HerdrInstaller.parseVersion("not a version") == nil)
        #expect(HerdrInstaller.parseVersion("") == nil)
    }

    @Test func comparesVersionsNumericallyNotLexically() {
        // the bug a string compare would introduce: "0.10.0" < "0.8.2" lexically
        #expect(HerdrInstaller.meetsMinimum("0.10.0"))
        #expect(HerdrInstaller.meetsMinimum("0.8.2"))
        #expect(HerdrInstaller.meetsMinimum("1.0.0"))
        #expect(!HerdrInstaller.meetsMinimum("0.8.1"))
        #expect(!HerdrInstaller.meetsMinimum("0.7.9"))
    }

    // MARK: - Probe

    @Test func probeReportsAbsentWhenHerdrIsMissingButCurlExists() async throws {
        let transport = FakeSSHTransport()
        let (installer, _) = try makeInstaller(transport: transport)
        await installer.connection.connect()
        transport.structuredCommandResults = [
            ok(""),          // command -v herdr -> nothing
            ok("/usr/bin/curl"),
        ]

        await installer.probe()

        #expect(installer.state == .absent(curlAvailable: true))
    }

    @Test func probeReportsMissingCurlSoInstallIsNotOffered() async throws {
        let transport = FakeSSHTransport()
        let (installer, _) = try makeInstaller(transport: transport)
        await installer.connection.connect()
        transport.structuredCommandResults = [ok(""), ok("")]

        await installer.probe()

        #expect(installer.state == .absent(curlAvailable: false))
        #expect(!installer.canInstall)
    }

    @Test func probeReportsTheInstalledVersion() async throws {
        let transport = FakeSSHTransport()
        let (installer, _) = try makeInstaller(transport: transport)
        await installer.connection.connect()
        transport.structuredCommandResults = [ok("/opt/homebrew/bin/herdr\nherdr 0.8.2")]

        await installer.probe()

        #expect(installer.state == .present(version: "0.8.2"))
    }

    @Test func probeRequiresAnAuthenticatedConnection() async throws {
        let transport = FakeSSHTransport()
        let (installer, _) = try makeInstaller(transport: transport)
        // deliberately not connected

        await installer.probe()

        guard case .failed = installer.state else {
            Issue.record("Expected .failed without an authenticated connection, got \(installer.state)")
            return
        }
    }

    // MARK: - Install

    @Test func installRunsTheOfficialScriptThenVerifies() async throws {
        let transport = FakeSSHTransport()
        let (installer, _) = try makeInstaller(transport: transport)
        await installer.connection.connect()
        transport.structuredCommandResults = [
            ok("installed"),        // the install script
            ok("herdr 0.8.2"),      // verification
        ]

        await installer.install()

        #expect(installer.state == .ready(version: "0.8.2"))
        let ran = transport.structuredCommandsRun.map(\.command)
        #expect(ran.contains { $0.contains("herdr.dev/install.sh") })
        #expect(ran.contains { $0.contains("--version") })
    }

    /// Guards the bug the fake could not see: Citadel's exec path reports exit 0
    /// even for a failed command, so verification -- not exit status -- decides.
    @Test func aFailedInstallReportingExitZeroIsStillCaughtByVerification() async throws {
        let transport = FakeSSHTransport()
        let (installer, _) = try makeInstaller(transport: transport)
        await installer.connection.connect()
        transport.structuredCommandResults = [
            ok("curl: (6) could not resolve host", exit: 0),  // lies about success
            ok("command not found: herdr"),                    // verification tells the truth
        ]

        await installer.install()

        guard case .failed(let message) = installer.state else {
            Issue.record("Expected .failed, got \(installer.state)")
            return
        }
        #expect(message.contains("still not installed"))
        #expect(message.contains("could not resolve host"))
    }

    @Test func installFailureSurfacesStderrRatherThanASilentSuccess() async throws {
        let transport = FakeSSHTransport()
        let (installer, _) = try makeInstaller(transport: transport)
        await installer.connection.connect()
        transport.structuredCommandResults = [fail("curl: (6) could not resolve host")]

        await installer.install()

        guard case .failed(let message) = installer.state else {
            Issue.record("Expected .failed, got \(installer.state)")
            return
        }
        #expect(message.contains("could not resolve host"))
    }

    @Test func installThatYieldsTooOldAVersionIsAFailureNotSuccess() async throws {
        let transport = FakeSSHTransport()
        let (installer, _) = try makeInstaller(transport: transport)
        await installer.connection.connect()
        transport.structuredCommandResults = [ok("installed"), ok("herdr 0.7.1")]

        await installer.install()

        guard case .failed(let message) = installer.state else {
            Issue.record("Expected .failed for a below-minimum version, got \(installer.state)")
            return
        }
        #expect(message.contains("0.7.1"))
        #expect(message.contains("0.8.2"))
    }

    @Test func installThatProducesNoParsableVersionIsAFailure() async throws {
        let transport = FakeSSHTransport()
        let (installer, _) = try makeInstaller(transport: transport)
        await installer.connection.connect()
        transport.structuredCommandResults = [ok("installed"), ok("command not found: herdr")]

        await installer.install()

        guard case .failed = installer.state else {
            Issue.record("Expected .failed when the version cannot be parsed, got \(installer.state)")
            return
        }
    }

    // MARK: - Update

    @Test func updateRunsHerdrUpdateThenVerifies() async throws {
        let transport = FakeSSHTransport()
        let (installer, _) = try makeInstaller(transport: transport)
        await installer.connection.connect()
        transport.structuredCommandResults = [ok("updated"), ok("herdr 0.9.0")]

        await installer.update()

        #expect(installer.state == .ready(version: "0.9.0"))
        #expect(transport.structuredCommandsRun.map(\.command).contains { $0.contains("herdr update") })
    }

    // MARK: - Command surface

    @Test func theDisplayedCommandIsTheCommandThatRuns() async throws {
        let transport = FakeSSHTransport()
        let (installer, _) = try makeInstaller(transport: transport)
        await installer.connection.connect()
        transport.structuredCommandResults = [ok("installed"), ok("herdr 0.8.2")]

        let shown = HerdrInstaller.installCommand
        await installer.install()

        // what the UI promises the user and what we send must not drift apart
        #expect(transport.structuredCommandsRun.first?.command.contains(shown) == true)
    }

    @Test func theInstallBudgetCoversTheScriptsOwnRetryAllowance() {
        // herdr's installer allows 20s for the manifest plus 120s per download
        // and retries the download 3 times, so a budget under ~6 minutes can
        // expire mid-install on a slow link.
        #expect(HerdrInstaller.installTimeout >= .seconds(380))
    }

    @Test func anAmbiguousOutcomeNeverClaimsTheInstallFailed() async throws {
        let transport = FakeSSHTransport()
        let (installer, _) = try makeInstaller(transport: transport)
        await installer.connection.connect()
        transport.structuredCommandResults = [.failure(.ambiguousDisconnect)]

        await installer.install()

        guard case .failed(let message) = installer.state else {
            Issue.record("Expected .failed, got \(installer.state)")
            return
        }
        // the install may in fact have succeeded — the message must say so and
        // must point at the recovery, not assert a failure that did not happen
        #expect(message.lowercased().contains("may or may not"))
        #expect(message.contains("Try again"))
    }

    @Test func remoteCommandsAreBoundedSoAHungHostCannotStallTheSheet() async throws {
        let transport = FakeSSHTransport()
        let (installer, _) = try makeInstaller(transport: transport)
        await installer.connection.connect()
        transport.structuredCommandResults = [ok("installed"), ok("herdr 0.8.2")]

        await installer.install()

        for request in transport.structuredCommandsRun {
            #expect(request.timeout > .zero)
            #expect(request.outputLimit > 0)
        }
    }
}

/// A long install over a slow link can end with the channel closing before
/// Citadel sees a clean finish — while the installer on the host ran fine.
@Suite @MainActor struct HerdrInstallAmbiguousDisconnectTests {

    private func makeInstaller(_ transport: FakeSSHTransport) throws -> HerdrInstaller {
        let keyStore = KeyStore(backing: InMemoryKeychain())
        let keyID = try keyStore.generateEd25519(label: "install")
        return HerdrInstaller(connection: HostConnection(
            host: Host(name: "h", address: "10.0.0.1", username: "alice",
                       keyID: keyID, defaultWorkdir: "/home/alice"),
            keyStore: keyStore,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: "msam.inst.\(UUID())")!),
            transport: transport
        ))
    }

    private func stub(_ transport: FakeSSHTransport,
                      _ outcomes: [Result<String, SSHCommandExecutionError>]) {
        transport.structuredCommandResults = outcomes.map { outcome in
            outcome.map { SSHCommandResult(exitStatus: 0, stdout: Data($0.utf8), stderr: Data()) }
        }
    }

    @Test func anAmbiguousDisconnectDuringInstallStillVerifiesTheHost() async throws {
        // THE bug: a host reported "Herdr did not install" with Herdr sitting
        // installed on it, because the throw short-circuited past the check.
        let transport = FakeSSHTransport()
        let installer = try makeInstaller(transport)
        await installer.connection.connect()
        stub(transport, [
            .failure(.ambiguousDisconnect),   // install: channel died mid-download
            .success("herdr 0.8.2\n")         // verify: it actually landed
        ])

        await installer.install()

        #expect(installer.state == .ready(version: "0.8.2"))
    }

    @Test func aGenuineFailureStillReportsTheInstallError() async throws {
        // The install threw AND nothing is on the host: the install error is
        // more useful than "still not installed".
        let transport = FakeSSHTransport()
        let installer = try makeInstaller(transport)
        await installer.connection.connect()
        stub(transport, [
            .failure(.ambiguousDisconnect),
            .success("")                      // verify finds nothing
        ])

        await installer.install()

        guard case .failed = installer.state else {
            Issue.record("expected failure, got \(installer.state)")
            return
        }
    }

    @Test func aCleanInstallIsUnaffected() async throws {
        let transport = FakeSSHTransport()
        let installer = try makeInstaller(transport)
        await installer.connection.connect()
        stub(transport, [.success("installed ok\n"), .success("herdr 0.8.2\n")])

        await installer.install()

        #expect(installer.state == .ready(version: "0.8.2"))
    }

    @Test func aHostThatCannotBeReachedForVerificationReportsTheInstallError() async throws {
        let transport = FakeSSHTransport()
        let installer = try makeInstaller(transport)
        await installer.connection.connect()
        stub(transport, [.failure(.ambiguousDisconnect), .failure(.ambiguousDisconnect)])

        await installer.install()

        guard case .failed = installer.state else {
            Issue.record("expected failure, got \(installer.state)")
            return
        }
    }

    @Test func aTooOldVersionIsStillRejectedAfterAnAmbiguousInstall() async throws {
        // Recovering from the disconnect must not also skip the minimum-version
        // gate.
        let transport = FakeSSHTransport()
        let installer = try makeInstaller(transport)
        await installer.connection.connect()
        stub(transport, [.failure(.ambiguousDisconnect), .success("herdr 0.5.0\n")])

        await installer.install()

        guard case .failed(let message) = installer.state else {
            Issue.record("expected failure, got \(installer.state)")
            return
        }
        #expect(message.contains("0.5.0"))
    }
}
