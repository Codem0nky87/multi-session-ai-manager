import Foundation
import Testing
@testable import MultiSessionAIManager

private final class TBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) { stored = value }

    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func mutate(_ body: (inout T) -> Void) {
        lock.withLock { body(&stored) }
    }
}

private func makeHost(workdir: String) -> Host {
    Host(
        name: "mac",
        address: "1.2.3.4",
        port: 22,
        username: "u",
        keyID: "k",
        defaultWorkdir: workdir
    )
}

private func freshKnownHosts(_ function: String) -> KnownHostsStore {
    let suite = "msam.knownhosts.\(function)"
    UserDefaults().removePersistentDomain(forName: suite)
    return KnownHostsStore(defaults: UserDefaults(suiteName: suite)!)
}

private let key = SSHKeyMaterial(ed25519Seed: Data(repeating: 7, count: 32))

@Test func tofuTrustNewThenMatchThenMismatch() async throws {
    let knownHosts = freshKnownHosts(#function)

    let firstTransport = FakeSSHTransport()
    firstTransport.hostKeyToPresent = "FPONE"
    let verdicts = TBox<[HostKeyVerdict]>([])
    let first = SSHService(
        host: makeHost(workdir: "/w"),
        transport: firstTransport,
        knownHosts: knownHosts
    )
    try await first.connect(key: key) { fingerprint, verdict in
        verdicts.mutate { $0.append(verdict) }
        #expect(fingerprint == "FPONE")
        return true
    }
    #expect(firstTransport.isConnected)
    #expect(verdicts.value == [.trustedNew])
    #expect(knownHosts.verify(host: "1.2.3.4", fingerprint: "FPONE") == .match)

    let matchingTransport = FakeSSHTransport()
    matchingTransport.hostKeyToPresent = "FPONE"
    let matchingCallbackCalled = TBox(false)
    let matching = SSHService(
        host: makeHost(workdir: "/w"),
        transport: matchingTransport,
        knownHosts: knownHosts
    )
    try await matching.connect(key: key) { _, _ in
        matchingCallbackCalled.value = true
        return false
    }
    #expect(matchingTransport.isConnected)
    #expect(!matchingCallbackCalled.value)

    let changedTransport = FakeSSHTransport()
    changedTransport.hostKeyToPresent = "FPTWO"
    let mismatchVerdict = TBox<HostKeyVerdict?>(nil)
    let changed = SSHService(
        host: makeHost(workdir: "/w"),
        transport: changedTransport,
        knownHosts: knownHosts
    )
    await #expect(throws: SSHTransportError.self) {
        try await changed.connect(key: key) { _, verdict in
            mismatchVerdict.value = verdict
            return false
        }
    }
    #expect(mismatchVerdict.value == .mismatch)
    #expect(!changedTransport.isConnected)
    #expect(knownHosts.verify(host: "1.2.3.4", fingerprint: "FPONE") == .match)
}

@Test func tofuPinsNonDefaultPortSeparatelyFromDefaultPort() async throws {
    let knownHosts = freshKnownHosts(#function)
    let host = Host(
        name: "hermes",
        address: "1.2.3.4",
        port: 2222,
        username: "u",
        keyID: "k",
        defaultWorkdir: "/w"
    )
    let transport = FakeSSHTransport()
    transport.hostKeyToPresent = "FP2222"
    let service = SSHService(host: host, transport: transport, knownHosts: knownHosts)

    try await service.connect(key: key) { _, verdict in
        #expect(verdict == .trustedNew)
        return true
    }

    #expect(knownHosts.verify(host: "[1.2.3.4]:2222", fingerprint: "FP2222") == .match)
    #expect(knownHosts.verify(host: "1.2.3.4", fingerprint: "FP2222") == .trustedNew)
}

@Test func provisioningRunnerUsesBoundedNonInteractiveLoginShell() async throws {
    let transport = FakeSSHTransport()
    let service = SSHService(
        host: makeHost(workdir: "/w"),
        transport: transport,
        knownHosts: freshKnownHosts(#function)
    )
    try await service.connect(key: key) { _, _ in true }
    transport.structuredCommandResults = [
        .success(.init(
            exitStatus: 3,
            stdout: Data("out".utf8),
            stderr: Data("err".utf8)
        ))
    ]

    let result = try await service.run(
        "printf 'a'; printf 'b' >&2",
        timeout: .seconds(7),
        outputLimit: 123
    )

    #expect(result.exitStatus == 3)
    #expect(result.stdoutString == "out")
    #expect(result.stderrString == "err")
    let request = try #require(transport.structuredCommandsRun.first)
    #expect(request.command == "$SHELL -lc 'PATH=\"$HOME/.local/bin:$PATH\"; export PATH; printf '\\''a'\\''; printf '\\''b'\\'' >&2'")
    #expect(!request.command.contains("2>/dev/null"))
    #expect(request.timeout == .seconds(7))
    #expect(request.outputLimit == 123)
}
