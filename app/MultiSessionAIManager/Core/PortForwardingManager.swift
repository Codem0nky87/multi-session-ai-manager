import Foundation
import Observation
import SwiftUI

/// One host's live port-forwarding state, owned by the app rather than by the
/// port-management sheet. A tunnel the user started keeps running after the
/// sheet closes — it is stopped only explicitly (Stop Tunnel / Stop all),
/// when the host session is removed, or when the app terminates.
@MainActor
@Observable
final class PortForwardingSession {
    let host: Host
    let connection: HostConnection
    let model: SessionWebTunnelModel
    var tunnels: [SessionWebTunnel]
    /// Hop passwords live here so a running tunnel can be restarted after the
    /// sheet closes; they are never persisted.
    var hopPasswords: [UUID: String] = [:]
    /// True while the user has left this session running on purpose.
    var isManaged = false

    init(host: Host, keyStore: KeyStore, knownHosts: KnownHostsStore, tunnels: [SessionWebTunnel]) {
        self.host = host
        self.tunnels = tunnels
        let connection = HostConnection(host: host, keyStore: keyStore, knownHosts: knownHosts)
        self.connection = connection
        self.model = SessionWebTunnelModel(server: connection.makeSessionWebTunnelServer())
    }

    /// Number of tunnels currently serving traffic (connecting counts too, so
    /// the monitor indicator never shows zero for a tunnel mid-start).
    var activeTunnelCount: Int {
        switch model.status {
        case .connecting, .listening, .open: return 1
        case .idle, .failed: return 0
        }
    }

    func connect() {
        guard case .idle = connection.state else { return }
        Task { await connection.connect() }
    }

    func stopTunnel() async {
        await model.stop()
    }

    func shutdown() async {
        await model.stop()
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

    /// Explicitly retires one host's session: stops its tunnel and disconnects.
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
    // hop; the app root always injects the real manager.
    static let defaultValue: PortForwardingManager? = nil
}

extension EnvironmentValues {
    var portForwardingManager: PortForwardingManager? {
        get { self[PortForwardingManagerKey.self] }
        set { self[PortForwardingManagerKey.self] = newValue }
    }
}
