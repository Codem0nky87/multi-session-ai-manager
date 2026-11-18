import Foundation
import Observation
import SwiftUI
import UIKit

/// One host's live port-forwarding state, owned by the app rather than by the
/// port-management sheet. Tunnels the user started keep running after the
/// sheet closes — each is stopped only explicitly (its Stop button, or Stop
/// all), when the host session is removed, or when the app terminates.
@MainActor
@Observable
final class PortForwardingSession {
    let host: Host
    let connection: HostConnection
    let model: SessionWebTunnelModel
    /// Browsing through this host, over the same SSH connection as its forwards.
    let browse: HostBrowseModel
    var tunnels: [SessionWebTunnel]
    /// Hop passwords live here so a running tunnel can be restarted after the
    /// sheet closes; they are never persisted.
    var hopPasswords: [UUID: String] = [:]
    /// True while the user has left this session running on purpose.
    var isManaged = false

    /// How the SSH connection under the forwards is kept alive.
    struct KeepAlive: Sendable {
        /// 30 s stays inside common NAT, firewall and VPN idle-eviction windows.
        var interval: Duration = .seconds(30)
        /// How long a probe may hang before the link counts as dead. A half-open
        /// connection never answers.
        var probeTimeout: Duration = .seconds(10)
    }

    @ObservationIgnored private let keepAlivePolicy: KeepAlive
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?
    @ObservationIgnored private var foregroundTask: Task<Void, Never>?
    /// The check of the link that is running, if one is. There is one at a time:
    /// two that each replaced a dead connection would take each other's away.
    @ObservationIgnored private var linkCheck: Task<Void, Never>?

    /// Lets the browser, which is made before the session is complete, reach it.
    @MainActor private final class Owner {
        weak var session: PortForwardingSession?
    }

    /// - Parameters:
    ///   - model: the forwards' model; by default one that forwards over this
    ///     session's own SSH connection.
    ///   - transport: the SSH transport of that connection.
    init(host: Host, keyStore: KeyStore, knownHosts: KnownHostsStore, tunnels: [SessionWebTunnel],
         model: SessionWebTunnelModel? = nil, transport: SSHTransport = NIOSSHTransport(),
         keepAlive: KeepAlive = KeepAlive()) {
        self.host = host
        self.tunnels = tunnels
        let connection = HostConnection(host: host, keyStore: keyStore, knownHosts: knownHosts, transport: transport)
        self.connection = connection
        self.model = model ?? SessionWebTunnelModel(server: connection.makeSessionWebTunnelServer())
        let owner = Owner()
        self.browse = HostBrowseModel(server: connection.makeHostBrowseProxyServer()) { [connection] in
            await owner.session?.ensureLink()
            switch connection.state {
            case .connected:
                return nil
            case .failed(let message):
                return "Could not connect to \(host.name): \(message)"
            case .hostKeyChanged:
                // Never settled from here: the host's own tab shows the key and asks.
                return "\(host.name) presented a different host key. Open its tab to review the key first."
            case .idle, .connecting:
                return "Could not connect to \(host.name)."
            }
        }
        self.keepAlivePolicy = keepAlive
        owner.session = self
        self.model.onConnectionProblem = { [weak self] in
            Task { await self?.keepAlive() }
        }
        self.model.beforeStart = { [weak self] in
            await self?.ensureLink()
        }
        startKeepAlive()
    }

    deinit {
        keepAliveTask?.cancel()
        foregroundTask?.cancel()
    }

