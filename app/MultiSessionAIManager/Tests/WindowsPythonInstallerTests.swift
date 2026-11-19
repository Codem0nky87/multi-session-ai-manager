import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite @MainActor
struct WindowsPythonInstallerTests {
    // MARK: What the host says

    @Test func aHostWithPythonReportsItsVersion() {
        let probe = WindowsPythonInstaller.parse("MSAM_PYTHON=3.14.0\nMSAM_WINDOWS=server\nMSAM_STORE=no\nMSAM_WINGET=yes\n")
        #expect(probe == .init(version: "3.14.0", isServer: true, hasStore: false, hasWinget: true))
    }

    @Test func theStoresPlaceholderForPythonIsNotPython() {
        // Windows ships a python.exe that only says where to get Python.
        let output = """
        Python was not found; run without arguments to install from the Microsoft Store, or disable this shortcut from Settings > Apps > Advanced app settings > App execution aliases.
        MSAM_PYTHON=
        MSAM_WINDOWS=client
        MSAM_STORE=yes
        MSAM_WINGET=yes
        """
        #expect(WindowsPythonInstaller.parse(output) == .init(version: nil, isServer: false, hasStore: true, hasWinget: true))
    }

    @Test func aHostThatSaysNothingIsTakenForAServerWithNothingOnIt() {
        #expect(WindowsPythonInstaller.parse("") == .init(version: nil, isServer: true, hasStore: false, hasWinget: false))
    }

    @Test func aPythonTooOldForTheHostServiceDoesNotCount() {
        #expect(WindowsPythonInstaller.Probe(version: "3.9.0", isServer: true, hasStore: false, hasWinget: true).usableVersion == "3.9.0")
        #expect(WindowsPythonInstaller.Probe(version: "3.14.2", isServer: true, hasStore: false, hasWinget: true).usableVersion == "3.14.2")
        #expect(WindowsPythonInstaller.Probe(version: "3.8.10", isServer: true, hasStore: false, hasWinget: true).usableVersion == nil)
        #expect(WindowsPythonInstaller.Probe(version: "2.7.18", isServer: true, hasStore: false, hasWinget: true).usableVersion == nil)
    }

    @Test func aHostThatHasPythonIsAskedNothingElse() throws {
        // What it could install Python with takes the longest to find out and is not needed.
        let script = WindowsPythonInstaller.probeScript
        let answered = try #require(script.range(of: "if ($version) { exit 0 }"))
        let slower = try #require(script.range(of: "Get-CimInstance"))
        #expect(answered.lowerBound < slower.lowerBound)
    }

    // MARK: How to install it

    @Test func aClientWithTheStoreInstallsFromTheStore() {
        let plan = WindowsPythonInstaller.plan(for: .init(version: nil, isServer: false, hasStore: true, hasWinget: true))
        #expect(plan.command == WindowsPythonInstaller.storeCommand)
        #expect(plan.command?.contains("winget install 9NQ7512CXL7T") == true)
    }

    @Test func aServerInstallsForTheWholeMachineWithWinget() {
        let plan = WindowsPythonInstaller.plan(for: .init(version: nil, isServer: true, hasStore: true, hasWinget: true))
        #expect(plan.command == WindowsPythonInstaller.machineCommand)
        #expect(plan.command?.contains("Python.Python.3.14") == true)
        #expect(plan.command?.contains("--scope machine") == true)
    }

    @Test func aClientWithoutTheStoreInstallsLikeAServer() {
        let plan = WindowsPythonInstaller.plan(for: .init(version: nil, isServer: false, hasStore: false, hasWinget: true))
        #expect(plan.command == WindowsPythonInstaller.machineCommand)
    }

    @Test func aHostWithoutWingetIsToldWhereToGetPython() {
        let plan = WindowsPythonInstaller.plan(for: .init(version: nil, isServer: true, hasStore: false, hasWinget: false))
        #expect(plan.command == nil)
        #expect(plan.explanation.contains("python.org"))
    }

    @Test func neitherCommandCanStopToAskAQuestion() {
        // Nobody is at the host to answer one.
        for command in [WindowsPythonInstaller.storeCommand, WindowsPythonInstaller.machineCommand] {
            #expect(command.contains("--accept-package-agreements"))
            #expect(command.contains("--accept-source-agreements"))
            #expect(command.contains("--disable-interactivity"))
        }
    }

    // MARK: Against a host

    @Test func lookingForPythonInstallsNothing() async throws {
        let (installer, transport) = try await fixture()
        stub(transport, ["MSAM_PYTHON=3.14.0\nMSAM_WINDOWS=server\nMSAM_STORE=no\nMSAM_WINGET=yes"])
        await installer.probe()
        #expect(installer.state == .ready(version: "3.14.0"))
        #expect(installer.isReady)
        #expect(!scripts(transport).contains { $0.contains("winget install") })
    }

