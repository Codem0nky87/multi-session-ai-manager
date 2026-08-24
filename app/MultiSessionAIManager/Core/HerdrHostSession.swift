import Foundation
import NIOConcurrencyHelpers
import Observation

/// One host tab's live state: an authenticated SSH connection, a PTY running
/// Herdr, and the terminal painting it. Herdr's own "launch or attach" semantics
/// mean a reconnect lands back in the same remote session, so this type does not
/// reconcile any state of its own.
@MainActor
@Observable
final class HerdrHostSession {
    enum Status: Equatable {
        case idle
        case connecting
        case live
        /// Herdr is not installed on the host. Actionable, not an opaque shell error.
        case herdrMissing
        /// The host presented a different host key than the pinned one. Kept
        /// distinct from `.failed` because the only recovery is an explicit,
        /// destructive decision to trust the new key -- a Retry button can do
        /// nothing here but re-detect the same mismatch forever.
        case hostKeyChanged(String)
        case failed(String)
    }

    /// Lock-guarded accumulator for the bounded, off-main missing-Herdr sentinel
    /// scan. It lives outside `self` (captured by value into the `@Sendable`
    /// output closure) because output arrives off the main actor and must not
    /// touch `HerdrHostSession` state directly. Its `scanLimit` lives here too
    /// (rather than on `HerdrHostSession`) because that closure is nonisolated —
    /// a `static let` on the enclosing `@MainActor` class is not reachable from it.
    private struct SentinelScanState: Sendable {
        /// How many bytes of a fresh channel's output are scanned for the
        /// missing-Herdr sentinel before giving up. The sentinel, if the remote
        /// host emits it at all, only appears in the pre-`exec` preamble —
        /// bounding the scan keeps LATER output (which may coincidentally contain
        /// the sentinel text, e.g. someone greps for it or opens
        /// `HerdrLaunchCommand.swift` inside the session) from mislabeling an
        /// otherwise-healthy tab. It also caps the off-main scan cost to a
        /// one-time, bounded byte search instead of a per-chunk decode forever.
        static let scanLimit = 4096

        var buffer = Data()
        var finished = false
    }

    let connection: HostConnection
    let sessionName: String?
    /// Identifies this tab's outbox watcher on the host. Stable across app
    /// launches so a relaunch evicts its own orphan rather than adding to it.
    let watchIdentity: String
    let terminal: TerminalEmulator

    private(set) var status: Status = .idle
    private var channel: PTYChannel?
    /// A second channel per live tab, tailing the host's outbox so a file the
    /// user sends from the `herdr-file-viewer` plugin arrives without polling.
    /// Separate from the Herdr PTY because that one is carrying an interactive
    /// program and cannot be shared.
    private var watchChannel: PTYChannel?
    /// Paths queued on the host and not yet handled. Read by the UI.
    private(set) var incomingPaths: [String] = []
    private var sawMissingSentinel = false
    /// Bumped at the top of every `start()`, and again by `stop()` when it
    /// supersedes whatever is in flight. Mirrors
    /// `HostConnection.operationGeneration`: an in-flight `start()` re-checks this
    /// after each `await` and abandons (closing any channel it already obtained)
    /// if it no longer matches, so a `stop()` that races a slow connect can't be
    /// clobbered by the connect finishing after the fact.
    private var operationGeneration: UInt64 = 0

    init(
        connection: HostConnection,
        sessionName: String?,
        watchIdentity: String = "default",
        terminal: TerminalEmulator = TerminalEmulator()
    ) {
        self.connection = connection
        self.sessionName = sessionName
        self.watchIdentity = watchIdentity
        self.terminal = terminal
    }