    /// Keeps the SSH connection under running forwards alive, and replaces it when
    /// it has died.
    ///
    /// An idle forward sends nothing, so a NAT, firewall or VPN in the path drops
    /// the flow without a word. The listeners on this device would then accept
    /// connections that go nowhere, and the only cure was to stop and restart
    /// every forward. A small round trip refreshes the flow. If it gets no answer
    /// the connection is made again underneath the listeners, which keep their
    /// ports, so the next connection through a forward simply works.
    ///
    /// Nothing is sent for a host with no forward running. iOS suspends the app in
    /// the background, where nothing can be kept alive; the check runs at once on
    /// return instead.
    func keepAlive() async {
        // A check that is already running will do for this beat.
        guard needsItsConnection, linkCheck == nil else { return }
        await checkLink { [weak self] in self?.needsItsConnection ?? false }
    }

    /// Makes sure the connection answers, for whoever is about to start
    /// something on it: a forward, or the browser.
    ///
    /// The state alone cannot tell. Nothing is sent for a host with nothing
    /// running, so a connection that died meanwhile (the screen went off, iOS
    /// suspended the app) still reads "connected". A start then went out on the
    /// dead connection and failed, and since a failed forward is not running,
    /// nothing ever checked: every start failed until the app was closed.
    func ensureLink() async {
        while let running = linkCheck { await running.value }
        await checkLink { true }
        // A connect begun elsewhere (the sheet's Retry) is not repeated here,
        // but what is started next needs its outcome.
        let deadline = ContinuousClock.now + .seconds(30)
        while connection.state == .connecting, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// One round trip on the connection, and a new connection if it gets no answer.
    /// - Parameter stillWanted: asked after a failed round trip, which can take
    ///   seconds: whether anything still needs the connection.
    private func checkLink(reconnectIf stillWanted: @escaping @MainActor () -> Bool) async {
        let check = Task { [weak self] in
            guard let self else { return }
            defer { linkCheck = nil }
            switch connection.state {
            case .connecting, .hostKeyChanged:
                // Already being connected, or waiting for the user to look at a
                // changed key. Neither is this check's to settle.
                return
            case .idle, .connected, .failed:
                break
            }
            if await connection.verifyAlive(timeout: keepAlivePolicy.probeTimeout) { return }
            guard stillWanted() else { return }
            await connection.connect()
            if connection.state == .connected {
                model.clearConnectionProblems()
            }
        }
        linkCheck = check
        await check.value
    }

    /// A running forward or an open browser: either goes dead with the connection.
    private var needsItsConnection: Bool {
        model.runningCount > 0 || browse.isActive
    }

    private func startKeepAlive() {
        let interval = keepAlivePolicy.interval
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self else { return }
                await self.keepAlive()
            }
        }
        foregroundTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
                guard let self else { return }
                await self.keepAlive()
            }
        }
    }

    /// Number of tunnels currently serving traffic (connecting counts too, so
    /// the monitor indicator never shows zero for a tunnel mid-start).
    var activeTunnelCount: Int { model.runningCount }

    func connect() {
        guard case .idle = connection.state else { return }
        Task { await connection.connect() }
    }

    func shutdown() async {
        keepAliveTask?.cancel()
        foregroundTask?.cancel()
        await model.stopAll()
        await browse.stop()
        await connection.disconnect()
    }
}

/// App-level registry of port-forwarding sessions, keyed by host id. Injected
/// through the SwiftUI environment from the app root so the metrics bar can
/// read live tunnel counts and the host editor can open/manage a session
/// without owning its lifetime.
@MainActor
@Observable
final class PortForwardingManager {
    private(set) var sessions: [UUID: PortForwardingSession] = [:]
    private let keyStore: KeyStore
    private let knownHosts: KnownHostsStore

    init(keyStore: KeyStore, knownHosts: KnownHostsStore) {
        self.keyStore = keyStore
        self.knownHosts = knownHosts
    }

    /// Total running tunnels across every host — the monitor indicator.
    var activeTunnelCount: Int {
        sessions.values.reduce(0) { $0 + $1.activeTunnelCount }
    }

    func activeTunnelCount(for hostID: UUID) -> Int {
        sessions[hostID]?.activeTunnelCount ?? 0
    }

