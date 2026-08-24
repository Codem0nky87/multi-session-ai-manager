import Foundation
import Observation

enum InstallStep: Equatable { case connect, install, verify }

enum InstallPhase: Equatable {
    case idle, connecting, installing, verifying, success
    case failed(step: InstallStep, message: String)
}

@MainActor @Observable final class InstallKeyModel {
    private let host: Host
    private let publicKey: String
    private let keyMaterial: SSHKeyMaterial
    private let knownHosts: KnownHostsStore
    private let installer: KeyInstaller
    private let verify: @Sendable (SSHKeyMaterial) async -> Bool

    private(set) var phase: InstallPhase = .idle

    init(host: Host, publicKey: String, keyMaterial: SSHKeyMaterial,
         knownHosts: KnownHostsStore, installer: KeyInstaller,
         verify: @escaping @Sendable (SSHKeyMaterial) async -> Bool) {
        self.host = host; self.publicKey = publicKey; self.keyMaterial = keyMaterial
        self.knownHosts = knownHosts; self.installer = installer; self.verify = verify
    }

    func run(username: String, password: String) async {
        phase = .connecting
        let kh = knownHosts, knownHostsKey = host.knownHostsKey
        let validator: @Sendable (String) -> Bool = { fp in
            switch kh.verify(host: knownHostsKey, fingerprint: fp) {
            case .match: return true
            case .trustedNew: kh.pin(host: knownHostsKey, fingerprint: fp); return true
            case .mismatch: kh.pin(host: knownHostsKey, fingerprint: fp); return true // onboarding: (re)trust
            }
        }
        do {
            try await installer.connect(host: host, username: username, password: password,
                                        hostKeyValidator: validator)
        } catch {
            phase = .failed(step: .connect, message: Self.connectMessage(error)); return
        }
        phase = .installing
        do {
            _ = try await installer.runCommand(KeyInstallerScript.authorizedKeysInstallScript(publicKey: publicKey))
        } catch {
            await installer.disconnect()
            phase = .failed(step: .install, message: "Couldn't write the key on the host (permissions?)."); return
        }
        await installer.disconnect()
        phase = .verifying
        if await verify(keyMaterial) {
            phase = .success
        } else {
            phase = .failed(step: .verify, message: "Key didn't authenticate — the host may restrict it.")
        }
    }

    private static func connectMessage(_ error: Error) -> String {
        if case KeyInstallError.authFailed = error { return "Authentication failed — check the password." }
        return SSHFailure.classify(message: "\(error)").userMessage
    }
}
