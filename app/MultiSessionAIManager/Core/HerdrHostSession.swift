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

    /// Tunables for the idle-connection heartbeat. One mechanism serves two
    /// goals: the probe's round trip refreshes NAT/firewall flow state
    /// (keepalive), and its deadline is the only reliable detector of a
    /// half-open TCP link, which never delivers an EOF (issue #1).
    ///
    /// Battery: this costs nothing in background -- iOS suspends the process,
    /// freezing the timer -- and nothing while output is flowing, because
    /// `shouldProbe` skips the probe unless the link has been quiet for a full
    /// interval.
    struct LivenessPolicy: Sendable {
        /// Probe cadence while live and quiet. 30s stays inside common
        /// NAT/firewall/WARP idle-eviction windows (typically 60s+).
        var interval: Duration = .seconds(30)
        /// How long a probe may hang before the connection is declared dead.
        /// A half-open link never answers; without this bound, detection
        /// would wait on kernel TCP retransmission timeouts (minutes).
        var probeTimeout: Duration = .seconds(10)
    }

    let connection: HostConnection
    let sessionName: String?
    /// Identifies this tab's outbox watcher on the host. Stable across app
    /// launches so a relaunch evicts its own orphan rather than adding to it.
    let watchIdentity: String
    let terminal: TerminalEmulator
    let liveness: LivenessPolicy

    private(set) var status: Status = .idle
    private var channel: PTYChannel?
    /// The idle-connection heartbeat (issue #1). Lives exactly as long as one
    /// `.live` stretch: started when `start()` lands on `.live`, retired by
    /// `stop()`, by any status change (generation guard), or by its own
    /// recovery hand-off.
    private var heartbeat: Task<Void, Never>?
    /// Stamped off-main on every PTY output chunk; read by the heartbeat to
    /// skip probing while traffic already proves the link alive.
    private let lastOutputAt = NIOLockedValueBox(ContinuousClock.now)
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
        terminal: TerminalEmulator = TerminalEmulator(),
        liveness: LivenessPolicy = .init()
    ) {
        self.connection = connection
        self.sessionName = sessionName
        self.watchIdentity = watchIdentity
        self.terminal = terminal
        self.liveness = liveness
    }

    /// Whether the heartbeat should spend a round trip: only when the link has
    /// been quiet for a full interval. Output arriving IS proof of liveness,
    /// so an actively streaming agent generates zero extra traffic.
    static func shouldProbe(
        lastOutput: ContinuousClock.Instant,
        now: ContinuousClock.Instant,
        interval: Duration
    ) -> Bool {
        now - lastOutput >= interval
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
            let lastOutputAt = self.lastOutputAt
            lastOutputAt.withLockedValue { $0 = .now }
            let channel = try await connection.openHerdrPTY(
                sessionName: sessionName,
                cols: terminal.cols,
                rows: terminal.rows
            ) { [weak self] data in
                lastOutputAt.withLockedValue { $0 = .now }
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
            if status == .live {
                startHeartbeat(generation: generation)
            }
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

        // An open-looking channel proves nothing: a NAT-evicted idle flow dies
        // with no FIN, so `isOpen` stays true over a corpse forever (issue #1).
        // Probe before trusting `.live`, so a tab switch or a return to the
        // foreground recovers a half-open connection instead of no-opping.
        if status == .live, channel?.isOpen == true {
            let generation = operationGeneration
            let alive = await connection.verifyAlive(timeout: liveness.probeTimeout)
            guard operationGeneration == generation else { return }
            if status == .live, !alive {
                await recoverLostConnection()
            }
        }

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

    /// While `.live` and quiet, probe the connection every `interval`. The
    /// probe's traffic is the keepalive; its failure is the drop detector. On
    /// failure the session recovers itself -- herdr reattaches to the same
    /// remote session, so one silent redial is safe. If the redial fails,
    /// `start()` lands on `.failed`, no new heartbeat is started, and the
    /// overlay's Retry is the only way forward: no retry loop.
    ///
    /// Battery: in the background iOS suspends the process (the sleep simply
    /// freezes), and while output is flowing `shouldProbe` skips the round
    /// trip -- so probes only happen foreground AND idle, which is exactly
    /// when NAT/firewall flow state is at risk of eviction.
    private func startHeartbeat(generation: UInt64) {
        heartbeat?.cancel()
        let lastOutputAt = self.lastOutputAt
        let policy = liveness
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: policy.interval)
                guard !Task.isCancelled, let self else { return }
                guard self.operationGeneration == generation, self.status == .live else { return }
                let lastOutput = lastOutputAt.withLockedValue { $0 }
                guard Self.shouldProbe(
                    lastOutput: lastOutput,
                    now: .now,
                    interval: policy.interval
                ) else { continue }
                let alive = await self.connection.verifyAlive(timeout: policy.probeTimeout)
                guard self.operationGeneration == generation, self.status == .live else { return }
                guard !alive else { continue }
                await self.recoverLostConnection()
                // ensureLive (not start) so the outbox watch is re-established
                // along with the PTY. Its own start() supersedes this task's
                // generation, so the loop must end here either way.
                await self.ensureLive()
                return
            }
        }
    }

    /// The connection under a live tab is dead (a probe failed). Tear down the
    /// channel AND the connection -- unlike a dead channel over a healthy
    /// connection, reusing this one would just reopen a PTY over a corpse.
    private func recoverLostConnection() async {
        channel?.close()
        channel = nil
        terminal.pty = nil
        status = .idle
        await connection.disconnect()
    }

    func stop() async {
        operationGeneration &+= 1
        heartbeat?.cancel()
        heartbeat = nil
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
