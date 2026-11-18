import Foundation
import Testing
@testable import MultiSessionAIManager

/// The screen goes off, iOS suspends the app, and the SSH connection under the
/// forwards dies. Nothing travels on a connection that is not in use, so it still
/// read "connected" when the user came back and pressed Start. The start went out
/// on the dead connection and failed with a hint about the hop's key, and it
/// failed the same way every time until the app was closed.
@Suite(.serialized) @MainActor struct PortForwardDeadLinkTests {
    /// Holds whoever passes until it is released, and says when someone arrived.
    private actor Gate {
        private var released = false
        private var arrived = false
        private var held: [CheckedContinuation<Void, Never>] = []

        func pass() async {
            arrived = true
            guard !released else { return }
            await withCheckedContinuation { held.append($0) }
        }

        /// Whether someone arrived, waiting a moment for it. Never hangs.
        func someoneArrived() async -> Bool {
            for _ in 0..<300 where !arrived {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return arrived
        }

        /// Lets the one that has waited longest go on.
        func releaseFirst() {
            guard !held.isEmpty else { return }
            held.removeFirst().resume()
        }

        func release() {
            released = true
            held.forEach { $0.resume() }
            held = []
        }
    }

    private func eventually(_ what: String, _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "timed out waiting for: \(what)")
    }

    @MainActor private final class Rig {
        let transport = FakeSSHTransport()
        let session: PortForwardingSession
        /// The kind of forward this happened to: through a hop, started by a
        /// command on the first host. The app's own server starts it.
        let forward = SessionWebTunnel(label: "QAS Proxy", targetHost: "10.200.109.26", targetPort: 8443,
                                       hop: .init(username: "root", host: "10.200.107.247"))

        init() throws {
            let keys = KeyStore(backing: InMemoryKeychain())
            let host = Host(name: "Forge", address: "10.0.0.1", username: "alice",
                            keyID: try keys.generateEd25519(label: "forwards"), defaultWorkdir: "/home/alice")
            transport.defaultCommandResponse = SessionWebTunnelRemoteForwardCommands.readyMarker
            session = PortForwardingSession(
                host: host, keyStore: keys,
                knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: "msam.deadlink.\(UUID())")!),
                tunnels: [forward], transport: transport,
                keepAlive: .init(interval: .seconds(3600), probeTimeout: .seconds(1)))
        }

        /// The connection in use carries nothing more, the way a closed one fails;
        /// a connection made after this works. With a gate, the small round trip
        /// that checks the link hangs at it first, like a link that stopped answering.
        func theLinkDies(holdingTheCheckAt gate: Gate? = nil) {
            let transport = transport
            let dead = transport.connectAttemptCount
            transport.beforeCommand = { command in
                guard transport.connectAttemptCount == dead else { return }
                if command == "true" { await gate?.pass() }
                throw SSHTransportError.commandFailed("remote command failed: NIOSSHError.creatingChannelAfterClosure")
            }
        }

        var status: SessionWebTunnelStatus { session.model.status(for: forward.id) }

        var isListening: Bool {
            if case .listening = status { return true }
            return false
        }
    }

    @Test func aForwardStartsAlthoughTheLinkDiedWhileNothingWasRunning() async throws {
        let rig = try Rig()
        await rig.session.connection.connect()
        rig.theLinkDies()

        await rig.session.model.start(rig.forward)

        #expect(rig.isListening, "\(rig.status)")
        #expect(rig.transport.connectAttemptCount == 2, "The dead connection is replaced before the start goes out")
        await rig.session.shutdown()
    }

    @Test func stoppingAndStartingAForwardWhoseLinkDiedWorks() async throws {
        // What one does on coming back to a forward that no longer answers.
        let rig = try Rig()
        await rig.session.connection.connect()
        await rig.session.model.start(rig.forward)
        rig.theLinkDies()

        await rig.session.model.stop(rig.forward.id)
        await rig.session.model.start(rig.forward)

        #expect(rig.isListening, "\(rig.status)")
        await rig.session.shutdown()
    }

    @Test func aStartConnectsAHostThatIsNotConnectedYet() async throws {
        let rig = try Rig()

        await rig.session.model.start(rig.forward)

        #expect(rig.isListening, "\(rig.status)")
        #expect(rig.transport.connectAttemptCount == 1)
        await rig.session.shutdown()
    }

    @Test func aLinkThatAnswersIsNotReplacedForAStart() async throws {
        let rig = try Rig()
        await rig.session.connection.connect()

        await rig.session.model.start(rig.forward)

        #expect(rig.isListening, "\(rig.status)")
        #expect(rig.transport.connectAttemptCount == 1)
        await rig.session.shutdown()
    }

    @Test func aNewConnectionIsNotReplacedOnTheWordOfAnOldRoundTrip() async throws {
        // The keep-alive and the user's Start both look at a link that stopped
        // answering. The keep-alive gives up first and makes a new connection.
        // If the Start had sent its own round trip on the old connection, that
        // one would fail afterwards and take the new connection down, with
        // whatever had just been started on it.
        let rig = try Rig()
        await rig.session.connection.connect()
        await rig.session.model.start(rig.forward)
        let gate = Gate()
        rig.theLinkDies(holdingTheCheckAt: gate)

        let beat = Task { await rig.session.keepAlive() }
        #expect(await gate.someoneArrived(), "The keep-alive checks the link")
        let restart = Task { await rig.session.model.start(rig.forward) }
        try await Task.sleep(for: .milliseconds(150))
        await gate.releaseFirst()
        await eventually("the keep-alive's new connection") {
            rig.transport.connectAttemptCount == 2 && rig.session.connection.state == .connected
        }
        await gate.release()
        await beat.value
        await restart.value

        #expect(rig.transport.connectAttemptCount == 2)
        #expect(rig.isListening, "\(rig.status)")
        await rig.session.shutdown()
    }

    @Test func theBrowserOpensAlthoughTheLinkDied() async throws {
        let rig = try Rig()
        await rig.session.connection.connect()
        rig.theLinkDies()

        await rig.session.browse.start()

        #expect(rig.transport.connectAttemptCount == 2, "Pages must not be asked for over the dead connection")
        guard case .ready = rig.session.browse.state else {
            Issue.record("expected a running proxy, got \(rig.session.browse.state)")
            return
        }
        await rig.session.shutdown()
    }
}
