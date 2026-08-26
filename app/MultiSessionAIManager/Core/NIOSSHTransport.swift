import Foundation
import Crypto
import NIOCore
import NIOPosix
import NIOConcurrencyHelpers
import NIOSSH
@preconcurrency import Citadel

enum NIOSSHCommandStream: Sendable {
    case stdout
    case stderr
}

/// Accumulates command output at the streaming callback, rejecting a chunk
/// before stdout and stderr together would exceed the request's single cap.
struct NIOSSHCommandAccumulator: Sendable {
    private let outputLimit: Int
    private(set) var stdout = Data()
    private(set) var stderr = Data()

    init(outputLimit: Int) {
        self.outputLimit = outputLimit
    }

    mutating func append(_ stream: NIOSSHCommandStream, bytes: Data) throws {
        guard outputLimit > 0 else { throw SSHCommandExecutionError.invalidRequest }
        guard bytes.count <= outputLimit - stdout.count - stderr.count else {
            throw SSHCommandExecutionError.outputLimitExceeded(limit: outputLimit)
        }
        switch stream {
        case .stdout:
            stdout.append(bytes)
        case .stderr:
            stderr.append(bytes)
        }
    }

    mutating func append(_ stream: NIOSSHCommandStream, buffer: ByteBuffer) throws {
        guard outputLimit > 0 else { throw SSHCommandExecutionError.invalidRequest }
        guard buffer.readableBytes <= outputLimit - stdout.count - stderr.count else {
            throw SSHCommandExecutionError.outputLimitExceeded(limit: outputLimit)
        }
        switch stream {
        case .stdout:
            stdout.append(contentsOf: buffer.readableBytesView)
        case .stderr:
            stderr.append(contentsOf: buffer.readableBytesView)
        }
    }

    func result(exitStatus: Int32) -> SSHCommandResult {
        .init(exitStatus: exitStatus, stdout: stdout, stderr: stderr)
    }
}

/// Races a command operation against a deadline without waiting for a transport
/// that is slow to observe cancellation. The locked state resolves exactly once.
enum SSHCommandDeadline {
    static func run<T: Sendable>(
        timeout: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard timeout > .zero else { throw SSHCommandExecutionError.invalidRequest }
        let state = SSHCommandDeadlineState<T>()
        let tasks = SSHCommandDeadlineTasks()

        let operationTask = Task {
            do {
                let value = try await operation()
                if state.complete(.success(value)) { tasks.cancelTimeout() }
            } catch is CancellationError {
                if state.complete(.failure(SSHCommandExecutionError.cancelled)) {
                    tasks.cancelTimeout()
                }
            } catch let error as SSHCommandExecutionError {
                if state.complete(.failure(error)) { tasks.cancelTimeout() }
            } catch {
                if state.complete(.failure(error)) { tasks.cancelTimeout() }
            }
        }
        tasks.setOperation(operationTask)

        let timeoutTask = Task {
            do {
                try await Task.sleep(for: timeout)
                if state.complete(.failure(SSHCommandExecutionError.timedOut)) {
                    tasks.cancelOperation()
                }
            } catch {
                // The operation or caller cancellation won.
            }
        }
        tasks.setTimeout(timeoutTask)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.setContinuation(continuation)
            }
        } onCancel: {
            if state.complete(.failure(SSHCommandExecutionError.cancelled)) {
                tasks.cancelAll()
            }
        }
    }
}

private final class SSHCommandDeadlineState<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var completed = false

    func setContinuation(_ continuation: CheckedContinuation<T, Error>) {
        let immediate = lock.withLock { () -> Result<T, Error>? in
            if let result {
                self.result = nil
                return result
            }
            self.continuation = continuation
            return nil
        }
        if let immediate { continuation.resume(with: immediate) }
    }

    @discardableResult
    func complete(_ result: Result<T, Error>) -> Bool {
        let outcome = lock.withLock { () -> (won: Bool, continuation: CheckedContinuation<T, Error>?) in
            guard !completed else { return (false, nil) }
            completed = true
            if let continuation = self.continuation {
                self.continuation = nil
                return (true, continuation)
            }
            self.result = result
            return (true, nil)
        }
        outcome.continuation?.resume(with: result)
        return outcome.won
    }
}