    /// Returns the live session for this host, creating (and persisting) one
    /// from the saved tunnel definitions when first opened.
    func session(for host: Host) -> PortForwardingSession {
        if let existing = sessions[host.id] { return existing }
        let session = PortForwardingSession(
            host: host, keyStore: keyStore, knownHosts: knownHosts,
            tunnels: Self.loadTunnels(hostID: host.id)
        )
        sessions[host.id] = session
        return session
    }

    func persist(_ session: PortForwardingSession) {
        Self.saveTunnels(session.tunnels, hostID: session.host.id)
    }

    /// Explicitly retires one host's session: stops its tunnels and disconnects.
    func remove(hostID: UUID) async {
        guard let session = sessions.removeValue(forKey: hostID) else { return }
        await session.shutdown()
    }

    func stopAll() async {
        for session in sessions.values { await session.shutdown() }
        sessions.removeAll()
    }

    // MARK: - Persistence (definitions only; a session must be re-opened to run)

    static func loadTunnels(hostID: UUID) -> [SessionWebTunnel] {
        let key = "herdr.ssh-web-tunnels.\(hostID.uuidString.lowercased())"
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SessionWebTunnel].self, from: data) else {
            return []
        }
        return decoded.filter { $0.validationError == nil }
    }

    static func saveTunnels(_ tunnels: [SessionWebTunnel], hostID: UUID) {
        let key = "herdr.ssh-web-tunnels.\(hostID.uuidString.lowercased())"
        guard let data = try? JSONEncoder().encode(tunnels) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

// MARK: - Connection lifecycle guard

/// Serialises connect/disconnect for a host connection so a late completion
/// from a superseded connect cannot tear down a newer connection, and closing
/// a sheet stops the tunnel before dropping the SSH session.
@MainActor
final class HerdrSSHConnectionLifecycle {
    private let connectOperation: () async -> Void
    private let disconnectOperation: () async -> Void
    private var connectionTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(
        connect: @escaping () async -> Void,
        disconnect: @escaping () async -> Void
    ) {
        connectOperation = connect
        disconnectOperation = disconnect
    }

    deinit {
        connectionTask?.cancel()
    }

    func connect() {
        perform(connectOperation)
    }

    func perform(_ operation: @escaping () async -> Void) {
        generation &+= 1
        let operationGeneration = generation
        connectionTask?.cancel()
        let disconnectOperation = self.disconnectOperation
        connectionTask = Task { [weak self] in
            await operation()
            guard let self else {
                await disconnectOperation()
                return
            }
            guard generation == operationGeneration else { return }
            connectionTask = nil
        }
    }

    func close(after stop: () async -> Void = {}) async {
        generation &+= 1
        connectionTask?.cancel()
        connectionTask = nil
        await stop()
        await disconnectOperation()
    }
}

// MARK: - Environment

private struct PortForwardingManagerKey: EnvironmentKey {
    // Optional so the nonisolated EnvironmentKey default needs no MainActor
    // hop; the app root injects the real manager with `portForwarding(_:)`.
    static let defaultValue: PortForwardingManager? = nil
}

extension View {
    /// Hands the app's port-forwarding manager to everything below this view.
    ///
    /// This, and not `.environment(manager)`, is what the readers see: they look
    /// the manager up by key (`@Environment(\.portForwardingManager)`), and an
    /// object placed in the environment by type is invisible to a key lookup. The
    /// app once used the by-type form. Every reader then got nil, the host editor
    /// built a throwaway session each time its sheet opened, and closing the sheet
    /// took the SSH connection with it while the listeners kept their ports.
    func portForwarding(_ manager: PortForwardingManager) -> some View {
        environment(\.portForwardingManager, manager)
    }
}

extension EnvironmentValues {
    var portForwardingManager: PortForwardingManager? {
        get { self[PortForwardingManagerKey.self] }
        set { self[PortForwardingManagerKey.self] = newValue }
    }
}
