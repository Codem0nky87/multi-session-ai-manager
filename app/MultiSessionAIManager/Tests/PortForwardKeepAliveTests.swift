import Foundation
import Testing
import UIKit
@testable import MultiSessionAIManager

/// An idle forward used to die quietly: nothing travelled on its SSH connection, a
/// NAT or firewall dropped the flow, and the listeners kept accepting connections
/// that went nowhere until the user stopped and restarted every forward.
@Suite(.serialized) @MainActor struct PortForwardKeepAliveTests {
    private final class Listener: SessionWebTunnelListener, @unchecked Sendable {
        let localPort: Int
        private let lock = NSLock()
        private var stops = 0
        init(localPort: Int) { self.localPort = localPort }
        var stopCount: Int { lock.withLock { stops } }
        func stop() async { lock.withLock { stops += 1 } }
    }

    private final class Server: SessionWebTunnelServing, @unchecked Sendable {
        private let lock = NSLock()
        private var port = 50_000
        private var made: [Listener] = []
        private var callbacks: [@Sendable (String) -> Void] = []
        func start(tunnel: SessionWebTunnel, hopPassword: String?,
                   onConnectionError: @escaping @Sendable (String) -> Void) async throws -> any SessionWebTunnelListener {
            lock.withLock {
                port += 1
                let listener = Listener(localPort: port)
                made.append(listener)
                callbacks.append(onConnectionError)
                return listener
            }
        }
        var listeners: [Listener] { lock.withLock { made } }
        func failAConnection(_ message: String) { lock.withLock { callbacks }.last?(message) }
    }

    @MainActor private final class Rig {
        let transport = FakeSSHTransport()
        let server = Server()
        let knownHosts = KnownHostsStore(defaults: UserDefaults(suiteName: "msam.keepalive.\(UUID())")!)
        let session: PortForwardingSession
        let forward = SessionWebTunnel(label: "RDP", targetHost: "127.0.0.1", targetPort: 3391, localPort: 13389)

        init(interval: Duration = .seconds(3600)) throws {
            let keys = KeyStore(backing: InMemoryKeychain())
            let host = Host(name: "Forge", address: "10.0.0.1", username: "alice",
                            keyID: try keys.generateEd25519(label: "forwards"), defaultWorkdir: "/home/alice")
            session = PortForwardingSession(
                host: host, keyStore: keys, knownHosts: knownHosts, tunnels: [forward],
                model: SessionWebTunnelModel(server: server), transport: transport,
                keepAlive: .init(interval: interval, probeTimeout: .seconds(1)))
        }

        /// How many keep-alive round trips the host has seen.
        var pings: Int { transport.commandsRun.filter { $0 == "true" }.count }

        func connectAndStart() async {
            await session.connection.connect()
            await session.model.start(forward)
        }
    }

    private func eventually(_ what: String, timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "timed out waiting for: \(what)")
    }

    @Test func anIdleForwardIsKeptAliveWithASmallRoundTrip() async throws {
        let rig = try Rig()
        await rig.connectAndStart()

        await rig.session.keepAlive()

        #expect(rig.pings == 1)
        #expect(rig.transport.connectAttemptCount == 1, "A healthy link is not reconnected")
        await rig.session.shutdown()
    }

    @Test func aHostWithNothingRunningIsLeftAlone() async throws {
        let rig = try Rig()
        await rig.session.connection.connect()
        let commands = rig.transport.commandsRun.count

        await rig.session.keepAlive()

        #expect(rig.transport.commandsRun.count == commands)
        #expect(rig.transport.connectAttemptCount == 1)
        await rig.session.shutdown()
    }

    @Test func aDeadLinkIsReconnectedWithoutStoppingTheForward() async throws {
        let rig = try Rig()
        await rig.connectAndStart()
        rig.transport.commandError = SSHTransportError.notConnected   // the link no longer answers

        await rig.session.keepAlive()

        #expect(rig.transport.connectAttemptCount == 2)
        #expect(rig.session.connection.state == .connected)
        #expect(rig.session.model.status(for: rig.forward.id) == .listening(localPort: 50_001),
                "The listener and its port stay as they were")
        #expect(rig.server.listeners.map(\.stopCount) == [0])
        await rig.session.shutdown()
    }

    @Test func aProblemOnAForwardBringsTheCheckForward() async throws {
        // No waiting for the next beat: a connection that just failed is the best
        // sign that the link is gone.
        let rig = try Rig()
        await rig.connectAndStart()
        rig.transport.commandError = SSHTransportError.notConnected

        rig.server.failAConnection("SSH host could not reach 127.0.0.1:3391. notConnected")

        await eventually("the link is reconnected") { rig.transport.connectAttemptCount == 2 }
        rig.transport.commandError = nil
        await eventually("the old problem is cleared") {
            rig.session.model.connectionProblem(for: rig.forward.id) == nil
        }
        await rig.session.shutdown()
    }

    @Test func aChangedHostKeyIsLeftForTheUser() async throws {
        let rig = try Rig()
        rig.knownHosts.pin(host: rig.session.host.knownHostsKey, fingerprint: "SOME-OTHER-KEY")
        await rig.connectAndStart()
        guard case .hostKeyChanged = rig.session.connection.state else {
            Issue.record("expected a changed host key, got \(rig.session.connection.state)")
            return
        }
        let attempts = rig.transport.connectAttemptCount

        await rig.session.keepAlive()
        await rig.session.keepAlive()

        #expect(rig.transport.connectAttemptCount == attempts)
        await rig.session.shutdown()
    }

    @Test func theKeepAliveRunsByItselfWhileAForwardRunsAndStopsWithIt() async throws {
        let rig = try Rig(interval: .milliseconds(30))
        await rig.connectAndStart()

        await eventually("several beats") { rig.pings >= 3 }

        await rig.session.model.stopAll()
        try await Task.sleep(for: .milliseconds(80))
        let afterStop = rig.pings
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.pings == afterStop, "Nothing is sent for a host with no forward running")
        await rig.session.shutdown()
    }

    @Test func comingBackToTheAppChecksTheLinkAtOnce() async throws {
        // iOS suspends the app in the background, so the link is usually gone on
        // return; the next beat could be half a minute away.
        let rig = try Rig()
        await rig.connectAndStart()
        rig.transport.commandError = SSHTransportError.notConnected

        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)

        await eventually("the link is reconnected") { rig.transport.connectAttemptCount == 2 }
        await rig.session.shutdown()
    }

    @Test func aStoppedSessionSendsNothingMore() async throws {
        let rig = try Rig(interval: .milliseconds(30))
        await rig.connectAndStart()
        await eventually("a beat") { rig.pings >= 1 }

        await rig.session.shutdown()

        let after = rig.pings
        let attempts = rig.transport.connectAttemptCount
        try await Task.sleep(for: .milliseconds(200))
        #expect(rig.pings == after)
        #expect(rig.transport.connectAttemptCount == attempts)
    }
}