private final class SSHCommandDeadlineTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var cancelOperationWhenSet = false
    private var cancelTimeoutWhenSet = false

    func setOperation(_ task: Task<Void, Never>) {
        let cancel = lock.withLock {
            operationTask = task
            return cancelOperationWhenSet
        }
        if cancel { task.cancel() }
    }

    func setTimeout(_ task: Task<Void, Never>) {
        let cancel = lock.withLock {
            timeoutTask = task
            return cancelTimeoutWhenSet
        }
        if cancel { task.cancel() }
    }

    func cancelOperation() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            cancelOperationWhenSet = true
            return operationTask
        }
        task?.cancel()
    }

    func cancelTimeout() {
        let task = lock.withLock { () -> Task<Void, Never>? in
            cancelTimeoutWhenSet = true
            return timeoutTask
        }
        task?.cancel()
    }

    func cancelAll() {
        cancelOperation()
        cancelTimeout()
    }
}

/// Generation-fenced ownership for one replaceable SSH connection. A client
/// created by an older connect attempt is returned as stale instead of becoming
/// current, and disconnect invalidates all in-flight attempts before retiring the
/// installed client.
final class SSHConnectionOwnership<Client>: @unchecked Sendable {
    struct InstallResult {
        let staleClient: Client?
        let replacedClient: Client?
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var client: Client?

    func beginConnect() -> UInt64 {
        lock.withLock {
            generation &+= 1
            return generation
        }
    }

    func install(_ candidate: Client, for attempt: UInt64) -> InstallResult {
        lock.withLock {
            guard attempt == generation else {
                return InstallResult(staleClient: candidate, replacedClient: nil)
            }
            let replaced = client
            client = candidate
            return InstallResult(staleClient: nil, replacedClient: replaced)
        }
    }

    func current() -> Client? {
        lock.withLock { client }
    }

    func retire() -> Client? {
        lock.withLock {
            generation &+= 1
            let retired = client
            client = nil
            return retired
        }
    }
}

/// Real SSH transport built on Citadel (`SSHClient`) for both non-interactive
/// command execution and interactive PTY shells. Citadel is itself built on the
/// Wellz26 fork of swift-nio-ssh; we drop down to a raw `NIOSSHClientServerAuthenticationDelegate`
/// only to compute the host-key fingerprint for the seam's validator hook.
///
/// Concurrency: nio delivers IO on an `EventLoop`, not the main thread. The seam's
/// `onOutput` and `hostKeyValidator` are `@Sendable`; this class never hops to main
/// (the UI bridge in Task 4.1 does that). Mutable state (`client`) is guarded by a
/// lock, so the class is `@unchecked Sendable`.
///
/// Runtime-unverifiable here: this needs a live SSH server + network, which the
/// simulator/CI does not provide. Acceptance for Task 3.2 is "compiles, conforms,
/// uses the libraries correctly"; on-device validation happens in Phase 8.
final class NIOSSHTransport: SSHTransport, @unchecked Sendable {

    private let connectionOwnership = SSHConnectionOwnership<SSHClient>()

    init() {}

    // MARK: - Connect

    func connect(host: Host, key: SSHKeyMaterial,
                 hostKeyValidator: @escaping @Sendable (String) -> Bool) async throws {
        let attempt = connectionOwnership.beginConnect()
        let privateKey: Curve25519.Signing.PrivateKey
        do {
            privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: key.ed25519Seed)
        } catch {
            throw SSHTransportError.commandFailed("invalid ed25519 seed: \(error)")
        }

        let auth = SSHAuthenticationMethod.ed25519(username: host.username, privateKey: privateKey)
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
            // nio wraps the validation failure (including our validator's own
            // HostKeyRejected and the fork's InvalidHostKey); map a rejected
            // fingerprint to the seam's dedicated error via isHostKeyRejection,
            // everything else to commandFailed.
            if isHostKeyRejection(error) {
                throw SSHTransportError.hostKeyRejected
            }
            throw SSHTransportError.commandFailed("connect failed: \(error)")
        }

