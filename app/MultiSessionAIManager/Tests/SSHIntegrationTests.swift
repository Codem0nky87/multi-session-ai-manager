import Testing
import Foundation
@testable import MultiSessionAIManager

// MARK: - Optional, env-gated real-sshd integration test (Task 3.4)
//
// This test exercises the REAL `NIOSSHTransport` against a real sshd. It is
// SKIPPED by default: the `.enabled(if:)` trait reads `MSAM_SSH_IT` from the
// environment, so with no env vars set the test is reported as skipped (never
// run, never failed) and the normal suite stays green without a network/SSH
// server.
//
// To run it for real, point it at a host you can reach and authenticate to with
// an ed25519 key, then pass the env so xcodebuild forwards it to the test
// process. The variables are read via `ProcessInfo` at the trait level and
// inside the test:
//
//   MSAM_SSH_IT=1            (required; must equal "1" to enable)
//   MSAM_SSH_HOST=<host>     (required; hostname or IP)
//   MSAM_SSH_PORT=<port>     (optional; default 22)
//   MSAM_SSH_USER=<user>     (required; ssh login user)
//   MSAM_SSH_KEY_SEED_HEX=<hex>   (key source A: 64 hex chars = 32-byte ed25519 seed)
//   MSAM_SSH_KEY_PATH=<path>      (key source B: unencrypted OpenSSH ed25519 private key)
//
// Provide exactly one of KEY_SEED_HEX or KEY_PATH. KEY_PATH is parsed with
// `KeyStore.parseEd25519Seed`; only unencrypted ed25519 keys are supported.
//
// xcodebuild forwards the launching process environment to the test runner, so:
//
//   env MSAM_SSH_IT=1 MSAM_SSH_HOST=example.com MSAM_SSH_USER=me \
//       MSAM_SSH_KEY_SEED_HEX=<64-hex> \
//       xcodebuild test -scheme MultiSessionAIManager \
//       -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M5)'
//
// (If your CI strips env, set it on the scheme's Test action / TestPlan instead;
// the var names above are what the code reads.)
//
// The host-key validator accepts ANY fingerprint for the integration run — this
// test is about transport plumbing, not host-key pinning (covered elsewhere).

private enum IT {
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["MSAM_SSH_IT"] == "1"
    }

    static func env(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key].flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Resolve the 32-byte ed25519 seed from SEED_HEX or KEY_PATH.
    static func resolveSeed() throws -> Data {
        if let hex = env("MSAM_SSH_KEY_SEED_HEX") {
            guard let seed = Data(hexString: hex), seed.count == 32 else {
                throw ITError("MSAM_SSH_KEY_SEED_HEX must be 64 hex chars (32-byte seed)")
            }
            return seed
        }
        if let path = env("MSAM_SSH_KEY_PATH") {
            let pem = try String(contentsOfFile: path, encoding: .utf8)
            return try KeyStore.parseEd25519Seed(pem: pem)
        }
        throw ITError("provide MSAM_SSH_KEY_SEED_HEX or MSAM_SSH_KEY_PATH")
    }

    static func requiredHost() throws -> Host {
        guard let address = env("MSAM_SSH_HOST") else { throw ITError("MSAM_SSH_HOST is required") }
        guard let user = env("MSAM_SSH_USER") else { throw ITError("MSAM_SSH_USER is required") }
        let port = env("MSAM_SSH_PORT").flatMap { Int($0) } ?? 22
        return Host(name: "it", address: address, port: port, username: user,
                    keyID: "it", defaultWorkdir: "/")
    }

    struct ITError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }
}

/// Thread-safe accumulator so the `@Sendable` `onOutput` closure can append bytes.
private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func append(_ d: Data) { lock.lock(); defer { lock.unlock() }; data.append(d) }
    var value: Data { lock.lock(); defer { lock.unlock() }; return data }
}

@Test(.enabled(if: IT.enabled))
func realSSHTransportRunsCommandAndOpensPTY() async throws {
    let host = try IT.requiredHost()
    let seed = try IT.resolveSeed()
    let key = SSHKeyMaterial(ed25519Seed: seed)

    let transport = NIOSSHTransport()
    try await transport.connect(host: host, key: key) { _ in true } // accept any host key for the IT

    // Non-interactive command.
    let out = try await transport.runCommand("echo msam_it_ok")
    #expect(out.contains("msam_it_ok"))

    // Interactive PTY: send a command, give the server a moment, read some bytes.
    let box = OutputBox()
    let channel = try await transport.openPTY(command: "", cols: 80, rows: 24) { data in
        box.append(data)
    }
    channel.send(Data("echo hi\n".utf8))
    try await Task.sleep(nanoseconds: 1_500_000_000) // 1.5s for the shell to echo back
    channel.close()

    let ptyText = String(decoding: box.value, as: UTF8.self)
    #expect(ptyText.contains("hi"))

    await transport.disconnect()
}

// MARK: - Hex decoding helper (test-local)

private extension Data {
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let hi = chars[i].hexDigitValue, let lo = chars[i + 1].hexDigitValue else { return nil }
            bytes.append(UInt8(hi << 4 | lo))
            i += 2
        }
        self.init(bytes)
    }
}
