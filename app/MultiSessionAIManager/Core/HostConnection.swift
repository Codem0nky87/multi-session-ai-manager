import Foundation
import NIOConcurrencyHelpers
import Observation

/// Owns one authenticated SSH connection for host setup and private web tunnels.
/// Herdr terminal/session state travels through the Herdr REST/WebSocket clients;
/// this object deliberately has no terminal-session or workspace responsibilities.
@MainActor
@Observable
final class HostConnection {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(message: String)
        case hostKeyChanged(fingerprint: String)
    }

    let host: Host
    let knownHosts: KnownHostsStore
    private let keyStore: KeyStore
    private let service: SSHService
    private(set) var state: State = .idle
    private var operationGeneration: UInt64 = 0

    init(
        host: Host,
        keyStore: KeyStore,
        knownHosts: KnownHostsStore,
        transport: SSHTransport = NIOSSHTransport()
    ) {
        self.host = host
        self.keyStore = keyStore
        self.knownHosts = knownHosts
        self.service = SSHService(host: host, transport: transport, knownHosts: knownHosts)
    }

    func connect() async {
        operationGeneration &+= 1
        let connectGeneration = operationGeneration
        let replacingExistingConnection = state != .idle
        state = .connecting

        if replacingExistingConnection {
            await service.disconnect()
            guard operationGeneration == connectGeneration else { return }
            guard !Task.isCancelled else {
                state = .idle
                return
            }
        }

        let mismatchBox = NIOLockedValueBox<String?>(nil)
        do {
            let seed = try keyStore.ed25519Seed(id: host.keyID)
            try await service.connect(key: SSHKeyMaterial(ed25519Seed: seed)) { fingerprint, verdict in
                switch verdict {
                case .trustedNew, .match:
                    return true
                case .mismatch:
                    mismatchBox.withLockedValue { $0 = fingerprint }
                    return false
                }
            }
            try Task.checkCancellation()
            guard operationGeneration == connectGeneration else { return }
            state = .connected
        } catch {
            guard operationGeneration == connectGeneration else { return }
            if error is CancellationError || Task.isCancelled {
                await service.disconnect()
                guard operationGeneration == connectGeneration else { return }
                state = .idle
            } else if let fingerprint = mismatchBox.withLockedValue({ $0 }) {
                state = .hostKeyChanged(fingerprint: fingerprint)
            } else {
                state = .failed(message: SSHFailure.classify(
                    message: String(describing: error)
                ).userMessage)
            }
        }
    }

    func trustChangedKeyAndReconnect() async {
        guard case .hostKeyChanged(let fingerprint) = state else { return }
        knownHosts.pin(host: host.knownHostsKey, fingerprint: fingerprint)
        await connect()
    }

    func makeSessionWebTunnelServer() -> any SessionWebTunnelServing {
        NIOSessionWebTunnelServer(service: service)
    }

    struct PTYUnavailable: Error, Equatable {}

    /// Runs bounded, non-interactive commands on this host — used by
    /// `HerdrInstaller`. Available only while this exact connection is
    /// authenticated, and it hands back the same host-key-verified service the
    /// PTY uses rather than opening a parallel connection. Returns nil rather
    /// than throwing so callers can gate UI affordances on it.
    var provisioningCommandRunner: SSHService? {
        state == .connected ? service : nil
    }

    /// Open an interactive PTY running Herdr on this host. Available only while
    /// this exact connection is authenticated, mirroring the provisioner's rule:
    /// it reuses the host-key-verified service and never opens a parallel session.
    func openHerdrPTY(
        sessionName: String?,
        cols: Int,
        rows: Int,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> PTYChannel {
        guard state == .connected else { throw PTYUnavailable() }
        return try await service.openPTY(
            command: HerdrLaunchCommand.launch(sessionName: sessionName),
            cols: cols,
            rows: rows,
            onOutput: onOutput
        )
    }

    func disconnect() async {
        operationGeneration &+= 1
        state = .idle
        await service.disconnect()
    }
}