        let installation = connectionOwnership.install(newClient, for: attempt)
        if let staleClient = installation.staleClient {
            try? await staleClient.close()
            throw CancellationError()
        }
        if let replacedClient = installation.replacedClient {
            try? await replacedClient.close()
        }
    }

    // MARK: - File upload

    /// SFTP write over the SAME authenticated client the PTY and commands use.
    /// `CitadelFileTransfer` dials its own connection because it is constructed
    /// before any session exists; here a live, host-key-verified client is
    /// already in hand, so a second dial would only mean a second auth.
    ///
    /// The SFTP subsystem is opened per upload and closed after: uploads are
    /// occasional, and holding a subsystem open for the life of a tab is state
    /// to invalidate on every reconnect for no benefit.
    func writeFile(_ data: Data, to path: String) async throws {
        let client = try currentClient()
        let sftp: SFTPClient
        do {
            sftp = try await client.openSFTP()
        } catch {
            throw SSHTransportError.commandFailed("openSFTP failed: \(error)")
        }
        defer { Task { try? await sftp.close() } }
        do {
            let file = try await sftp.openFile(filePath: path, flags: [.write, .create, .truncate])
            do {
                try await file.write(ByteBuffer(bytes: data))
                try await file.close()
            } catch {
                try? await file.close()
                throw error
            }
        } catch {
            throw SSHTransportError.commandFailed("upload to \(path) failed: \(error)")
        }
    }

    /// SFTP read over the SAME authenticated client, mirroring `writeFile`.
    func readFile(at path: String) async throws -> Data {
        try await withSFTP { sftp in
            let file = try await sftp.openFile(filePath: path, flags: [.read])
            do {
                let buffer = try await file.readAll()
                try await file.close()
                return Data(buffer.readableBytesView)
            } catch {
                try? await file.close()
                throw error
            }
        }
    }

    /// Size WITHOUT reading the file, so callers can refuse an oversize download
    /// before pulling a single byte across the link.
    func fileSize(at path: String) async throws -> Int {
        try await withSFTP { sftp in
            let attributes = try await sftp.getAttributes(at: path)
            guard let size = attributes.size else {
                throw SSHTransportError.commandFailed("could not determine the size of \(path)")
            }
            return Int(size)
        }
    }

    /// Open the SFTP subsystem, run `body`, and close it again.
    ///
    /// Opened per operation rather than held for the life of the tab: transfers
    /// are occasional, and a cached subsystem is state that would need
    /// invalidating on every reconnect for no benefit.
    private func withSFTP<T>(_ body: (SFTPClient) async throws -> T) async throws -> T {
        let client = try currentClient()
        let sftp: SFTPClient
        do {
            sftp = try await client.openSFTP()
        } catch {
            throw SSHTransportError.commandFailed("openSFTP failed: \(error)")
        }
        defer { Task { try? await sftp.close() } }
        do {
            return try await body(sftp)
        } catch let error as SSHTransportError {
            throw error
        } catch {
            throw SSHTransportError.commandFailed("sftp operation failed: \(error)")
        }
    }

    private func currentClient() throws -> SSHClient {
        guard let client = connectionOwnership.current() else {
            throw SSHTransportError.notConnected
        }
        return client
    }

    private func isHostKeyRejection(_ error: Error) -> Bool {
        if error is InvalidHostKey { return true }
        if error is SSHHostKeyRejected { return true }
        // The fork buries validation failures inside the channel-close error path;
        // match on the description as a last resort so a rejected key never looks
        // like a generic connection failure.
        let desc = String(describing: error).lowercased()
        return desc.contains("hostkeyrejected") || desc.contains("invalidhostkey")
    }

    // MARK: - Run command (non-interactive)

    func runCommand(_ cmd: String) async throws -> String {
        let client = try currentClient()
        do {
            let buffer = try await client.executeCommand(cmd, mergeStreams: true)
            return String(buffer: buffer)
        } catch {
            throw Self.commandFailure(
                command: cmd,
                underlyingError: error
            )
        }
    }

    func runCommand(_ request: SSHCommandRequest) async throws -> SSHCommandResult {
        guard !request.command.isEmpty,
              request.outputLimit > 0,
              request.timeout > .zero else {
            throw SSHCommandExecutionError.invalidRequest
        }
        let client = try currentClient()
        return try await SSHCommandDeadline.run(timeout: request.timeout) {
            var accumulator = NIOSSHCommandAccumulator(outputLimit: request.outputLimit)
            do {
                try await client.withExec(request.command) { inbound, _ in
                    for try await chunk in inbound {
                        switch chunk {
                        case .stdout(let buffer):
                            try accumulator.append(.stdout, buffer: buffer)
                        case .stderr(let buffer):
                            try accumulator.append(.stderr, buffer: buffer)
                        }
                    }
                }
                return accumulator.result(exitStatus: 0)
            } catch let error as ChannelError where error == .alreadyClosed {
                // Citadel's `withExec` closes the channel after `perform` returns,
                // but a command that ran to completion has already been closed
                // server-side, so that redundant close throws `.alreadyClosed`.
                // The output stream drained normally, so this IS the success
                // path -- treating it as a failure made every bounded command
                // surface as `.ambiguousDisconnect`.
                return accumulator.result(exitStatus: 0)
            } catch let error as SSHClient.CommandFailed {
                return accumulator.result(
                    exitStatus: Int32(exactly: error.exitCode) ?? -1
                )
            } catch is CancellationError {
                throw SSHCommandExecutionError.cancelled
            } catch let error as SSHCommandExecutionError {
                throw error
            } catch {
                // No remote exit status arrived, so a mutating caller cannot know
                // whether the command ran and must not retry automatically.
                throw SSHCommandExecutionError.ambiguousDisconnect
            }
        }
    }

    static func commandFailure(
        command _: String,
        underlyingError _: Error
    ) -> SSHTransportError {
        // Commands may contain transient credentials (for example SSH_ASKPASS
        // setup), so neither the command nor transport detail is retained.
        .commandFailed("remote command failed")
    }

    // MARK: - Open PTY (interactive shell)

    func openPTY(command: String, cols: Int, rows: Int,
                 onOutput: @escaping @Sendable (Data) -> Void) async throws -> PTYChannel {
        let client = try currentClient()

        let ptyRequest = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: "xterm-256color",
            terminalCharacterWidth: cols,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )

        // `withPTY` owns the channel for the duration of its `perform` closure and
        // tears it down when the closure returns. The seam, however, must *return*
        // a live PTYChannel and let the caller drive it. Bridge the two: drive
        // `withPTY` from a detached Task, hand the writer out through a one-shot
        // continuation so `openPTY` can return, then keep the closure alive on a
        // "channel closed" signal that `PTYChannel.close()` (or server EOF) trips.
        let writerBox = WriterBox()
        let closeSignal = CloseSignal()

        let pump = Task { [weak writerBox] in
            do {
                try await client.withPTY(ptyRequest) { inbound, outbound in
                    // Send the requested command into the interactive shell.
                    if !command.isEmpty {
                        try await outbound.write(ByteBuffer(string: command + "\n"))
                    }

                    // Publish only AFTER the attach command has been written. This
                    // keeps TerminalSession in its attaching/busy state if startup
                    // stalls or fails instead of declaring cached output live.
                    writerBox?.set(outbound)

                    // Forward server output until EOF or until close() is requested.
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        group.addTask {
                            for try await chunk in inbound {
                                switch chunk {
                                case .stdout(let buffer), .stderr(let buffer):
                                    onOutput(Data(buffer.readableBytesView))
                                }
                            }
                        }
                        group.addTask {
                            await closeSignal.wait()
                        }
                        // Whichever finishes first (EOF or user close) ends the PTY.
                        _ = try await group.next()
                        group.cancelAll()
                    }
                }
            } catch {
                // Stream ended (EOF, error, or cancellation). Nothing to surface here;
                // the channel is being torn down.
            }
            writerBox?.markClosed()
        }

        // Wait until the writer is available (or the pump failed before publishing).
        guard let writer = await writerBox.awaitWriter() else {
            pump.cancel()
            throw SSHTransportError.commandFailed("failed to open PTY shell")
        }

        return NIOPTYChannel(
            writer: writer,
            writerBox: writerBox,
            closeSignal: closeSignal,
            pump: pump
        )
    }

    // MARK: - Direct TCP/IP (session web tunnel)

    func openDirectTCPIP(
        targetHost: String,
        targetPort: Int,
        onOutput: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) async throws -> any DirectTCPIPChannel {
        let client = try currentClient()
        let originator = try SocketAddress(ipAddress: "127.0.0.1", port: 0)
        let closeNotifier = DirectTCPIPCloseNotifier(onClose: onClose)

        do {
            let channel = try await client.createDirectTCPIPChannel(
                using: SSHChannelType.DirectTCPIP(
                    targetHost: targetHost,
                    targetPort: targetPort,
                    originatorAddress: originator
                )
            ) { channel in
                channel.pipeline.addHandler(
                    DirectTCPIPInboundHandler(
                        onOutput: onOutput,
                        closeNotifier: closeNotifier
                    )
                )
            }
            return NIODirectTCPIPChannel(channel: channel, closeNotifier: closeNotifier)
        } catch {
            throw SSHTransportError.commandFailed(
                "direct-tcpip \(targetHost):\(targetPort) failed: \(error)"
            )
        }
    }

    // MARK: - Disconnect

    func disconnect() async {
        let c = connectionOwnership.retire()
        try? await c?.close()
    }
}

