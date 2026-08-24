import Foundation
import NIOCore
import NIOConcurrencyHelpers
import NIOSSH
@preconcurrency import Citadel

/// Real password-authenticated `KeyInstaller` built on Citadel. Used once, to push
/// a public key onto a host's `~/.ssh/authorized_keys` before the app switches to
/// key-only auth (`NIOSSHTransport`). Connection bootstrap, host-key validation
/// (shared `SSHFingerprintHostKeyValidator`) and `@unchecked Sendable` concurrency
/// model mirror `CitadelFileTransfer` / `NIOSSHTransport` exactly.
///
/// Concurrency: nio delivers IO on an `EventLoop`, not the main thread. The
/// `hostKeyValidator` is `@Sendable`; the mutable client lives behind a
/// `NIOLockedValueBox`, so the class is `@unchecked Sendable`. `@preconcurrency
/// import Citadel` because not all Citadel types carry Swift 6 Sendable
/// annotations.
///
/// Runtime-unverifiable here: this needs a live SSH server accepting password
/// auth, which the simulator/CI does not provide. Acceptance is "compiles,
/// conforms to the seam, uses the real Citadel password-auth API"; on-device
/// validation happens later.
final class CitadelKeyInstaller: KeyInstaller, @unchecked Sendable {

    private let clientBox = NIOLockedValueBox<SSHClient?>(nil)

    init() {}

    // MARK: - Connect

    func connect(host: Host, username: String, password: String,
                 hostKeyValidator: @escaping @Sendable (String) -> Bool) async throws {
        let auth = SSHAuthenticationMethod.passwordBased(username: username, password: password)
        let validator = SSHHostKeyValidator.custom(SSHFingerprintHostKeyValidator(accept: hostKeyValidator))

        let newClient: SSHClient
        do {
            newClient = try await SSHClient.connect(
                host: host.address,
                port: host.port,
                authenticationMethod: auth,
                hostKeyValidator: validator,
                reconnect: .never
            )
        } catch {
            throw Self.mapConnectError(error)
        }

        clientBox.withLockedValue { $0 = newClient }
    }

    /// Map a Citadel connect failure onto the seam's `KeyInstallError`. Citadel
    /// surfaces a password rejection as `AuthenticationFailed` or
    /// `SSHClientError.allAuthenticationOptionsFailed`; classify everything else
    /// (timeouts, refused connections, DNS) as `.unreachable`, falling back to
    /// `.other` when the description matches neither auth nor a known transport
    /// failure.
    private static func mapConnectError(_ error: Error) -> KeyInstallError {
        if error is AuthenticationFailed { return .authFailed }
        if case SSHClientError.allAuthenticationOptionsFailed = error { return .authFailed }

        switch SSHFailure.classify(message: String(describing: error)) {
        case .authRejected:
            return .authFailed
        case .unreachable:
            return .unreachable
        case .hostKeyMismatch, .unknown:
            return .other(String(describing: error))
        }
    }

    private func currentClient() throws -> SSHClient {
        guard let client = clientBox.withLockedValue({ $0 }) else {
            throw KeyInstallError.other("not connected")
        }
        return client
    }

    // MARK: - Run command

    func runCommand(_ cmd: String) async throws -> String {
        let client = try currentClient()
        do {
            let buffer = try await client.executeCommand(cmd, mergeStreams: true)
            return String(buffer: buffer)
        } catch {
            throw KeyInstallError.other("\(cmd): \(error)")
        }
    }

    // MARK: - Disconnect

    func disconnect() async {
        let c = clientBox.withLockedValue { value -> SSHClient? in
            let existing = value
            value = nil
            return existing
        }
        try? await c?.close()
    }
}
