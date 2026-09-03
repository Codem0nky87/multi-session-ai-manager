import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite @MainActor struct HerdrHostSessionTests {
    private func makeSession(
        transport: FakeSSHTransport,
        sessionName: String? = nil,
        knownHosts: KnownHostsStore? = nil,
        liveness: HerdrHostSession.LivenessPolicy = .init(),
        recovery: HerdrHostSession.RecoveryPolicy = .init(),
        automaticRecoveryEnabled: Bool = true,
        terminal: TerminalEmulator? = nil
    ) throws -> HerdrHostSession {
        let suite = "HerdrHostSessionTests.\(UUID().uuidString)"
        let keyStore = KeyStore(backing: InMemoryKeychain())
        let keyID = try keyStore.generateEd25519(label: "thin-herdr")
        let connection = HostConnection(
            host: Host(
                name: "mac",
                address: "192.0.2.10",
                username: "alice",
                keyID: keyID,
                defaultWorkdir: "/Users/alice"
            ),
            keyStore: keyStore,
            knownHosts: knownHosts ?? KnownHostsStore(defaults: UserDefaults(suiteName: suite)!),
            transport: transport
        )
        let session: HerdrHostSession
        if let terminal {
            session = HerdrHostSession(
                connection: connection,
                sessionName: sessionName,
                terminal: terminal,
                liveness: liveness,
                recovery: recovery
            )
        } else {
            session = HerdrHostSession(
                connection: connection,
                sessionName: sessionName,
                liveness: liveness,
                recovery: recovery
            )
        }
        session.automaticRecoveryEnabled = automaticRecoveryEnabled
        return session
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func herdrPTYCount(_ transport: FakeSSHTransport, sessionName: String? = nil) -> Int {
        let command = HerdrLaunchCommand.launch(sessionName: sessionName)
        return transport.openedPTYs.filter { $0.command == command }.count
    }

    private func watchPTYs(_ transport: FakeSSHTransport) -> [FakePTYChannel] {
        let command = RemoteFileDownload.watchCommand(identity: "default")
        return transport.openedPTYs.filter { $0.command == command }
    }

    @Test func defaultTerminalKeepsScrollbackOnTheHost() throws {
        let session = try makeSession(transport: FakeSSHTransport())

        #expect(session.terminal.history == .hostOwned)
        #expect(session.terminal.localScrollbackLimit == 0)
    }

    @Test func successfulStartBindsThePTYAndGoesLive() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(transport: transport)

        await session.start()

        #expect(session.status == .live)
        #expect(session.terminal.pty != nil)
        #expect(transport.openedPTYs.last?.command.contains("exec herdr") == true)
    }

    @Test func namedSessionReachesTheRemoteCommand() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(transport: transport, sessionName: "build")

        await session.start()

        #expect(transport.openedPTYs.last?.command == HerdrLaunchCommand.launch(sessionName: "build"))
        // and prove the name is not simply absent
        #expect(HerdrLaunchCommand.remoteScript(sessionName: "build").contains("--session 'build'"))
    }

    @Test func missingHerdrOnTheHostIsReportedExplicitly() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(transport: transport)

        await session.start()
        transport.openedPTYs.last?.emit(Data("\(HerdrLaunchCommand.missingSentinel)\n".utf8))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(session.status == .herdrMissing)
    }

    @Test func authenticationFailureSurfacesAsFailedNotACrash() async throws {
        let transport = FakeSSHTransport()
        transport.connectError = SSHTransportError.hostKeyRejected
        let session = try makeSession(transport: transport)

        await session.start()

        guard case .failed = session.status else {
            Issue.record("Expected .failed, got \(session.status)")
            return
        }
    }

    @Test func stoppingClosesThePTYAndUnbindsTheTerminal() async throws {
        let transport = FakeSSHTransport()
        let clock = TestTerminalFrameClock()
        let terminal = TerminalEmulator(frameClock: clock)
        let session = try makeSession(transport: transport, terminal: terminal)
        #expect(!session.terminal.isRenderLoopRunning)
        await session.start()
        session.terminal.feed(Data("pending".utf8))
        await Task.yield()
        #expect(session.terminal.isRenderLoopRunning)

        await session.stop()

        #expect(session.status == .idle)
        #expect(session.terminal.pty == nil)
        // `stop()` must close the channel ITSELF. Asserting `closed` after the
        // fact proves nothing: the transport's own disconnect closes every PTY
        // it vended, so this held even with `channel?.close()` deleted. The
        // snapshot is taken at the START of `disconnect()`, before that side
        // effect runs, so only the session's own close can satisfy it.
        #expect(transport.ptyClosedStatesAtLastDisconnect.last == true)
        #expect(transport.openedPTYs.last?.closed == true)
        // Likewise pending rendering is retired permanently by session teardown.
        #expect(session.terminal.isRenderLoopRunning == false)
        session.terminal.feed(Data("late".utf8))
        await Task.yield()
        #expect(session.terminal.isRenderLoopRunning == false)
        #expect(session.terminal.coreCursorColumn == 0)
    }

    // Regression: `stop()` used to close the PTY and the terminal but leave the
    // underlying SSH connection authenticated and open, so every closed tab
    // leaked one idle connection for the life of the process.
    @Test func stoppingDisconnectsTheUnderlyingSSHConnection() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(transport: transport)
        await session.start()

        await session.stop()

        #expect(transport.disconnectCount == 1)
        #expect(transport.isConnected == false)
        #expect(session.connection.state == .idle)
    }

    // NOT a strong-vs-weak proof: `FakeSSHTransport.openedPTYs` is `private(set)`
    // and retains every channel it vends for as long as `transport` (held
    // transitively by `session.connection`) is reachable, so this harness cannot
    // distinguish `HerdrHostSession` holding its own strong reference to the
    // channel from `channel` being `weak` and merely riding along on the fake's
    // retention — deleting `self.channel = channel` in `start()` still leaves
    // every assertion below passing. The real protection against the channel
    // (and the remote herdr process behind it) disappearing is structural, not
    // something this fake can exercise: `TerminalEmulator.pty` is `weak`, which
    // makes `HerdrHostSession.channel` the one app-side strong reference standing
    // between a live PTY and deallocation. What this test does pin: the session
    // keeps reporting a live, open, bound channel across a real actor hop.
    @Test func liveStatusAndOpenChannelSurviveAnActorHop() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(transport: transport)
        await session.start()

        weak var weakChannel = transport.openedPTYs.last
        await Task.yield()

        #expect(weakChannel != nil)
        #expect(session.status == .live)
        #expect(weakChannel?.isOpen == true)
    }

    @Test func echoedLaunchCommandDoesNotTriggerMissingDetection() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(transport: transport)
        await session.start()

        // a real PTY echoes the command it was sent
        let echoed = transport.openedPTYs.last?.command ?? ""
        transport.openedPTYs.last?.emit(Data((echoed + "\n").utf8))
        try? await Task.sleep(for: .milliseconds(50))

        #expect(session.status == .live)
    }

    @Test func aDroppedChannelIsDetectedAndReattached() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(transport: transport)
        await session.start()
        #expect(session.status == .live)

        transport.openedPTYs.forEach { $0.close() }   // simulate the channel dropping
        await session.ensureLive()

        // herdr attaches to the same persistent session, so a reattach is a plain restart
        #expect(session.status == .live)
        #expect(herdrPTYCount(transport) == 2)
        // A dead CHANNEL over a healthy CONNECTION must reuse that connection.
        // Tearing it down here would turn every backgrounded tab into a full
        // re-authentication.
        #expect(transport.disconnectCount == 0)
    }

    // MARK: - Bounded automatic recovery

    @Test func defaultRecoveryPolicyAttemptsImmediatelyThenAfterTwoAndFiveSeconds() {
        #expect(HerdrHostSession.RecoveryPolicy().attemptDelays == [
            .zero,
            .seconds(2),
            .seconds(5),
        ])
        #expect(HerdrHostSession.RecoveryPolicy(attemptDelays: []).attemptDelays == [
            .zero,
            .seconds(2),
            .seconds(5),
        ])
    }

    @Test func unexpectedPTYCloseOverHealthySSHReattachesWithoutPolling() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(
            transport: transport,
            sessionName: "build",
            recovery: .init(attemptDelays: [.zero, .milliseconds(10), .milliseconds(20)])
        )
        await session.start()

        transport.openedPTYs.last?.close()
        try await waitUntil { self.herdrPTYCount(transport, sessionName: "build") == 2 }

        #expect(session.status == .live)
        #expect(transport.disconnectCount == 0)
        let replacement = transport.openedPTYs.filter {
            $0.command == HerdrLaunchCommand.launch(sessionName: "build")
        }.last
        #expect(replacement?.isOpen == true)
    }

    @Test func inactivePTYLossWaitsForReselectionBeforeRecovering() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(
            transport: transport,
            recovery: .init(attemptDelays: [.zero, .milliseconds(10), .milliseconds(20)]),
            automaticRecoveryEnabled: false
        )
        await session.start()
        await session.ensureWatching()
        let attachesBeforeLoss = herdrPTYCount(transport)
        let watcher = watchPTYs(transport).last
        let herdrPTY = transport.openedPTYs.last {
            $0.command == HerdrLaunchCommand.launch(sessionName: nil)
        }

        herdrPTY?.close()
        try await waitUntil { session.status != .live }
        #expect(session.status == .idle)
        try await Task.sleep(for: .milliseconds(80))

        #expect(herdrPTYCount(transport) == attachesBeforeLoss)
        #expect(session.terminal.pty == nil)
        #expect(watcher?.closed == true)

        session.automaticRecoveryEnabled = true
        await session.ensureLive()

        #expect(session.status == .live)
        #expect(herdrPTYCount(transport) == attachesBeforeLoss + 1)
    }

    @Test func hostLossStopsAfterThreeRecoveryAttempts() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(
            transport: transport,
            recovery: .init(
                attemptDelays: [.zero, .milliseconds(10), .milliseconds(20), .milliseconds(20)]
            )
        )
        await session.start()
        let connectsBeforeLoss = transport.connectAttemptCount

        transport.connectErrors = [
            .commandFailed("attempt one"),
            .commandFailed("attempt two"),
            .commandFailed("attempt three"),
            .commandFailed("policy must not allow attempt four"),
        ]
        await transport.disconnect()
        try await waitUntil { transport.connectAttemptCount - connectsBeforeLoss == 3 }
        try await Task.sleep(for: .milliseconds(80))

        #expect(transport.connectAttemptCount - connectsBeforeLoss == 3)
        guard case .failed = session.status else {
            Issue.record("Expected recovery exhaustion to remain failed, got \(session.status)")
            return
        }

        transport.connectErrors = [nil]
        await session.ensureLive()

        #expect(transport.connectAttemptCount - connectsBeforeLoss == 3)
        guard case .failed = session.status else {
            Issue.record("Expected lifecycle reconciliation to preserve terminal failure")
            return
        }
    }

    @Test func successfulSecondAttemptCancelsTheThird() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(
            transport: transport,
            recovery: .init(attemptDelays: [.zero, .milliseconds(10), .milliseconds(80)])
        )
        await session.start()
        let connectsBeforeLoss = transport.connectAttemptCount

        transport.connectErrors = [.commandFailed("attempt one"), nil]
        await transport.disconnect()
        try await waitUntil { session.status == .live && transport.connectAttemptCount - connectsBeforeLoss == 2 }
        try await Task.sleep(for: .milliseconds(120))

        #expect(transport.connectAttemptCount - connectsBeforeLoss == 2)
        #expect(herdrPTYCount(transport) == 2)
    }

    @Test func disablingAutomaticRecoveryCancelsDelayedAttempts() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(
            transport: transport,
            recovery: .init(attemptDelays: [.zero, .milliseconds(150), .milliseconds(150)])
        )
        await session.start()
        let connectsBeforeLoss = transport.connectAttemptCount

        transport.connectErrors = [
            .commandFailed("attempt one"),
            .commandFailed("attempt two"),
            .commandFailed("attempt three"),
        ]
        await transport.disconnect()
        try await waitUntil { transport.connectAttemptCount - connectsBeforeLoss == 1 }

        session.automaticRecoveryEnabled = false
        try await Task.sleep(for: .milliseconds(220))

        #expect(transport.connectAttemptCount - connectsBeforeLoss == 1)
        #expect(session.status == .idle)

        transport.connectErrors = [nil]
        await session.retry()

        #expect(session.status == .live)
        #expect(transport.connectAttemptCount - connectsBeforeLoss == 2)
    }

    @Test func manualRetryAfterExhaustionGetsAFreshThreeAttemptBudget() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(
            transport: transport,
            recovery: .init(attemptDelays: [.zero, .milliseconds(10), .milliseconds(20)])
        )
        await session.start()
        let connectsBeforeLoss = transport.connectAttemptCount

        transport.connectErrors = [
            .commandFailed("automatic one"),
            .commandFailed("automatic two"),
            .commandFailed("automatic three"),
        ]
        await transport.disconnect()
        try await waitUntil {
            if case .failed = session.status {
                return transport.connectAttemptCount - connectsBeforeLoss == 3
            }
            return false
        }

        transport.connectErrors = [
            .commandFailed("manual one"),
            .commandFailed("manual two"),
            nil,
        ]
        await session.retry()

        #expect(session.status == .live)
        #expect(transport.connectAttemptCount - connectsBeforeLoss == 6)
    }

    @Test func manualRetryReplacesAnActiveAutomaticCycleWithAFreshBudget() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(
            transport: transport,
            recovery: .init(attemptDelays: [.zero, .milliseconds(300), .milliseconds(300)])
        )
        await session.start()
        let connectsBeforeLoss = transport.connectAttemptCount

        transport.connectErrors = [.commandFailed("automatic one")]
        await transport.disconnect()
        try await waitUntil {
            session.status == .connecting && transport.connectAttemptCount - connectsBeforeLoss == 1
        }

        transport.connectErrors = [
            .commandFailed("manual one"),
            .commandFailed("manual two"),
            nil,
        ]
        await session.retry()

        #expect(session.status == .live)
        #expect(transport.connectAttemptCount - connectsBeforeLoss == 4)
        await session.stop()
    }

    @Test func duplicateEnsureLiveCallsCoalesceWithoutResettingTheBudget() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(
            transport: transport,
            recovery: .init(attemptDelays: [.zero, .milliseconds(100), .milliseconds(100)])
        )
        await session.start()
        let connectsBeforeLoss = transport.connectAttemptCount

        transport.connectErrors = (1...8).map {
            .commandFailed("unexpected extra attempt \($0)")
        }
        await transport.disconnect()
        try await waitUntil {
            session.status == .connecting && transport.connectAttemptCount - connectsBeforeLoss == 1
        }

        let firstReconciliation = Task { await session.ensureLive() }
        await Task.yield()
        let duplicateReconciliation = Task { await session.ensureLive() }
        await firstReconciliation.value
        await duplicateReconciliation.value

        #expect(transport.connectAttemptCount - connectsBeforeLoss == 3)
        guard case .failed = session.status else {
            Issue.record("Expected the shared recovery cycle to exhaust, got \(session.status)")
            return
        }
    }

    @Test func disablingRecoveryCancelsCycleStartedByEnsureLive() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(
            transport: transport,
            recovery: .init(attemptDelays: [.zero, .milliseconds(150), .milliseconds(150)])
        )
        await session.start()
        let connectsBeforeLoss = transport.connectAttemptCount

        transport.structuredCommandResults = [.failure(.timedOut)]
        transport.connectErrors = [
            .commandFailed("attempt one"),
            .commandFailed("attempt two"),
            .commandFailed("attempt three"),
        ]
        let reconciliation = Task { await session.ensureLive() }
        try await waitUntil {
            session.status == .connecting && transport.connectAttemptCount - connectsBeforeLoss == 1
        }

        session.automaticRecoveryEnabled = false
        await reconciliation.value
        try await Task.sleep(for: .milliseconds(220))

        #expect(transport.connectAttemptCount - connectsBeforeLoss == 1)
        #expect(session.status == .idle)
    }

    @Test func foregroundingResumesAnAutomaticCycleCancelledInBackground() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(
            transport: transport,
            recovery: .init(attemptDelays: [.zero, .milliseconds(150), .milliseconds(150)])
        )
        await session.start()
        let connectsBeforeLoss = transport.connectAttemptCount

        transport.connectErrors = [.commandFailed("backgrounded attempt")]
        await transport.disconnect()
        try await waitUntil {
            session.status == .connecting && transport.connectAttemptCount - connectsBeforeLoss == 1
        }

        session.automaticRecoveryEnabled = false
        #expect(session.status == .idle)

        transport.connectErrors = [nil]
        session.automaticRecoveryEnabled = true
        await session.ensureLive()

        #expect(session.status == .live)
        #expect(transport.connectAttemptCount - connectsBeforeLoss == 2)
    }

    @Test func deliberateStopDoesNotRecoverThroughPTYClose() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(
            transport: transport,
            recovery: .init(attemptDelays: [.zero, .milliseconds(10), .milliseconds(20)])
        )
        await session.start()

        await session.stop()
        try await Task.sleep(for: .milliseconds(80))

        #expect(session.status == .idle)
        #expect(herdrPTYCount(transport) == 1)
        #expect(transport.isConnected == false)
    }

    @Test func recoverySkipsPTYThatClosesBeforeOpenReturns() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(
            transport: transport,
            recovery: .init(attemptDelays: [.zero, .milliseconds(80), .milliseconds(100)])
        )
        await session.start()

        transport.closeNextPTYBeforeReturning = true
        transport.openedPTYs.last?.close()
        try await waitUntil { self.herdrPTYCount(transport) == 2 }

        #expect(session.status != .live)
        let shortLivedChannel = transport.openedPTYs.filter {
            $0.command == HerdrLaunchCommand.launch(sessionName: nil)
        }.last
        #expect(shortLivedChannel?.isOpen == false)

        try await waitUntil { session.status == .live && self.herdrPTYCount(transport) == 3 }

        #expect(session.terminal.pty != nil)
    }

    @Test func replacementPTYCloseDuringRecoveryHandoffStartsANewCycle() async throws {
        let transport = FakeSSHTransport()
        let watchGate = PTYOpenGate()
        let watchCommand = RemoteFileDownload.watchCommand(identity: "default")
        let session = try makeSession(
            transport: transport,
            recovery: .init(attemptDelays: [.zero, .milliseconds(10), .milliseconds(20)])
        )
        await session.start()
        transport.beforeOpenPTY = { command in
            guard command == watchCommand else { return }
            await watchGate.suspendOnce()
        }

        transport.openedPTYs.last?.close()
        await watchGate.waitUntilSuspended()
        let replacement = transport.openedPTYs.filter {
            $0.command == HerdrLaunchCommand.launch(sessionName: nil)
        }.last
        replacement?.close()
        await Task.yield()
        await watchGate.resume()
        try await waitUntil { session.status == .live && self.herdrPTYCount(transport) == 3 }

        #expect(replacement?.isOpen == false)
        #expect(session.terminal.pty?.isOpen == true)
    }

    @Test func concurrentWatchRequestsOpenOnlyOneRemoteTail() async throws {
        let transport = FakeSSHTransport()
        let watchGate = PTYOpenGate()
        let watchCommand = RemoteFileDownload.watchCommand(identity: "default")
        let session = try makeSession(transport: transport)
        await session.start()
        transport.beforeOpenPTY = { command in
            guard command == watchCommand else { return }
            await watchGate.suspendOnce()
        }

        let first = Task { await session.ensureWatching() }
        await watchGate.waitUntilSuspended()
        let concurrent = Task { await session.ensureWatching() }
        await Task.yield()
        await watchGate.resume()
        await first.value
        await concurrent.value

        let watchers = watchPTYs(transport)
        #expect(watchers.count == 1)
        #expect(watchers.filter(\.isOpen).count == 1)
        await session.stop()
    }

    @Test func supersededWatchCandidateIsClosedInsteadOfPublished() async throws {
        let transport = FakeSSHTransport()
        let watchGate = PTYOpenGate()
        let watchCommand = RemoteFileDownload.watchCommand(identity: "default")
        let session = try makeSession(
            transport: transport,
            recovery: .init(attemptDelays: [.zero, .milliseconds(10), .milliseconds(20)])
        )
        await session.start()
        transport.beforeOpenPTY = { command in
            guard command == watchCommand else { return }
            await watchGate.suspendOnce()
        }

        let staleOpen = Task { await session.ensureWatching() }
        await watchGate.waitUntilSuspended()
        transport.openedPTYs.last?.close()
        try await waitUntil {
            self.herdrPTYCount(transport) == 2 && self.watchPTYs(transport).count == 1
        }
        await watchGate.resume()
        await staleOpen.value
        try await waitUntil { self.watchPTYs(transport).count == 2 }

        let watchers = watchPTYs(transport)
        #expect(watchers.filter(\.isOpen).count == 1)
        #expect(watchers.last?.closed == true)
        await session.stop()
    }

    @Test func ensureLiveDoesNothingWhileTheChannelIsHealthy() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(transport: transport)
        await session.start()

        await session.ensureLive()

        #expect(herdrPTYCount(transport) == 1)
        #expect(transport.disconnectCount == 0)
    }

    // Regression (C1): the transport can die while HostConnection still caches
    // `.connected`. EOF recovery must probe that stale state and redial instead
    // of trying to attach over the corpse.
    @Test func automaticRecoveryReconnectsInsteadOfReusingADeadConnection() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(
            transport: transport,
            recovery: .init(attemptDelays: [.zero, .milliseconds(10), .milliseconds(20)])
        )
        await session.start()
        #expect(session.status == .live)

        await transport.disconnect()                  // TCP dies; nobody tells HostConnection
        #expect(session.connection.state == .connected)   // the stale cache, exactly as shipped
        try await waitUntil { session.status == .live && transport.connectAttemptCount == 2 }

        #expect(transport.isConnected)
        #expect(herdrPTYCount(transport) == 2)
        #expect(transport.disconnectCount == 2) // simulated loss + stale-cache retirement
    }

    // Regression (C4): a changed host key used to be flattened into
    // `.failed("Host key changed (...)")` behind a Retry that could only ever
    // re-detect the same mismatch. It now has its own status, and the only
    // recovery is the explicit, destructive trust action.
    @Test func aChangedHostKeyGetsItsOwnStatusAndAnExplicitTrustRecovery() async throws {
        let suite = "HerdrHostSessionTests.hostKey.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let knownHosts = KnownHostsStore(defaults: defaults)
        knownHosts.pin(host: "192.0.2.10", fingerprint: "AAAAPREVIOUSLYPINNEDKEY")
        let transport = FakeSSHTransport()
        let session = try makeSession(transport: transport, knownHosts: knownHosts)

        await session.start()
        #expect(session.status == .hostKeyChanged(transport.hostKeyToPresent))

        // Retrying alone can never clear it -- the mismatch is re-detected.
        await session.ensureLive()
        #expect(session.status == .hostKeyChanged(transport.hostKeyToPresent))

        // Only the explicit decision does.
        await session.connection.trustChangedKeyAndReconnect()
        await session.ensureLive()

        #expect(session.status == .live)
    }

    // MARK: - Idle-connection heartbeat (issue #1)
    //
    // A NAT/firewall evicting an idle flow leaves the TCP connection HALF-OPEN:
    // no FIN or RST ever arrives, the inbound stream simply goes silent, and
    // `PTYChannel.isOpen` stays true forever. Every reconciliation that trusts
    // `isOpen` therefore no-ops while the tab sits frozen on screen. Only
    // round-trip traffic with a deadline can tell a quiet-but-healthy link from
    // a dead one.

    @Test func anIdleDeadConnectionIsDetectedAndRecoveredWithoutUserInteraction() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(
            transport: transport,
            liveness: .init(interval: .milliseconds(40), probeTimeout: .milliseconds(500)),
            recovery: .init(attemptDelays: [.zero, .milliseconds(10), .milliseconds(20)])
        )
        await session.start()
        #expect(session.status == .live)

        // The link dies with no EOF: the channel still LOOKS open. One probe
        // fails; the redial and every later probe succeed.
        transport.structuredCommandResults = [.failure(.timedOut)]

        // Recovery also reopens the outbox watch (its own PTY), so count only
        // the herdr PTYs when asserting the reattach.
        let herdrCommand = HerdrLaunchCommand.launch(sessionName: nil)
        func herdrPTYCount() -> Int {
            transport.openedPTYs.filter { $0.command == herdrCommand }.count
        }
        for _ in 0..<100 {
            if herdrPTYCount() >= 2, session.status == .live { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(session.status == .live)
        #expect(herdrPTYCount() == 2)
        // A dead CONNECTION (unlike a dead channel) must be torn down and
        // redialled -- reusing it would reopen a PTY over a corpse.
        #expect(transport.disconnectCount == 1)
        await session.stop()
    }

    @Test func ensureLiveProbesAndRecoversAHalfOpenConnection() async throws {
        let transport = FakeSSHTransport()
        // Default policy: the 30s heartbeat never fires inside this test, so
        // any recovery observed below is ensureLive()'s own doing.
        let session = try makeSession(transport: transport)
        await session.start()
        #expect(transport.openedPTYs.last?.isOpen == true)

        transport.structuredCommandResults = [.failure(.timedOut)]
        await session.ensureLive()

        #expect(session.status == .live)
        let herdrCommand = HerdrLaunchCommand.launch(sessionName: nil)
        #expect(transport.openedPTYs.filter { $0.command == herdrCommand }.count == 2)
        #expect(transport.disconnectCount == 1)
        await session.stop()
    }

    @Test func aDeadConnectionOnAnUnreachableHostLandsOnFailedWithoutLooping() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(
            transport: transport,
            liveness: .init(interval: .milliseconds(40), probeTimeout: .milliseconds(500)),
            recovery: .init(attemptDelays: [.zero, .milliseconds(10), .milliseconds(20)])
        )
        await session.start()

        transport.commandError = SSHCommandExecutionError.timedOut      // every probe fails
        transport.connectError = SSHTransportError.commandFailed("boom") // and so does the redial

        var sawFailed = false
        for _ in 0..<100 {
            if case .failed = session.status { sawFailed = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sawFailed)

        // Landing on .failed must END the cycle -- the overlay's Retry is the
        // only way forward. A silent retry loop here would redial a dead host
        // every interval for as long as the tab is open.
        let commandsAfterFailure = transport.commandsRun.count
        let ptysAfterFailure = transport.openedPTYs.count
        try await Task.sleep(for: .milliseconds(200))
        #expect(transport.commandsRun.count == commandsAfterFailure)
        #expect(transport.openedPTYs.count == ptysAfterFailure)
        // The heartbeat begins recovery by closing the old PTY, which emits EOF.
        // That concurrent signal must coalesce rather than adding another cycle.
        #expect(transport.connectAttemptCount == 4) // initial connect + three recovery attempts
        guard case .failed = session.status else {
            Issue.record("Expected .failed to be terminal, got \(session.status)")
            return
        }
    }

    @Test func aStoppedSessionIsNeverResurrectedByItsHeartbeat() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(
            transport: transport,
            liveness: .init(interval: .milliseconds(40), probeTimeout: .milliseconds(500))
        )
        await session.start()
        await session.stop()

        // A zombie heartbeat would see the disconnected transport as a dead
        // connection and "recover" it -- reconnecting a tab the user closed.
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.status == .idle)
        #expect(transport.openedPTYs.count == 1)
        #expect(transport.isConnected == false)
    }

    // The battery half of the design: while output is flowing, the connection
    // is self-evidently alive and the heartbeat must not add traffic on top.
    @Test func probeIsSuppressedWhileOutputProvesTheConnectionAlive() {
        let now = ContinuousClock.now
        #expect(HerdrHostSession.shouldProbe(
            lastOutput: now - .seconds(31), now: now, interval: .seconds(30)
        ))
        #expect(!HerdrHostSession.shouldProbe(
            lastOutput: now - .seconds(5), now: now, interval: .seconds(30)
        ))
    }
}

private actor PTYOpenGate {
    private var suspended = false
    private var didSuspend = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func suspendOnce() async {
        guard !didSuspend else { return }
        didSuspend = true
        suspended = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilSuspended() async {
        guard !suspended else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resume() {
        suspended = false
        continuation?.resume()
        continuation = nil
    }
}
