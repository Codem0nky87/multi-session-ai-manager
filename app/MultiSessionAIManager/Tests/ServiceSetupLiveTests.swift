import Foundation
import Testing
@testable import MultiSessionAIManager

/// Writes only inside the disposable fixture directory. SFTP is disabled.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MSAM_SSH_IT"] == "1"))
@MainActor
struct ServiceSetupLiveTests {
    private struct Fixture: Decodable { let root: String; let port: Int; let username: String }

    private func connect() async throws -> (SSHService, String) {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            URL(fileURLWithPath: ProcessInfo.processInfo.environment["MSAM_SSH_FIXTURE"]!)))
        let key = SSHKeyMaterial(ed25519Seed: try KeyStore.parseEd25519Seed(
            pem: String(contentsOfFile: fixture.root + "/client_key", encoding: .utf8)))
        let service = SSHService(host: Host(name: "Fixture", address: "127.0.0.1", port: fixture.port,
            username: fixture.username, keyID: "fixture", defaultWorkdir: ""), transport: NIOSSHTransport(),
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        // Redirect provisioning's HOME into the fixture. Never touch the real
        // user's ~/.local files or register a real user service in these tests.
        let script = "#!/bin/sh\nexport HOME=\(POSIXShell.quote(fixture.root))\nexec /bin/sh -c \"$2\"\n"
        try executable(script, at: fixture.root + "/fixture-shell")
        try await service.connect(key: key) { _, _ in true }
        return (service, fixture.root)
    }

    @Test func metricsInstallWorksWithoutSFTP() async throws {
        let (service, root) = try await connect()
        defer { Task { await service.disconnect() } }
        try await SSHCommandDeadline.run(timeout: .seconds(10)) {
            try await MSAMMetricsInstaller.install(using: service)
        }
        let destination = root + "/.local/bin/msam-metrics"
        let installed = try Data(contentsOf: URL(fileURLWithPath: destination))
        let bundled = try Data(contentsOf: #require(Bundle.main.url(forResource: "msam-metrics", withExtension: "py")))
        #expect(installed == bundled)
        #expect(FileManager.default.isExecutableFile(atPath: destination))
    }

    @Test func execUploadPreservesBytesAndOriginalFileOnFailure() async throws {
        let (service, root) = try await connect()
        defer { Task { await service.disconnect() } }
        let destination = root + "/quote's $literal\nfile"
        let bytes = Data((0..<65_536).map { UInt8($0 % 256) })
        try await service.writeSetupFile(bytes, to: destination)
        #expect(try Data(contentsOf: URL(fileURLWithPath: destination)) == bytes)
        try await service.writeSetupFile(Data(), to: destination)
        #expect(try Data(contentsOf: URL(fileURLWithPath: destination)).isEmpty)
        let locked = root + "/upload-locked"
        try FileManager.default.createDirectory(atPath: locked, withIntermediateDirectories: true)
        let original = URL(fileURLWithPath: locked + "/original")
        try Data("original".utf8).write(to: original)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked) }
        await #expect(throws: SSHSetupFileUpload.Failure.self) {
            try await service.writeSetupFile(Data("replacement".utf8), to: original.path)
        }
        #expect(try Data(contentsOf: original) == Data("original".utf8))
    }

    @Test func linuxSetupFindsUserBusWithoutSSHSessionVariables() async throws {
        let (service, root) = try await connect()
        defer { Task { await service.disconnect() } }
        let context = AgentUpdaterHostContext(home: root, platform: .linux, uid: 4242)
        _ = try await service.run(AgentUpdaterInstaller.prepareCommand(for: context), timeout: .seconds(10), outputLimit: 4096)
        let helper = try Data(contentsOf: #require(Bundle.main.url(forResource: "msam-agent-updater", withExtension: "sh")))
        try await service.writeSetupFile(helper, to: AgentUpdaterInstaller.helperPath(for: context))
        try await service.writeSetupFile(Data(AgentUpdaterInstaller.systemdUnit(
            helperPath: AgentUpdaterInstaller.helperPath(for: context),
            statePath: AgentUpdaterInstaller.statePath(for: context)).utf8), to: AgentUpdaterInstaller.servicePath(for: context))
        let bin = root + "/mockbin"
        try FileManager.default.createDirectory(atPath: bin, withIntermediateDirectories: true)
        try executable("""
        #!/bin/sh
        [ "$XDG_RUNTIME_DIR" = /run/user/4242 ] || exit 1
        [ "$DBUS_SESSION_BUS_ADDRESS" = unix:path=/run/user/4242/bus ] || exit 1
        case "$*" in
          '--user enable --now msam-agent-updater.service') touch "$HOME/service-started" ;;
          '--user is-active --quiet msam-agent-updater.service') test -f "$HOME/service-started" ;;
          '--user daemon-reload') exit 0 ;;
          *) exit 1 ;;
        esac
        """, at: bin + "/systemctl")
        try executable("#!/bin/sh\nprintf 'yes\\n'\n", at: bin + "/loginctl")
        func isolated(_ command: String) -> String {
            let script = "PATH=\(POSIXShell.quote(bin)):$PATH; export PATH; " + command
            return "env -u XDG_RUNTIME_DIR -u DBUS_SESSION_BUS_ADDRESS /bin/sh -c \(POSIXShell.quote(script))"
        }
        let start = try await service.run(isolated(AgentUpdaterInstaller.finaliseCommand(for: context)
            + "\nprintf 'MSAM_SERVICE_START_OK\\n'"), timeout: .seconds(10), outputLimit: 4096)
        #expect(start.stdoutString.contains("MSAM_SERVICE_START_OK"))
        let result = try await service.run(isolated(AgentUpdaterInstaller.verificationCommand(for: context)),
                                           timeout: .seconds(10), outputLimit: 4096)
        let status = try AgentUpdaterInstaller.parseVerification(result.stdoutString, platform: .linux)
        #expect(status.isReady)
        #expect(status.lingerEnabled == true)
    }

    private func executable(_ script: String, at path: String) throws {
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }
}
