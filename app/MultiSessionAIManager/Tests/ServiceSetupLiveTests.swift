import Foundation
import Testing
@testable import MultiSessionAIManager

/// Writes only inside the disposable fixture directory. SFTP is disabled.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MSAM_SSH_IT"] == "1"))
@MainActor
struct ServiceSetupLiveTests {
    private struct Fixture: Decodable { let root: String; let port: Int; let username: String }

    @Test func metricsInstallWorksWithoutSFTP() async throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            URL(fileURLWithPath: ProcessInfo.processInfo.environment["MSAM_SSH_FIXTURE"]!)))
        let key = SSHKeyMaterial(ed25519Seed: try KeyStore.parseEd25519Seed(
            pem: String(contentsOfFile: fixture.root + "/client_key", encoding: .utf8)))
        let transport = NIOSSHTransport()
        let service = SSHService(host: Host(name: "Fixture", address: "127.0.0.1", port: fixture.port,
            username: fixture.username, keyID: "fixture", defaultWorkdir: ""), transport: transport,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        try await service.connect(key: key) { _, _ in true }
        defer { Task { await service.disconnect() } }
        // A shell wrapper redirects only provisioning's HOME into the fixture;
        // no ~/.local files or user services outside the fixture are touched.
        let shell = fixture.root + "/fixture-shell"
        let script = "#!/bin/sh\nexport HOME=\(POSIXShell.quote(fixture.root))\nexec /bin/sh -c \"$2\"\n"
        try script.write(toFile: shell, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: shell)
        // The fixture server sets SHELL to its wrapper for each exec request.
        try await SSHCommandDeadline.run(timeout: .seconds(10)) {
            try await MSAMMetricsInstaller.install(using: service)
        }
        let destination = fixture.root + "/.local/bin/msam-metrics"
        let installed = try Data(contentsOf: URL(fileURLWithPath: destination))
        let bundled = try Data(contentsOf: #require(Bundle.main.url(forResource: "msam-metrics", withExtension: "py")))
        #expect(installed == bundled)
        #expect(FileManager.default.isExecutableFile(atPath: destination))
    }
}
