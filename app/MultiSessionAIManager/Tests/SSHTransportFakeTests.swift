import Testing
import Foundation
@testable import MultiSessionAIManager

private func host() -> Host {
    Host(name: "mac", address: "1.2.3.4", port: 22, username: "u", keyID: "k", defaultWorkdir: "/w")
}

/// Thread-safe accumulator so test closures can be `@Sendable` (the seam's
/// `onOutput` / `hostKeyValidator` are `@Sendable` to allow off-main delivery).
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ value: T) { _value = value }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
    func mutate(_ body: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }; body(&_value)
    }
}

private final class OwnedSSHClient {}

@Test func newerSSHAttemptRejectsAnOlderLateClient() {
    let ownership = SSHConnectionOwnership<OwnedSSHClient>()
    let firstAttempt = ownership.beginConnect()
    let secondAttempt = ownership.beginConnect()
    let firstClient = OwnedSSHClient()
    let secondClient = OwnedSSHClient()

    let stale = ownership.install(firstClient, for: firstAttempt)
    #expect(stale.staleClient === firstClient)
    #expect(ownership.current() == nil)

    let accepted = ownership.install(secondClient, for: secondAttempt)
    #expect(accepted.staleClient == nil)
    #expect(accepted.replacedClient == nil)
    #expect(ownership.current() === secondClient)
}

@Test func disconnectInvalidatesAnInFlightSSHAttempt() {
    let ownership = SSHConnectionOwnership<OwnedSSHClient>()
    let attempt = ownership.beginConnect()
    let lateClient = OwnedSSHClient()

    #expect(ownership.retire() == nil)
    let result = ownership.install(lateClient, for: attempt)

    #expect(result.staleClient === lateClient)
    #expect(ownership.current() == nil)
}

@Test func fakeRecordsConnectAndRunsCommands() async throws {
    let t = FakeSSHTransport()
    t.commandResponses = ["herdr --version": "herdr 0.8.2\n"]
    let fpAccepted = Box(false)
    try await t.connect(host: host(), key: SSHKeyMaterial(ed25519Seed: Data(repeating: 7, count: 32))) { fp in
        fpAccepted.value = !fp.isEmpty; return true
    }
    let out = try await t.runCommand("herdr --version")
    #expect(out == "herdr 0.8.2\n")
    #expect(t.commandsRun.contains("herdr --version"))
    #expect(t.isConnected == true)
    #expect(fpAccepted.value == true)
}

@Test func fakeRejectsBadHostKey() async {
    let t = FakeSSHTransport()
    await #expect(throws: SSHTransportError.self) {
        try await t.connect(host: host(), key: SSHKeyMaterial(ed25519Seed: Data(count: 32))) { _ in false }
    }
}

@Test func fakePTYRecordsIOAndEmits() async throws {
    let t = FakeSSHTransport()
    try await t.connect(host: host(), key: SSHKeyMaterial(ed25519Seed: Data(count: 32))) { _ in true }
    let received = Box(Data())
    let ch = try await t.openPTY(command: "/bin/sh", cols: 80, rows: 24) { data in
        received.mutate { $0.append(data) }
    }
    ch.send(Data("hello".utf8))
    ch.resize(cols: 100, rows: 30)
    (ch as! FakePTYChannel).emit(Data("world".utf8))
    #expect((ch as! FakePTYChannel).sent == Data("hello".utf8))
    #expect((ch as! FakePTYChannel).lastResize?.cols == 100)
    #expect(received.value == Data("world".utf8))
    ch.close()
    #expect((ch as! FakePTYChannel).closed == true)
}

@Test func fakeRunCommandBeforeConnectThrows() async {
    let t = FakeSSHTransport()
    await #expect(throws: SSHTransportError.self) {
        _ = try await t.runCommand("herdr --version")
    }
}

@Test func fakeStructuredCommandPreservesStreamsExitAndRequest() async throws {
    let transport = FakeSSHTransport()
    try await transport.connect(
        host: host(),
        key: SSHKeyMaterial(ed25519Seed: Data(count: 32))
    ) { _ in true }
    let request = SSHCommandRequest(
        command: "printf output; printf error >&2; exit 7",
        timeout: .seconds(2),
        outputLimit: 64
    )
    transport.structuredCommandResults = [
        .success(.init(
            exitStatus: 7,
            stdout: Data("output".utf8),
            stderr: Data("error".utf8)
        ))
    ]

    let result = try await transport.runCommand(request)

    #expect(result.exitStatus == 7)
    #expect(result.stdoutString == "output")
    #expect(result.stderrString == "error")
    #expect(transport.structuredCommandsRun == [request])
}

