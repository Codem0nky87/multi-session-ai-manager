import Foundation

/// A configurable in-memory SSH transport for unit-testing authenticated setup
/// and forwarding without any swift-nio-ssh dependency.
///
/// Lives in Core (not Tests) so both the app's previews/diagnostics and the
/// test target can use it.
final class FakeSSHTransport: SSHTransport, @unchecked Sendable {

    private final class Connection {}

    struct DirectTCPIPTarget: Equatable {
        let host: String
        let port: Int
    }

    // MARK: Connect recording
    private(set) var lastConnectHost: Host?
    private(set) var lastConnectKey: SSHKeyMaterial?
    private let connectionOwnership = SSHConnectionOwnership<Connection>()
    var isConnected: Bool { connectionOwnership.current() != nil }
    private(set) var disconnectCount = 0
    /// `closed` for every PTY this transport vended, sampled at the START of the
    /// most recent `disconnect()` -- i.e. BEFORE `disconnect()`'s own teardown
    /// closes them. Lets a test prove its subject closed its channel itself,
    /// rather than riding on this fake's connection-teardown side effect.
    private(set) var ptyClosedStatesAtLastDisconnect: [Bool] = []
    /// The fingerprint string the validator was called with, and its decision.
    private(set) var lastHostKeyDecision: Bool?
    /// Optional async gates for deterministic cancellation tests.
    var beforeConnect: (@Sendable () async throws -> Void)?
    var beforeCommand: (@Sendable (String) async throws -> Void)?

    // MARK: Command recording / canned responses
    var commandResponses: [String: String] = [:]
    var defaultCommandResponse: String = ""
    private(set) var commandsRun: [String] = []
    var structuredCommandResults: [Result<SSHCommandResult, SSHCommandExecutionError>] = []
    private(set) var structuredCommandsRun: [SSHCommandRequest] = []

    // MARK: Failure injection
    var connectError: Error?
    /// Global failure: every `runCommand` throws this.
    var commandError: Error?
    /// Per-command failure checked before `commandResponses`, while unrelated
    /// commands may still succeed.
    var commandErrors: [String: Error] = [:]

    /// Fingerprint presented to `hostKeyValidator` during `connect`.
    var hostKeyToPresent: String = "AAAAFAKEFINGERPRINTBASE64NOPAD"

    // MARK: Uploaded files
    /// Absolute remote path -> bytes, for tests that assert what was uploaded.
    private(set) var writtenFiles: [String: Data] = [:]
    var writeFileError: Error?

    // MARK: Downloadable files
    /// Files that "already exist" on the fake host, for download tests.
    var remoteFiles: [String: Data] = [:]
    private(set) var readPaths: [String] = []
    var readFileError: Error?
    var fileSizeError: Error?

    // MARK: Opened PTYs (so tests can inspect after the fact)
    private(set) var openedPTYs: [FakePTYChannel] = []
    private(set) var openedDirectTCPIPTargets: [DirectTCPIPTarget] = []
    private(set) var openedDirectTCPIPChannels: [FakeDirectTCPIPChannel] = []
    var directTCPIPError: Error?

    init() {}

    func connect(host: Host, key: SSHKeyMaterial,
                 hostKeyValidator: @escaping @Sendable (String) -> Bool) async throws {
        let attempt = connectionOwnership.beginConnect()
        lastConnectHost = host
        lastConnectKey = key
        try await beforeConnect?()
        if let connectError { throw connectError }
        let accepted = hostKeyValidator(hostKeyToPresent)
        lastHostKeyDecision = accepted
        guard accepted else { throw SSHTransportError.hostKeyRejected }
        let installation = connectionOwnership.install(Connection(), for: attempt)
        guard installation.staleClient == nil else { throw CancellationError() }
    }

    func runCommand(_ cmd: String) async throws -> String {
        guard isConnected else { throw SSHTransportError.notConnected }
        commandsRun.append(cmd)
        try await beforeCommand?(cmd)
        if let commandError { throw commandError }
        if let perCommand = commandErrors[cmd] { throw perCommand }
        return commandResponses[cmd] ?? defaultCommandResponse
    }

