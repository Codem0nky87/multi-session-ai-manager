import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite @MainActor struct HerdrHostSessionTests {
    private func makeSession(
        transport: FakeSSHTransport,
        sessionName: String? = nil,
        knownHosts: KnownHostsStore? = nil
    ) throws -> HerdrHostSession {
        let suite = "HerdrHostSessionTests.\(UUID().uuidString)"
        let keyStore = KeyStore(backing: InMemoryKeychain())
        let keyID = try keyStore.generateEd25519(label: "thin-herdr")
        return HerdrHostSession(
            connection: HostConnection(
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
            ),
            sessionName: sessionName
        )
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
        let session = try makeSession(transport: transport)
        await session.start()
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
        // Likewise the display link: nothing but `stop()` invalidates it, and a
        // closed tab that leaves it scheduled ticks for the life of the process.
        #expect(session.terminal.isRenderLoopRunning == false)
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
        #expect(transport.openedPTYs.count == 2)
        // A dead CHANNEL over a healthy CONNECTION must reuse that connection.
        // Tearing it down here would turn every backgrounded tab into a full
        // re-authentication.
        #expect(transport.disconnectCount == 0)
    }

    @Test func ensureLiveDoesNothingWhileTheChannelIsHealthy() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(transport: transport)
        await session.start()

        await session.ensureLive()

        #expect(transport.openedPTYs.count == 1)
        #expect(transport.disconnectCount == 0)
    }

    // Regression (C1): the transport can die without anything invalidating
    // `HostConnection.state`, which stays `.connected`. `start()` then skips the
    // reconnect and opens a PTY on a corpse -- forever, however many times the
    // user taps Retry. `ensureLive()` drops the cached connection after a failure
    // so the next attempt reconnects for real.
    @Test func retryAfterTransportDeathReconnectsInsteadOfReusingTheDeadConnection() async throws {
        let transport = FakeSSHTransport()
        let session = try makeSession(transport: transport)
        await session.start()
        #expect(session.status == .live)

        await transport.disconnect()                  // TCP dies; nobody tells HostConnection
        #expect(session.connection.state == .connected)   // the stale cache, exactly as shipped

        await session.ensureLive()                    // stale .live -> reset -> start() over the corpse
        guard case .failed = session.status else {
            Issue.record("Expected .failed against a dead transport, got \(session.status)")
            return
        }

        await session.ensureLive()                    // the Retry the user actually taps

        #expect(session.status == .live)
        #expect(transport.isConnected)
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
}