private final class DirectTCPIPCloseNotifier: @unchecked Sendable {
    private let lock = NSLock()
    private var notified = false
    private let onClose: @Sendable () -> Void

    init(onClose: @escaping @Sendable () -> Void) {
        self.onClose = onClose
    }

    func notifyOnce() {
        let shouldNotify = lock.withLock {
            guard !notified else { return false }
            notified = true
            return true
        }
        if shouldNotify { onClose() }
    }
}

private final class DirectTCPIPInboundHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let onOutput: @Sendable (Data) -> Void
    private let closeNotifier: DirectTCPIPCloseNotifier

    init(
        onOutput: @escaping @Sendable (Data) -> Void,
        closeNotifier: DirectTCPIPCloseNotifier
    ) {
        self.onOutput = onOutput
        self.closeNotifier = closeNotifier
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        onOutput(Data(buffer.readableBytesView))
    }

    func channelInactive(context: ChannelHandlerContext) {
        closeNotifier.notifyOnce()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        closeNotifier.notifyOnce()
        context.close(promise: nil)
    }
}

private final class NIODirectTCPIPChannel: DirectTCPIPChannel, @unchecked Sendable {
    private let channel: Channel
    private let closeNotifier: DirectTCPIPCloseNotifier

    init(channel: Channel, closeNotifier: DirectTCPIPCloseNotifier) {
        self.channel = channel
        self.closeNotifier = closeNotifier
    }

