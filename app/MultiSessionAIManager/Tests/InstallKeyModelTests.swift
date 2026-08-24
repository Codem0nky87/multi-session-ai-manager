import Testing
import Foundation
@testable import MultiSessionAIManager

@MainActor
private func makeModel(installer: FakeKeyInstaller,
                      verify: @escaping @Sendable (SSHKeyMaterial) async -> Bool) -> InstallKeyModel {
    let suite = "installkey.\(UUID().uuidString)"
    UserDefaults().removePersistentDomain(forName: suite)
    let host = Host(name: "m", address: "1.2.3.4", port: 22, username: "",
                    keyID: "k", defaultWorkdir: "")
    return InstallKeyModel(host: host,
                           publicKey: "ssh-ed25519 AAAA msam",
                           keyMaterial: SSHKeyMaterial(ed25519Seed: Data(count: 32)),
                           knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: suite)!),
                           installer: installer,
                           verify: verify)
}

@Test @MainActor func happyPathReachesSuccessAndRunsInstall() async {
    let inst = FakeKeyInstaller()
    let m = makeModel(installer: inst, verify: { _ in true })
    await m.run(username: "alice", password: "pw")
    #expect(m.phase == .success)
    #expect(inst.commandsRun.contains { $0.contains("authorized_keys") })
}

@Test @MainActor func connectFailureStopsAtConnect() async {
    let inst = FakeKeyInstaller(); inst.connectError = KeyInstallError.authFailed
    let m = makeModel(installer: inst, verify: { _ in true })
    await m.run(username: "alice", password: "bad")
    guard case .failed(let step, let msg) = m.phase else { #expect(Bool(false)); return }
    #expect(step == .connect)
    #expect(msg.contains("password"))   // auth-failed friendly message
    #expect(inst.commandsRun.isEmpty)   // never ran install
}

@Test @MainActor func installFailureStopsAtInstall() async {
    let inst = FakeKeyInstaller(); inst.commandError = KeyInstallError.installFailed("nope")
    let m = makeModel(installer: inst, verify: { _ in true })
    await m.run(username: "alice", password: "pw")
    guard case .failed(let step, _) = m.phase else { #expect(Bool(false)); return }
    #expect(step == .install)
}

@Test @MainActor func verifyFailureStopsAtVerify() async {
    let inst = FakeKeyInstaller()
    let m = makeModel(installer: inst, verify: { _ in false })
    await m.run(username: "alice", password: "pw")
    guard case .failed(let step, _) = m.phase else { #expect(Bool(false)); return }
    #expect(step == .verify)
}

@Test @MainActor func trustsNewHostKeyDuringConnect() async {
    let inst = FakeKeyInstaller(); inst.hostKeyToPresent = "FPNEW"
    let suite = "installkey.tofu.\(UUID().uuidString)"
    UserDefaults().removePersistentDomain(forName: suite)
    let kh = KnownHostsStore(defaults: UserDefaults(suiteName: suite)!)
    let host = Host(name: "m", address: "9.9.9.9", port: 22, username: "", keyID: "k", defaultWorkdir: "")
    let m = InstallKeyModel(host: host, publicKey: "ssh-ed25519 AAAA msam",
                            keyMaterial: SSHKeyMaterial(ed25519Seed: Data(count: 32)),
                            knownHosts: kh, installer: inst, verify: { _ in true })
    await m.run(username: "alice", password: "pw")
    #expect(m.phase == .success)
    #expect(kh.verify(host: "9.9.9.9", fingerprint: "FPNEW") == .match)  // pinned during connect
}