    func runCommand(_ request: SSHCommandRequest) async throws -> SSHCommandResult {
        guard isConnected else { throw SSHTransportError.notConnected }
        guard !request.command.isEmpty, request.outputLimit > 0, request.timeout > .zero else {
            throw SSHCommandExecutionError.invalidRequest
        }
        structuredCommandsRun.append(request)
        commandsRun.append(request.command)
        try await beforeCommand?(request.command)
        if let commandError { throw commandError }
        if let perCommand = commandErrors[request.command] { throw perCommand }
        if !structuredCommandResults.isEmpty {
            let result = try structuredCommandResults.removeFirst().get()
            guard result.stdout.count <= request.outputLimit - result.stderr.count else {
                throw SSHCommandExecutionError.outputLimitExceeded(limit: request.outputLimit)
            }
            return result
        }
        let value = commandResponses[request.command] ?? defaultCommandResponse
        let bytes = Data(value.utf8)
        guard bytes.count <= request.outputLimit else {
            throw SSHCommandExecutionError.outputLimitExceeded(limit: request.outputLimit)
        }
        return .init(exitStatus: 0, stdout: bytes, stderr: Data())
    }

    func writeFile(_ data: Data, to path: String) async throws {
        guard isConnected else { throw SSHTransportError.notConnected }
        if let writeFileError { throw writeFileError }
        writtenFiles[path] = data
    }

    func readFile(at path: String) async throws -> Data {
        guard isConnected else { throw SSHTransportError.notConnected }
        if let readFileError { throw readFileError }
        guard let data = remoteFiles[path] ?? writtenFiles[path] else {
            throw SSHTransportError.commandFailed("no such file: \(path)")
        }
        readPaths.append(path)
        return data
    }

    func fileSize(at path: String) async throws -> Int {
        guard isConnected else { throw SSHTransportError.notConnected }
        if let fileSizeError { throw fileSizeError }
        guard let data = remoteFiles[path] ?? writtenFiles[path] else {
            throw SSHTransportError.commandFailed("no such file: \(path)")
        }
        return data.count
    }

    func openPTY(command: String, cols: Int, rows: Int,
                 onOutput: @escaping @Sendable (Data) -> Void) async throws -> PTYChannel {
        guard isConnected else { throw SSHTransportError.notConnected }
        let ch = FakePTYChannel(command: command, cols: cols, rows: rows, onOutput: onOutput)
        openedPTYs.append(ch)
        return ch
    }

    func openDirectTCPIP(
        targetHost: String,
        targetPort: Int,
        onOutput: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) async throws -> any DirectTCPIPChannel {
        guard isConnected else { throw SSHTransportError.notConnected }
        if let directTCPIPError { throw directTCPIPError }
        openedDirectTCPIPTargets.append(.init(host: targetHost, port: targetPort))
        let channel = FakeDirectTCPIPChannel(onOutput: onOutput, onClose: onClose)
        openedDirectTCPIPChannels.append(channel)
        return channel
    }

    func disconnect() async {
        disconnectCount += 1
        ptyClosedStatesAtLastDisconnect = openedPTYs.map(\.closed)
        _ = connectionOwnership.retire()
        // A real SSH disconnect takes every channel on the connection down with
        // it, so the fake does too -- which is exactly why the snapshot above
        // has to be taken first.
        openedPTYs.forEach { $0.close() }
    }
}

final class FakeDirectTCPIPChannel: DirectTCPIPChannel, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent = Data()
    private var _closed = false
    private let onOutput: @Sendable (Data) -> Void
    private let onClose: @Sendable () -> Void

    init(
        onOutput: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) {
        self.onOutput = onOutput
        self.onClose = onClose
    }

    var sent: Data { lock.withLock { _sent } }
    var closed: Bool { lock.withLock { _closed } }

    func send(_ data: Data) {
        lock.withLock { _sent.append(data) }
    }

    func close() {
        let shouldNotify = lock.withLock {
            guard !_closed else { return false }
            _closed = true
            return true
        }
        if shouldNotify { onClose() }
    }

    func emit(_ data: Data) {
        onOutput(data)
    }
}

/// PTY channel produced by `FakeSSHTransport`. Records I/O and lets tests push
/// output bytes back to the consumer via `emit`.
final class FakePTYChannel: PTYChannel {
    let command: String
    private(set) var openCols: Int
    private(set) var openRows: Int

    private(set) var sent = Data()
    private(set) var lastResize: (cols: Int, rows: Int)?
    private(set) var closed = false

    private let onOutput: @Sendable (Data) -> Void

    var isOpen: Bool { !closed }

    init(command: String, cols: Int, rows: Int, onOutput: @escaping @Sendable (Data) -> Void) {
        self.command = command
        self.openCols = cols
        self.openRows = rows
        self.onOutput = onOutput
    }

    func send(_ data: Data) {
        sent.append(data)
    }

    func resize(cols: Int, rows: Int) {
        lastResize = (cols, rows)
    }

    func close() {
        closed = true
    }

    /// Test hook: simulate the server emitting output bytes.
    func emit(_ data: Data) {
        onOutput(data)
    }
}
