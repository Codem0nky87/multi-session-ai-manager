import Foundation

/// One-shot, password-authenticated SSH helper used only to install a public key
/// onto a host. Separate from the key-only `SSHTransport` seam.
protocol KeyInstaller: AnyObject, Sendable {
    func connect(host: Host, username: String, password: String,
                 hostKeyValidator: @escaping @Sendable (String) -> Bool) async throws
    func runCommand(_ cmd: String) async throws -> String
    func disconnect() async
}

enum KeyInstallError: Error, Equatable {
    case authFailed, unreachable, installFailed(String), verifyFailed, other(String)
}

/// Shell-script helpers for key installation. A namespace enum rather than a
/// static-on-protocol extension because Swift does not permit calling a static
/// member on a protocol metatype (`(any KeyInstaller).Type`).
enum KeyInstallerScript {
    /// Idempotent, shell-safe command that ensures ~/.ssh exists with correct perms
    /// and appends `publicKey` to authorized_keys only if the exact line is absent.
    static func authorizedKeysInstallScript(publicKey: String) -> String {
        let q = shellSingleQuote(publicKey)
        return [
            "mkdir -p ~/.ssh",
            "chmod 700 ~/.ssh",
            "touch ~/.ssh/authorized_keys",
            "chmod 600 ~/.ssh/authorized_keys",
            "grep -qxF \(q) ~/.ssh/authorized_keys || echo \(q) >> ~/.ssh/authorized_keys",
        ].joined(separator: " && ")
    }

    static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