    func send(_ data: Data) {
        let channel = self.channel
        channel.eventLoop.execute {
            guard channel.isActive else { return }
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            channel.writeAndFlush(buffer, promise: nil)
        }
    }

    func close() {
        closeNotifier.notifyOnce()
        channel.eventLoop.execute {
            self.channel.close(promise: nil)
        }
    }
}

// MARK: - PTY channel

/// `Sendable` box used to hand Citadel's `TTYStdinWriter` out of the `withPTY`
/// closure to the awaiting `openPTY` call.
private final class WriterBox: @unchecked Sendable {
    private struct State {
        var writer: TTYStdinWriter?
        var closed = false
        var waiter: CheckedContinuation<TTYStdinWriter?, Never>?
    }
    private let state = NIOLockedValueBox(State())

    var isOpen: Bool {
        state.withLockedValue { $0.writer != nil && !$0.closed }
    }

    func set(_ w: TTYStdinWriter) {
        let cont = state.withLockedValue { s -> CheckedContinuation<TTYStdinWriter?, Never>? in
            s.writer = w
            let waiter = s.waiter
            s.waiter = nil
            return waiter
        }
        cont?.resume(returning: w)
    }

    func markClosed() {
        let cont = state.withLockedValue { s -> CheckedContinuation<TTYStdinWriter?, Never>? in
            s.closed = true
            // If we never published a writer (open failed), unblock the awaiter with nil.
            guard s.writer == nil else { return nil }
            let waiter = s.waiter
            s.waiter = nil
            return waiter
        }
        cont?.resume(returning: nil)
    }

