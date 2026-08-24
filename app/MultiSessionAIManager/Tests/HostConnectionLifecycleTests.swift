import Foundation
import Testing
@testable import MultiSessionAIManager

private actor HostConnectGate {
    private var nextID = 0
    private var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func suspend() async {
        nextID += 1
        let id = nextID
        let ready = waiters.filter { nextID >= $0.count }
        waiters.removeAll { nextID >= $0.count }
        ready.forEach { $0.continuation.resume() }
        await withCheckedContinuation { continuations[id] = $0 }
    }

    func waitForStarts(_ count: Int) async {
        if nextID >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }

    func release(_ id: Int) {
        continuations.removeValue(forKey: id)?.resume()
    }
}

@MainActor
@Suite struct HostConnectionLifecycleTests {
    @Test func olderConnectCannotOverwriteOrDisconnectNewerConnect() async throws {
        let transport = FakeSSHTransport()
        let gate = HostConnectGate()
        transport.beforeConnect = { await gate.suspend() }
        let connection = try makeConnection(transport: transport, function: #function)

        let first = Task { await connection.connect() }
        await gate.waitForStarts(1)
        let second = Task { await connection.connect() }
        await gate.waitForStarts(2)

        await gate.release(2)
        await second.value
        #expect(connection.state == .connected)
        await gate.release(1)
        await first.value

        #expect(connection.state == .connected)
        #expect(transport.isConnected)
        #expect(transport.disconnectCount == 1)
    }

    @Test func disconnectBeforeLateConnectKeepsConnectionIdle() async throws {
        let transport = FakeSSHTransport()
        let gate = HostConnectGate()
        transport.beforeConnect = { await gate.suspend() }
        let connection = try makeConnection(transport: transport, function: #function)

        let connecting = Task { await connection.connect() }
        await gate.waitForStarts(1)
        await connection.disconnect()
        await gate.release(1)
        await connecting.value

        #expect(connection.state == .idle)
        #expect(!transport.isConnected)
        #expect(transport.disconnectCount == 1)
    }

    @Test func herdrPTYIsUnavailableUntilSSHIsAuthenticated() async throws {
        let transport = FakeSSHTransport()
        let connection = try makeConnection(transport: transport, function: #function)

        await #expect(throws: HostConnection.PTYUnavailable.self) {
            _ = try await connection.openHerdrPTY(sessionName: nil, cols: 80, rows: 24) { _ in }
        }

        await connection.connect()
        #expect(connection.state == .connected)

        let channel = try await connection.openHerdrPTY(sessionName: nil, cols: 80, rows: 24) { _ in }
        #expect(channel.isOpen)
        #expect(transport.openedPTYs.last?.command.contains("exec herdr") == true)
    }

    private func makeConnection(
        transport: FakeSSHTransport,
        function: String
    ) throws -> HostConnection {
        let keyStore = KeyStore(backing: InMemoryKeychain())
        let keyID = try keyStore.generateEd25519(label: "host-lifecycle")
        let suite = "msam.host-lifecycle.\(function)"
        UserDefaults().removePersistentDomain(forName: suite)
        return HostConnection(
            host: Host(
                name: "Private host",
                address: "10.0.0.8",
                username: "owner",
                keyID: keyID,
                defaultWorkdir: "/srv"
            ),
            keyStore: keyStore,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: suite)!),
            transport: transport
        )
    }
}