@Test func nioAccumulatorCapsAggregateOutputBeforeBufferingAndKeepsStreamsSeparate() throws {
    var accumulator = NIOSSHCommandAccumulator(outputLimit: 7)

    try accumulator.append(.stdout, bytes: Data("1234".utf8))
    try accumulator.append(.stderr, bytes: Data("err".utf8))
    #expect(throws: SSHCommandExecutionError.outputLimitExceeded(limit: 7)) {
        try accumulator.append(.stdout, bytes: Data("5".utf8))
    }

    let result = accumulator.result(exitStatus: 9)
    #expect(result.exitStatus == 9)
    #expect(result.stdoutString == "1234")
    #expect(result.stderrString == "err")
}

@Test func fakeStructuredCommandUsesOneAggregateOutputBudget() async throws {
    let transport = FakeSSHTransport()
    try await transport.connect(
        host: host(),
        key: SSHKeyMaterial(ed25519Seed: Data(count: 32))
    ) { _ in true }
    transport.structuredCommandResults = [.success(.init(
        exitStatus: 0,
        stdout: Data("1234".utf8),
        stderr: Data("5678".utf8)
    ))]

    await #expect(throws: SSHCommandExecutionError.outputLimitExceeded(limit: 7)) {
        _ = try await transport.runCommand(.init(
            command: "command",
            timeout: .seconds(1),
            outputLimit: 7
        ))
    }
}

@Test func commandDeadlineReturnsTimeoutAndIgnoresLateCompletion() async {
    let gate = CommandGate()

    await #expect(throws: SSHCommandExecutionError.timedOut) {
        _ = try await SSHCommandDeadline.run(timeout: .milliseconds(10)) {
            await gate.waitIgnoringCancellation()
            return SSHCommandResult(
                exitStatus: 0,
                stdout: Data("late".utf8),
                stderr: Data()
            )
        }
    }

    await gate.release()
    await Task.yield()
    #expect(await gate.completionCount == 1)
}

@Test func commandDeadlineMapsCallerCancellationAndCancelsOperation() async {
    let cancellation = CancellationFlag()
    let task = Task {
        try await SSHCommandDeadline.run(timeout: .seconds(5)) {
            do {
                try await Task.sleep(for: .seconds(5))
                return SSHCommandResult(exitStatus: 0, stdout: Data(), stderr: Data())
            } catch {
                await cancellation.mark()
                throw error
            }
        }
    }

    task.cancel()
    await #expect(throws: SSHCommandExecutionError.cancelled) {
        _ = try await task.value
    }
    while await !cancellation.value { await Task.yield() }
}

@Suite struct NIOSSHTransportErrorTests {
    @Test func commandFailureDoesNotRetainSensitiveCommand() {
        let password = "secret-hop-pw"
        let error = NIOSSHTransport.commandFailure(
            command: "SSH_ASKPASS helper contains \(password)",
            underlyingError: NSError(
                domain: "SSHTransportFakeTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "remote command failed"]
            )
        )

        #expect(!String(describing: error).contains(password))
        #expect(String(describing: error).contains("remote command failed"))
    }
}

@Test func fakeDirectTCPIPRecordsTargetAndTransfersBytes() async throws {
    let t = FakeSSHTransport()
    try await t.connect(host: host(), key: SSHKeyMaterial(ed25519Seed: Data(count: 32))) { _ in true }
    let received = Box(Data())
    let closed = Box(false)

    let channel = try await t.openDirectTCPIP(
        targetHost: "10.44.0.25",
        targetPort: 9443,
        onOutput: { data in received.mutate { $0.append(data) } },
        onClose: { closed.value = true }
    )

    channel.send(Data("client".utf8))
    let fake = channel as! FakeDirectTCPIPChannel
    fake.emit(Data("server".utf8))
    #expect(t.openedDirectTCPIPTargets == [
        .init(host: "10.44.0.25", port: 9443)
    ])
    #expect(fake.sent == Data("client".utf8))
    #expect(received.value == Data("server".utf8))

    channel.close()
    #expect(fake.closed)
    #expect(closed.value)
}

private actor CommandGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var completionCount = 0

    func waitIgnoringCancellation() async {
        await withCheckedContinuation { continuation = $0 }
        completionCount += 1
    }

    func release() { continuation?.resume() }
}

private actor CancellationFlag {
    private(set) var value = false
    func mark() { value = true }
}