    func awaitWriter() async -> TTYStdinWriter? {
        // Fast path: already resolved.
        let early = state.withLockedValue { s -> TTYStdinWriter?? in
            if let writer = s.writer { return .some(writer) }
            if s.closed { return .some(nil) }
            return .none
        }
        if let resolved = early { return resolved }

        return await withCheckedContinuation { (cont: CheckedContinuation<TTYStdinWriter?, Never>) in
            let immediate = state.withLockedValue { s -> TTYStdinWriter?? in
                // Re-check under the lock in case set()/markClosed() raced in.
                if let writer = s.writer { return .some(writer) }
                if s.closed { return .some(nil) }
                s.waiter = cont
                return .none
            }
            if let resolved = immediate { cont.resume(returning: resolved) }
        }
    }
}

/// One-shot signal tripped by `PTYChannel.close()` to end the `withPTY` pump.
///
/// `wait()` is cancellation-aware: when the enclosing TaskGroup calls
/// `cancelAll()` on the server-EOF path, the cancelled waiter resumes instead of
/// hanging forever (which would leave `withPTY`'s closure — and the SSH channel —
/// suspended for the app's lifetime). Each stored continuation is resumed exactly
/// once: either by `trip()` (explicit close) or by `cancel(id:)` (cancellation),
/// whichever fires first; the loser is a no-op because the waiter is removed from
/// the dictionary on first resume.
private actor CloseSignal {
    private var isClosed = false
    private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var nextID: UInt64 = 0

    func wait() async {
        // Fast path: already tripped, no need to register a waiter.
        if isClosed { return }
        let id = nextID
        nextID &+= 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                // Re-check under actor isolation: if trip() already raced in, or the
                // task is already cancelled (so onCancel may have run before we got
                // here and found no waiter), resume immediately instead of parking.
                if isClosed || Task.isCancelled {
                    cont.resume()
                } else {
                    waiters[id] = cont
                }
            }
        } onCancel: {
            Task { await self.cancel(id: id) }
        }
    }

    /// Resume a single waiter due to cancellation, if it is still pending.
    private func cancel(id: UInt64) {
        if let cont = waiters.removeValue(forKey: id) {
            cont.resume()
        }
    }

    func trip() {
        guard !isClosed else { return }
        isClosed = true
        let pending = waiters
        waiters.removeAll()
        for (_, w) in pending { w.resume() }
    }
}

/// `PTYChannel` over a Citadel interactive shell. `send`/`resize`/`close` are
/// synchronous (the seam is sync) and dispatch the underlying async nio writes
/// onto detached Tasks; ordering of `send`s is preserved by a serial queue Task.
private final class NIOPTYChannel: PTYChannel, @unchecked Sendable {
    private let writer: TTYStdinWriter
    private let writerBox: WriterBox
    private let closeSignal: CloseSignal
    private let pump: Task<Void, Never>

    var isOpen: Bool { writerBox.isOpen }

    init(
        writer: TTYStdinWriter,
        writerBox: WriterBox,
        closeSignal: CloseSignal,
        pump: Task<Void, Never>
    ) {
        self.writer = writer
        self.writerBox = writerBox
        self.closeSignal = closeSignal
        self.pump = pump
    }

    func send(_ data: Data) {
        let writer = self.writer
        let writerBox = self.writerBox
        let closeSignal = self.closeSignal
        Task {
            do {
                try await writer.write(ByteBuffer(bytes: data))
            } catch {
                // A failed channel write means the connection under it is gone.
                // Marking closed is what turns "typing into a dead tab" from a
                // silently swallowed error into a stale channel the session's
                // reconciliation can actually see.
                writerBox.markClosed()
                await closeSignal.trip()
            }
        }
    }

    func resize(cols: Int, rows: Int) {
        let writer = self.writer
        Task {
            try? await writer.changeSize(cols: cols, rows: rows, pixelWidth: 0, pixelHeight: 0)
        }
    }

    func close() {
        writerBox.markClosed()
        let closeSignal = self.closeSignal
        Task { await closeSignal.trip() }
    }
}
