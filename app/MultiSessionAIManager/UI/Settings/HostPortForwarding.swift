import SwiftUI

// Moved verbatim out of the old Herdr gateway settings section: port
// forwarding and the SSH connection lifecycle it shares with Host Setup
// outlive that section, which has since been retired.

@MainActor
struct HerdrPortForwardingSheet: View {
    @State private var connection: HostConnection
    @State private var lifecycle: HerdrSSHConnectionLifecycle
    @State private var tunnels: [SessionWebTunnel]
    @State private var showingChangedKeyConfirmation = false
    private let hostID: UUID
    @Environment(\.dismiss) private var dismiss

    init(host: Host, keyStore: KeyStore, knownHosts: KnownHostsStore) {
        let connection = HostConnection(
            host: host,
            keyStore: keyStore,
            knownHosts: knownHosts
        )
        hostID = host.id
        _connection = State(initialValue: connection)
        _lifecycle = State(initialValue: HerdrSSHConnectionLifecycle(
            connect: { await connection.connect() },
            disconnect: { await connection.disconnect() }
        ))
        _tunnels = State(initialValue: Self.load(hostID: host.id))
    }

    var body: some View {
        ZStack {
            switch connection.state {
            case .connected:
                SessionWebTunnelSheet(
                    initialTunnels: tunnels,
                    connection: connection,
                    onClose: { await lifecycle.close() }
                ) { updated in
                    tunnels = updated
                    Self.save(updated, hostID: hostID)
                }
            case .idle, .connecting:
                statusScreen(
                    title: "Connecting to SSH host",
                    detail: "Port-forward definitions remain on this iPad and start only over the authenticated host connection.",
                    retry: nil
                )
            case .failed(let message):
                statusScreen(title: "SSH connection failed", detail: message) {
                    lifecycle.connect()
                }
            case .hostKeyChanged(let fingerprint):
                hostKeyChangedScreen(fingerprint: fingerprint)
            }
        }
        .task {
            if case .idle = connection.state {
                lifecycle.connect()
            }
        }
        .interactiveDismissDisabled()
        .alert("Trust changed SSH host key?", isPresented: $showingChangedKeyConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Trust new key & reconnect", role: .destructive) {
                lifecycle.perform {
                    await connection.trustChangedKeyAndReconnect()
                }
            }
        } message: {
            Text("Only trust this fingerprint if the host key change was expected. An unexpected change can mean the SSH connection is being intercepted.")
        }
    }

    private func statusScreen(
        title: String,
        detail: String,
        retry: (() -> Void)?
    ) -> some View {
        NavigationStack {
            VStack(spacing: 14) {
                if case .connecting = connection.state {
                    ProgressView()
                } else {
                    Image(systemName: "network")
                        .font(.largeTitle)
                        .foregroundStyle(HerdrTheme.accent)
                }
                Text(title).font(.headline)
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                if let retry {
                    Button("Retry", action: retry)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(24)
            .navigationTitle("SSH Web Tunnels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        Task {
                            await lifecycle.close()
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private func hostKeyChangedScreen(fingerprint: String) -> some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(systemName: "lock.trianglebadge.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(.red)
                Text("SSH host key changed").font(.headline)
                Text("Presented fingerprint")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text(fingerprint)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                Button("Review and trust new key", role: .destructive) {
                    showingChangedKeyConfirmation = true
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(24)
            .navigationTitle("SSH Web Tunnels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        Task {
                            await lifecycle.close()
                            dismiss()
                        }
                    }
                }
            }
        }
    }

    private static func load(hostID: UUID) -> [SessionWebTunnel] {
        guard let data = UserDefaults.standard.data(forKey: key(hostID)),
              let decoded = try? JSONDecoder().decode([SessionWebTunnel].self, from: data) else {
            return []
        }
        return decoded.filter { $0.validationError == nil }
    }

    private static func save(_ tunnels: [SessionWebTunnel], hostID: UUID) {
        guard let data = try? JSONEncoder().encode(tunnels) else { return }
        UserDefaults.standard.set(data, forKey: key(hostID))
    }

    private static func key(_ hostID: UUID) -> String {
        "herdr.ssh-web-tunnels.\(hostID.uuidString.lowercased())"
    }
}

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