    @Test func aHostWithoutPythonGetsAPlan() async throws {
        let (installer, transport) = try await fixture()
        stub(transport, ["MSAM_PYTHON=\nMSAM_WINDOWS=server\nMSAM_STORE=no\nMSAM_WINGET=yes"])
        await installer.probe()
        #expect(installer.state == .absent(.init(command: WindowsPythonInstaller.machineCommand,
                                                 explanation: WindowsPythonInstaller.machineExplanation)))
        #expect(!installer.isReady)
    }

    @Test func installingRunsThePlanThenAsksTheHostAgain() async throws {
        let (installer, transport) = try await fixture()
        stub(transport, [absentOnServer])
        await installer.probe()
        stub(transport, ["Successfully installed", "MSAM_PYTHON=3.14.0\nMSAM_WINDOWS=server\nMSAM_STORE=no\nMSAM_WINGET=yes"])
        await installer.install()
        #expect(installer.state == .ready(version: "3.14.0"))
        let run = scripts(transport)
        let install = try #require(run.firstIndex { $0.contains(WindowsPythonInstaller.machineCommand) })
        let check = try #require(run.lastIndex { $0.contains("MSAM_PYTHON=") })
        #expect(install < check)
    }

    @Test func anInstallThatReportsFailureButLeavesPythonBehindSucceeded() async throws {
        // Over a slow link the channel can close before the installer's result arrives.
        let (installer, transport) = try await fixture()
        stub(transport, [absentOnServer])
        await installer.probe()
        transport.structuredCommandResults = [
            .failure(.ambiguousDisconnect),
            .success(.init(exitStatus: 0, stdout: Data("MSAM_PYTHON=3.14.0\nMSAM_WINDOWS=server\nMSAM_STORE=no\nMSAM_WINGET=yes".utf8), stderr: Data())),
        ]
        await installer.install()
        #expect(installer.state == .ready(version: "3.14.0"))
    }

    @Test func anInstallThatLeavesNoPythonSaysWhatTheHostSaid() async throws {
        let (installer, transport) = try await fixture()
        stub(transport, [absentOnServer])
        await installer.probe()
        transport.structuredCommandResults = [
            .success(.init(exitStatus: 1, stdout: Data("No package found matching input criteria.".utf8), stderr: Data())),
            .success(.init(exitStatus: 0, stdout: Data(absentOnServer.utf8), stderr: Data())),
        ]
        await installer.install()
        guard case .failed(let message, let plan) = installer.state else {
            Issue.record("Expected a failure, got \(installer.state)")
            return
        }
        #expect(message.contains("No package found matching input criteria."))
        // The command stays on screen: it can still be run at the host itself.
        #expect(plan?.command == WindowsPythonInstaller.machineCommand)
    }

    @Test func aHostThatCouldNotBeAskedIsNotSaidToLackPython() async throws {
        let (installer, transport) = try await fixture()
        transport.structuredCommandResults = [.failure(.timedOut)]
        await installer.probe()
        #expect(!installer.isReady)
        #expect(!installer.isMissing)
        stub(transport, [absentOnServer])
        await installer.probe()
        #expect(installer.isMissing)
    }

    @Test func nothingIsRunWhenTheHostHasNoWayToInstall() async throws {
        let (installer, transport) = try await fixture()
        stub(transport, ["MSAM_PYTHON=\nMSAM_WINDOWS=server\nMSAM_STORE=no\nMSAM_WINGET=no"])
        await installer.probe()
        let before = transport.commandsRun
        await installer.install()
        #expect(transport.commandsRun == before)
        #expect(!installer.canInstall)
    }

    // MARK: Fixture

    private let absentOnServer = "MSAM_PYTHON=\nMSAM_WINDOWS=server\nMSAM_STORE=no\nMSAM_WINGET=yes"

    private func stub(_ transport: FakeSSHTransport, _ outputs: [String]) {
        transport.structuredCommandResults = outputs.map {
            .success(.init(exitStatus: 0, stdout: Data($0.utf8), stderr: Data()))
        }
    }

    /// The PowerShell each command carried, decoded.
    private func scripts(_ transport: FakeSSHTransport) -> [String] {
        transport.commandsRun.compactMap(WindowsHostFixture.script)
    }

    private func fixture() async throws -> (WindowsPythonInstaller, FakeSSHTransport) {
        let (connection, transport) = try await WindowsHostFixture.connected()
        return (WindowsPythonInstaller(connection: connection), transport)
    }
}

/// A connected Windows host for tests.
@MainActor
enum WindowsHostFixture {
    static func connected() async throws -> (HostConnection, FakeSSHTransport) {
        let keys = KeyStore(backing: InMemoryKeychain())
        let id = try keys.generateEd25519(label: "windows")
        let transport = FakeSSHTransport()
        // What the connection asks to tell Windows from everything else.
        transport.commandResponses["echo %OS% $env:OS"] = "Windows_NT"
        let connection = HostConnection(
            host: Host(name: "Windows", address: "192.0.2.30", username: "Administrator", keyID: id, defaultWorkdir: ""),
            keyStore: keys,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: "windows.\(UUID())")!),
            transport: transport
        )
        await connection.connect()
        return (connection, transport)
    }

    /// The script inside a command sent to a Windows host.
    nonisolated static func script(_ command: String) -> String? {
        guard command.hasPrefix("powershell.exe "), let encoded = command.split(separator: " ").last,
              let data = Data(base64Encoded: String(encoded)) else { return nil }
        return String(data: data, encoding: .utf16LittleEndian)
    }
}