    func start() async {
        guard status != .connecting, status != .live else { return }
        operationGeneration &+= 1
        let generation = operationGeneration
        status = .connecting
        sawMissingSentinel = false

        if connection.state != .connected {
            await connection.connect()
        }
        guard operationGeneration == generation else { return }
        guard connection.state == .connected else {
            if case .hostKeyChanged(let fingerprint) = connection.state {
                status = .hostKeyChanged(fingerprint)
            } else {
                status = .failed(Self.message(for: connection.state))
            }
            return
        }

        do {
            let terminal = self.terminal
            let scanState = NIOLockedValueBox(SentinelScanState())
            let sentinelBytes = Data(HerdrLaunchCommand.missingSentinel.utf8)
            let channel = try await connection.openHerdrPTY(
                sessionName: sessionName,
                cols: terminal.cols,
                rows: terminal.rows
            ) { [weak self] data in
                terminal.feed(data)
                // Off-main, bounded, byte-level scan — no String allocation, and it
                // stops looking (cheaply) once the preamble window has passed.
                let hit = scanState.withLockedValue { state -> Bool in
                    guard !state.finished else { return false }
                    state.buffer.append(data)
                    if state.buffer.range(of: sentinelBytes) != nil {
                        state.finished = true
                        state.buffer = Data()   // release; scanning is over either way
                        return true
                    }
                    if state.buffer.count >= SentinelScanState.scanLimit {
                        state.finished = true
                        state.buffer = Data()   // release; nothing more will ever be scanned
                    }
                    return false
                }
                guard hit else { return }
                Task { @MainActor in self?.markHerdrMissing(generation: generation) }
            }
            guard operationGeneration == generation else {
                // Superseded by a stop() or a newer start() while we were opening
                // the PTY — don't leak the channel we just got.
                channel.close()
                return
            }
            self.channel = channel
            terminal.pty = channel
            // The sentinel may have already landed (synchronously, or via a main-actor
            // hop that beat us here) while this call was suspended above; honor it
            // instead of clobbering it with an unconditional .live.
            status = sawMissingSentinel ? .herdrMissing : .live
        } catch {
            guard operationGeneration == generation else { return }
            status = .failed(SSHFailure.classify(message: String(describing: error)).userMessage)
        }
    }

    /// Upload a file to this host and type its absolute path into the pane.
    /// Returns the remote path so the caller can report it.
    ///
    /// Only meaningful while the tab is live: the upload rides THIS tab's
    /// already-authenticated connection (no second dial, no second host-key
    /// decision), and the path is typed into THIS tab's PTY. Neither exists
    /// otherwise, so an offline tab refuses rather than connecting behind the
    /// user's back.
    /// Open (or reopen) the outbox watch. Safe to call repeatedly.
    func ensureWatching() async {
        guard status == .live, let service = connection.provisioningCommandRunner else { return }
        guard watchChannel?.isOpen != true else { return }
        watchChannel = nil

        let accumulator = NIOLockedValueBox(RemoteFileDownload.LineAccumulator())
        do {
            watchChannel = try await service.openPTY(
                command: RemoteFileDownload.watchCommand(identity: watchIdentity),
                cols: 200,
                rows: 24,
                onOutput: { [weak self] data in
                    // Arrives off the main actor on a nio EventLoop, so the
                    // accumulator lives outside `self` behind a lock and only
                    // COMPLETE lines are handed back to the main actor.
                    let lines = accumulator.withLockedValue { $0.consume(data) }
                    guard !lines.isEmpty else { return }
                    Task { @MainActor [weak self] in
                        self?.enqueueIncoming(lines)
                    }
                }
            )
        } catch {
            // A host without the outbox (or without msam-send installed) simply
            // has nothing to watch. That is not a session failure -- the tab is
            // still perfectly usable -- so it must never touch `status`.
            watchChannel = nil
        }
    }

    private func enqueueIncoming(_ lines: [String]) {
        for line in lines where RemoteFileDownload.isAcceptable(line) {
            guard !incomingPaths.contains(line) else { continue }
            incomingPaths.append(line)
        }
    }

    /// Take the next queued path, if any.
    func takeNextIncomingPath() -> String? {
        incomingPaths.isEmpty ? nil : incomingPaths.removeFirst()
    }

