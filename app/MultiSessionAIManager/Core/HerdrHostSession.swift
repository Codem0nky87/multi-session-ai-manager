import Foundation
import NIOConcurrencyHelpers
import Observation

/// One host tab's live state: an authenticated SSH connection, a PTY running
/// Herdr, and the terminal painting it. Herdr's own "launch or attach" semantics
/// mean recovery can reopen the named remote session without reconstructing its
/// panes on the client.
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

    /// Delays before each attempt in one recovery cycle. The default provides
    /// one immediate attach followed by two bounded retries.
    struct RecoveryPolicy: Sendable {
        let attemptDelays: [Duration]

        init(attemptDelays: [Duration] = [.zero, .seconds(2), .seconds(5)]) {
            // A cycle with no attempts would otherwise leave the session stuck
            // in `.connecting`. Recovery is deliberately capped at three, so
            // normalize both invalid extremes at the policy boundary.
            self.attemptDelays = attemptDelays.isEmpty
                ? [.zero, .seconds(2), .seconds(5)]
                : Array(attemptDelays.prefix(3))
        }
    }

    let connection: HostConnection
    let sessionName: String?
    /// Identifies this tab's outbox watcher on the host. Stable across app
    /// launches so a relaunch evicts its own orphan rather than adding to it.
    let watchIdentity: String
    let terminal: TerminalEmulator
    let liveness: LivenessPolicy
    let recovery: RecoveryPolicy

    /// Set by the selected-tab lifecycle owner. Turning this off never closes
    /// a healthy channel; it only retires an automatic cycle already in flight.
    var automaticRecoveryEnabled = false {
        didSet {
            guard !automaticRecoveryEnabled else { return }
            cancelAutomaticRecovery()
        }
    }

    private(set) var status: Status = .idle
    private var channel: PTYChannel?
    /// The idle-connection heartbeat (issue #1). Lives exactly as long as one
    /// `.live` stretch: started when `start()` lands on `.live`, retired by
    /// `stop()`, by any status change (generation guard), or by its own
    /// recovery hand-off.
    private var heartbeat: Task<Void, Never>?
    /// EOF and heartbeat failures share this one task. A manual retry replaces
    /// it and therefore receives a fresh attempt budget.
    private var recoveryTask: Task<Void, Never>?
    private var recoveryGeneration: UInt64 = 0
    private var recoveryIsAutomatic = false
    /// Stamped off-main on every PTY output chunk; read by the heartbeat to
    /// skip probing while traffic already proves the link alive.
    private let lastOutputAt = NIOLockedValueBox(ContinuousClock.now)
    /// A second channel per live tab, tailing the host's outbox so a file the
    /// user sends from the `herdr-file-viewer` plugin arrives without polling.
    /// Separate from the Herdr PTY because that one is carrying an interactive
    /// program and cannot be shared.
    private var watchChannel: PTYChannel?
    /// At most one remote tail may be opening at a time. Its generation fences
    /// the candidate across `openPTY`'s suspension so a recovery/stop cannot
    /// publish a stale watcher after a newer live stretch has begun.
    private var watchTask: Task<Void, Never>?
    private var watchGeneration: UInt64 = 0
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
        terminal: TerminalEmulator = TerminalEmulator(history: .hostOwned),
        liveness: LivenessPolicy = .init(),
        recovery: RecoveryPolicy = .init()
    ) {
        self.connection = connection
        self.sessionName = sessionName
        self.watchIdentity = watchIdentity
        self.terminal = terminal
        self.liveness = liveness
        self.recovery = recovery
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
        cancelRecovery(setIdleIfConnecting: false)
        _ = await startAttempt()
    }

    /// Performs exactly one connect/attach attempt. Recovery owns the loop and
    /// calls this once per policy delay, so this method never retries itself.
    @discardableResult
    private func startAttempt() async -> Bool {
        operationGeneration &+= 1
        let generation = operationGeneration
        status = .connecting
        sawMissingSentinel = false

        if connection.state != .connected {
            await connection.connect()
        }
        guard operationGeneration == generation, !Task.isCancelled else { return false }
        guard connection.state == .connected else {
            if case .hostKeyChanged(let fingerprint) = connection.state {
                status = .hostKeyChanged(fingerprint)
            } else {
                status = .failed(Self.message(for: connection.state))
            }
            return false
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
                rows: terminal.rows,
                onOutput: { [weak self] data in
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
                },
                onClose: { [weak self] in
                    Task { @MainActor in
                        self?.herdrPTYDidClose(generation: generation)
                    }
                }
            )
            guard operationGeneration == generation, !Task.isCancelled else {
                // Superseded by a stop() or a newer start() while we were opening
                // the PTY — don't leak the channel we just got.
                channel.close()
                return false
            }
            // EOF can race the async hand-off and arrive before openPTY returns.
            // Never publish a channel that is already closed as a live session;
            // in a recovery cycle this simply consumes the current attempt.
            guard channel.isOpen else {
                self.channel = nil
                terminal.pty = nil
                status = .failed("The remote session closed unexpectedly")
                return false
            }
            self.channel = channel
            terminal.pty = channel
            // The sentinel may have already landed (synchronously, or via a main-actor
            // hop that beat us here) while this call was suspended above; honor it
            // instead of clobbering it with an unconditional .live.
            status = sawMissingSentinel ? .herdrMissing : .live
            if status == .live {
                startHeartbeat(generation: generation)
                return true
            }
            return false
        } catch {
            guard operationGeneration == generation else { return false }
            if error is CancellationError || Task.isCancelled {
                status = .idle
                return false
            }
            status = .failed(SSHFailure.classify(message: String(describing: error)).userMessage)
            return false
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
        if let watchTask {
            await watchTask.value
            return
        }

        watchChannel?.close()
        watchChannel = nil
        watchGeneration &+= 1
        let watchAttemptGeneration = watchGeneration
        let sessionGeneration = operationGeneration

        let accumulator = NIOLockedValueBox(RemoteFileDownload.LineAccumulator())
        let task = Task { [weak self] in
            guard let self else { return }
            await self.openWatchCandidate(
                using: service,
                accumulator: accumulator,
                watchGeneration: watchAttemptGeneration,
                sessionGeneration: sessionGeneration
            )
        }
        watchTask = task
        await task.value
        guard watchGeneration == watchAttemptGeneration else { return }
        watchTask = nil
    }

    private func openWatchCandidate(
        using service: SSHService,
        accumulator: NIOLockedValueBox<RemoteFileDownload.LineAccumulator>,
        watchGeneration watchAttemptGeneration: UInt64,
        sessionGeneration: UInt64
    ) async {
        do {
            let candidate = try await service.openPTY(
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
                        self?.enqueueIncoming(
                            lines,
                            watchGeneration: watchAttemptGeneration,
                            sessionGeneration: sessionGeneration
                        )
                    }
                }
            )
            guard watchGeneration == watchAttemptGeneration,
                  operationGeneration == sessionGeneration,
                  status == .live,
                  !Task.isCancelled,
                  candidate.isOpen else {
                candidate.close()
                return
            }
            watchChannel = candidate
        } catch {
            // A host without the outbox (or without msam-send installed) simply
            // has nothing to watch. That is not a session failure -- the tab is
            // still perfectly usable -- so it must never touch `status`.
        }
    }

    private func retireWatch() {
        watchGeneration &+= 1
        watchTask?.cancel()
        watchTask = nil
        watchChannel?.close()
        watchChannel = nil
    }

    private func enqueueIncoming(
        _ lines: [String],
        watchGeneration: UInt64,
        sessionGeneration: UInt64
    ) {
        guard self.watchGeneration == watchGeneration,
              operationGeneration == sessionGeneration,
              status == .live else { return }
        enqueueIncoming(lines)
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

    /// Reconcile lifecycle state without resetting a recovery budget. Repeated
    /// foreground/selection events join the one existing cycle, while a newly
    /// detected loss starts an automatic cycle that can be cancelled when the
    /// tab is deselected or the app backgrounds.
    func ensureLive() async {
        if let recoveryTask {
            await recoveryTask.value
            return
        }

        // An open-looking channel proves nothing: a NAT-evicted idle flow dies
        // with no FIN, so `isOpen` stays true over a corpse forever (issue #1).
        // Probe before trusting `.live`, so a tab switch or a return to the
        // foreground recovers a half-open connection instead of no-opping.
        if status == .live, channel?.isOpen == true {
            let generation = operationGeneration
            let alive = await connection.verifyAlive(timeout: liveness.probeTimeout)
            guard operationGeneration == generation else { return }
            if status == .live, alive {
                await ensureWatching()
                return
            }
            if status == .live, !alive {
                let task = beginRecovery(automatic: true, connectionKnownDead: true)
                await task?.value
                return
            }
        }

        if status == .live {
            let task = beginRecovery(automatic: true)
            await task?.value
            return
        }

        guard status != .connecting else { return }

        // A first launch is not a recovery cycle.
        if status == .idle, connection.state == .idle {
            await start()
            if status == .live {
                await ensureWatching()
            }
            return
        }

        if case .hostKeyChanged = status {
            // Reconciliation cannot approve a changed key. Once the separate,
            // explicit trust action has reconnected, however, finish attaching.
            guard connection.state == .connected else { return }
            await start()
            if status == .live {
                await ensureWatching()
            }
            return
        }

        // Exhaustion is terminal until the user explicitly retries. An idle
        // lifecycle-owned session, on the other hand, receives one automatic
        // cycle when it becomes eligible again.
        if status == .idle {
            let task = beginRecovery(automatic: true)
            await task?.value
        }
    }

    /// Explicit user intent is the sole operation that replaces any in-flight
    /// cycle and grants a fresh three-attempt budget. Unlike lifecycle recovery,
    /// it remains available while automatic recovery is disabled.
    func retry() async {
        let task = beginRecovery(automatic: false)
        await task?.value
    }

    /// While `.live` and quiet, probe the connection every `interval`. The
    /// probe's traffic is the keepalive; its failure is the drop detector. On
    /// failure the session hands off to the same bounded coordinator used by
    /// PTY EOF, so concurrent loss signals cannot create parallel redials.
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
                self.detectedUnexpectedLoss(connectionKnownDead: true)
                return
            }
        }
    }

    /// Handles both heartbeat loss and a PTY close after the initial callback's
    /// generation check. The coordinator probes the cached connection itself,
    /// so healthy SSH is reused while a dead transport is discarded.
    private func detectedUnexpectedLoss(connectionKnownDead: Bool = false) {
        guard status == .live else { return }
        if automaticRecoveryEnabled {
            _ = beginRecovery(automatic: true, connectionKnownDead: connectionKnownDead)
        } else {
            // The loss has not consumed a recovery attempt. Keep it dormant so
            // foreground selection can start the normal bounded cycle; `.failed`
            // is reserved for a cycle that actually exhausted its budget.
            operationGeneration &+= 1
            heartbeat?.cancel()
            heartbeat = nil
            channel?.close()
            channel = nil
            retireWatch()
            terminal.pty = nil
            status = .idle
        }
    }

    private func herdrPTYDidClose(generation: UInt64) {
        guard operationGeneration == generation, status == .live else { return }
        detectedUnexpectedLoss()
    }

    /// Starts one bounded recovery cycle. Automatic triggers coalesce; a manual
    /// Retry always cancels the prior cycle and starts with a fresh budget.
    @discardableResult
    private func beginRecovery(
        automatic: Bool,
        connectionKnownDead: Bool = false
    ) -> Task<Void, Never>? {
        if automatic {
            guard automaticRecoveryEnabled else { return nil }
        }

        // Duplicate signals from the retired PTY are fenced by operationGeneration
        // and `.live`. If an automatic close reaches here while a task still
        // exists, it belongs to the replacement PTY already published by that
        // task, so it is a new loss and must replace the finishing cycle.
        cancelRecovery(setIdleIfConnecting: false)
        recoveryGeneration &+= 1
        let generation = recoveryGeneration
        recoveryIsAutomatic = automatic

        // Invalidate the PTY callback before closing anything locally. That
        // makes stop/retry teardown indistinguishable from an old EOF callback.
        operationGeneration &+= 1
        heartbeat?.cancel()
        heartbeat = nil
        channel?.close()
        channel = nil
        retireWatch()
        terminal.pty = nil
        status = .connecting

        let task = Task { [weak self] in
            guard let self else { return }
            await self.runRecovery(
                generation: generation,
                automatic: automatic,
                connectionKnownDead: connectionKnownDead
            )
        }
        recoveryTask = task
        return task
    }

    private func runRecovery(
        generation: UInt64,
        automatic: Bool,
        connectionKnownDead: Bool
    ) async {
        var connectionKnownDead = connectionKnownDead
        for (attemptIndex, delay) in recovery.attemptDelays.prefix(3).enumerated() {
            if attemptIndex > 0 {
                // A failed intermediate attempt is not exhaustion. Keep the
                // reconnecting state visible until the next attempt or until
                // deselection/backgrounding cancels the cycle back to idle.
                status = .connecting
            }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard recoveryGeneration == generation, !Task.isCancelled else { return }
            if automatic, !automaticRecoveryEnabled { return }

            // HostConnection caches authentication state, so probe before every
            // attach. A failed probe retires that cache and forces this attempt
            // to reconnect; a healthy connection opens only a replacement PTY.
            if connection.state == .connected {
                if !connectionKnownDead {
                    connectionKnownDead = !(await connection.verifyAlive(
                        timeout: liveness.probeTimeout
                    ))
                    guard recoveryGeneration == generation, !Task.isCancelled else { return }
                }
                if connectionKnownDead {
                    await connection.disconnect()
                    guard recoveryGeneration == generation, !Task.isCancelled else { return }
                }
            }
            connectionKnownDead = false

            let succeeded = await startAttempt()
            guard recoveryGeneration == generation, !Task.isCancelled else { return }
            if succeeded {
                await ensureWatching()
                finishRecovery(generation: generation)
                return
            }

            // Neither condition can improve through unattended retries.
            switch status {
            case .hostKeyChanged, .herdrMissing:
                finishRecovery(generation: generation)
                return
            default:
                break
            }
        }
        finishRecovery(generation: generation)
    }

    private func finishRecovery(generation: UInt64) {
        guard recoveryGeneration == generation else { return }
        recoveryTask = nil
        recoveryIsAutomatic = false
    }

    private func cancelAutomaticRecovery() {
        guard recoveryIsAutomatic else { return }
        cancelRecovery(setIdleIfConnecting: true)
    }

    private func cancelRecovery(setIdleIfConnecting: Bool) {
        recoveryGeneration &+= 1
        recoveryTask?.cancel()
        recoveryTask = nil
        recoveryIsAutomatic = false
        guard setIdleIfConnecting, status == .connecting else { return }
        operationGeneration &+= 1
        status = .idle
    }

    func stop() async {
        operationGeneration &+= 1
        cancelRecovery(setIdleIfConnecting: false)
        heartbeat?.cancel()
        heartbeat = nil
        channel?.close()
        channel = nil
        // Its own channel, so it needs its own close -- otherwise every closed
        // tab leaves a `tail -F` running on the host for the life of the process.
        retireWatch()
        terminal.pty = nil
        // Permanently shut down frame scheduling. Ordinary visibility changes
        // only retire temporary frames and remain reversible.
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
