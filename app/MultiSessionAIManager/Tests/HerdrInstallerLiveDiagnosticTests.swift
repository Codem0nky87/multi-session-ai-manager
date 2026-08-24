import Foundation
import Testing
@testable import MultiSessionAIManager

/// DIAGNOSTIC ONLY — drives the REAL `NIOSSHTransport` against this Mac's sshd
/// to reproduce a failure the fake cannot: a remote command that exits non-zero
/// with no output, which is what a host without Herdr produces.
///
/// Requires `/tmp/msam-diag-seed.hex` (a raw ed25519 seed whose public key is in
/// this Mac's `authorized_keys`). Skips cleanly when that file is absent, so it
/// is inert on any other machine and in CI.
@Suite(.serialized) @MainActor
struct HerdrInstallerLiveDiagnosticTests {
    private static var seed: Data? {
        guard let hex = try? String(contentsOfFile: "/tmp/msam-diag-seed.hex", encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            hex.count == 64
        else { return nil }
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    /// Returns nil when this machine is not set up to run the diagnostic.
    ///
    /// "Set up" means BOTH a seed file and a matching entry in this Mac's
    /// `authorized_keys`. A stale seed whose public half was since rotated out
    /// is not a product failure -- connecting is this test's setup, not its
    /// subject -- so an auth failure skips exactly like a missing file.
    private func connect() async throws -> (SSHService, NIOSSHTransport)? {
        guard let seed = Self.seed else { return nil }
        let host = Host(
            name: "localhost",
            address: "127.0.0.1",
            port: 22,
            // Whoever is running the suite -- never a hardcoded name. The seed
            // in `/tmp/msam-diag-seed.hex` is authorized against THIS account's
            // `authorized_keys`, so any other username turns a clean skip into
            // an authentication failure on someone else's machine.
            username: NSUserName(),
            keyID: "diagnostic",
            defaultWorkdir: NSHomeDirectory()
        )
        print("DIAG: NSUserName()=\(NSUserName()) home=\(NSHomeDirectory())")
        let transport = NIOSSHTransport()
        let knownHosts = KnownHostsStore(defaults: UserDefaults(suiteName: "msam.diag.\(UUID())")!)
        let service = SSHService(host: host, transport: transport, knownHosts: knownHosts)
        do {
            try await service.connect(key: SSHKeyMaterial(ed25519Seed: seed)) { _, _ in true }
        } catch {
            print("SKIP: /tmp/msam-diag-seed.hex is present but not authorized here (\(error))")
            return nil
        }
        return (service, transport)
    }

    @Test func nonZeroExitWithNoOutputDoesNotSurfaceAsAmbiguousDisconnect() async throws {
        guard let (service, _) = try await connect() else {
            print("SKIP: no /tmp/msam-diag-seed.hex")
            return
        }
        defer { Task { await service.disconnect() } }

        // exactly the probe HerdrInstaller runs on a host WITHOUT herdr:
        // short-circuits, exits 1, produces nothing on stdout or stderr.
        do {
            let result = try await service.run(
                "command -v herdrDefinitelyNotInstalled >/dev/null 2>&1 && herdrDefinitelyNotInstalled --version",
                timeout: .seconds(15),
                outputLimit: 64 * 1024
            )
            print("DIAG: returned exit=\(result.exitStatus) stdout=\(result.stdoutString.debugDescription) stderr=\(result.stderrString.debugDescription)")
            // The invariant that matters: a command that runs to completion must
            // RETURN, not throw. Citadel does not surface a remote exit status on
            // this path, so stdout -- not exitStatus -- is what callers may trust.
            #expect(result.stdoutString.isEmpty)
        } catch let error as SSHCommandExecutionError {
            Issue.record("DIAG: threw \(error) instead of returning a non-zero result — this is the .24 failure")
            throw error
        }
    }

    @Test func zeroExitWithOutputStillWorks() async throws {
        guard let (service, _) = try await connect() else {
            print("SKIP: no /tmp/msam-diag-seed.hex")
            return
        }
        defer { Task { await service.disconnect() } }

        let result = try await service.run("echo DIAG_OK", timeout: .seconds(15), outputLimit: 64 * 1024)
        print("DIAG: exit=\(result.exitStatus) stdout=\(result.stdoutString.debugDescription)")
        #expect(result.stdoutString.contains("DIAG_OK"))
    }
}