    /// Download a queued path over this tab's own connection.
    func fetchIncoming(_ path: String) async throws -> IncomingFile {
        guard status == .live, let service = connection.provisioningCommandRunner else {
            throw RemoteFileDownload.Failure.downloadFailed("this tab is not connected")
        }
        return try await RemoteFileDownload.download(path, using: service)
    }

    func sendFile(
        _ data: Data,
        fileExtension: String,
        at date: Date = Date()
    ) async throws -> String {
        guard status == .live, let service = connection.provisioningCommandRunner else {
            throw RemoteFileUpload.Failure.uploadFailed("this tab is not connected")
        }
        let path = try await RemoteFileUpload.upload(
            data,
            fileExtension: fileExtension,
            using: service,
            at: date
        )
        // Path only -- never a newline. See RemoteFileUpload.paneInsertion.
        terminal.feedInputToPTY(Array(RemoteFileUpload.paneInsertion(for: path).utf8))
        return path
    }

    func resize(cols: Int, rows: Int) {
        terminal.resize(cols: cols, rows: rows)
    }

    /// The single entry point for "make this tab live". Reconciles cached state
    /// against reality before deciding what to do. Every UI trigger calls this,
    /// never `start()` directly -- `start()` early-returns on a cached `.live`
    /// and reuses a cached `HostConnection`, neither of which is invalidated by
    /// the transport dying underneath them.
    func ensureLive() async {
        // The outbox watch is reconciled the same way the PTY is -- by checking
        // whether it is still open rather than by a push callback, which is the
        // pattern this type already uses. Without this a reconnect leaves the
        // watch dead and files silently stop arriving with nothing to see.
        defer { Task { await self.ensureWatching() } }

        // Stale .live: the channel died while nobody was watching. Reset, but do
        // NOT disconnect -- the SSH connection is fine and herdr reattaches.
        if status == .live, channel?.isOpen != true {
            channel = nil
            terminal.pty = nil
            status = .idle
        }
        // A previous attempt failed: the cached connection may be a corpse
        // (HostConnection.state is never invalidated by transport death).
        // Drop it so start() reconnects instead of reusing it.
        if case .failed = status {
            await connection.disconnect()
        }
        await start()
    }

    func stop() async {
        operationGeneration &+= 1
        channel?.close()
        channel = nil
        // Its own channel, so it needs its own close -- otherwise every closed
        // tab leaves a `tail -F` running on the host for the life of the process.
        watchChannel?.close()
        watchChannel = nil
        terminal.pty = nil
        // The emulator's CADisplayLink is scheduled on the main run loop and is
        // invalidated ONLY here -- the view's `onDisappear` merely lowers its
        // preferred frame-rate range. Without this, every closed tab leaves a
        // display link ticking for the life of the process.
        terminal.stop()
        // Each tab owns its own `HostConnection` (built per-session in
        // `HostTabsModel.session(for:)`), so tearing it down here cannot disturb
        // another tab. Without this, every closed tab leaves one idle
        // authenticated SSH connection open for the life of the process --
        // neither `HostConnection` nor `NIOSSHTransport` has a `deinit` to catch it.
        await connection.disconnect()
        status = .idle
    }

    /// Invoked (hopped to the main actor) only when the off-main scan in `start()`'s
    /// output closure finds the sentinel. `generation` pins this callback to the
    /// specific `start()` call — and therefore the specific channel — that produced
    /// it, so a Task queued by a channel `stop()`/a later `start()` has since
    /// superseded can't mislabel the newer session.
    private func markHerdrMissing(generation: UInt64) {
        guard generation == operationGeneration, !sawMissingSentinel else { return }
        sawMissingSentinel = true
        if status == .live {
            status = .herdrMissing
        }
        // else status == .connecting: start() itself will read the latch when it
        // resumes, via `sawMissingSentinel ? .herdrMissing : .live`.
    }

    private static func message(for state: HostConnection.State) -> String {
        switch state {
        case .failed(let message): return message
        default: return "Could not connect"
        }
    }
}
