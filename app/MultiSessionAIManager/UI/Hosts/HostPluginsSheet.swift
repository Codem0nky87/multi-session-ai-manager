import SwiftUI

/// Owns the SSH connection when plugin management is opened from a saved host.
/// The setup sheet can still reuse its existing connection with the inner manager.
@MainActor
struct HostPluginsSheet: View {
    @State private var connection: HostConnection
    @State private var manager: HerdrPluginManagerModel
    @State private var lifecycle: HerdrSSHConnectionLifecycle
    @Environment(\.dismiss) private var dismiss

    init(host: Host, keyStore: KeyStore, knownHosts: KnownHostsStore) {
        let connection = HostConnection(host: host, keyStore: keyStore, knownHosts: knownHosts)
        _connection = State(initialValue: connection)
        _manager = State(initialValue: HerdrPluginManagerModel(connection: connection))
        _lifecycle = State(initialValue: HerdrSSHConnectionLifecycle(
            connect: { await connection.connect() },
            disconnect: { await connection.disconnect() }
        ))
    }

    var body: some View {
        ZStack {
            if connection.state == .connected {
                HerdrPluginManagerSheet(model: manager, hostName: connection.host.name)
            } else {
                NavigationStack {
                    ZStack {
                        AppBackground()
                        VStack(spacing: Theme.Space.md) {
                            connectionStatus
                        }
                        .padding(Theme.Space.lg)
                    }
                    .navigationTitle("Plugins on \(connection.host.name)")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarBackground(Theme.bg, for: .navigationBar)
                    .toolbarBackground(.visible, for: .navigationBar)
                    .toolbarColorScheme(.dark, for: .navigationBar)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }
                                .foregroundStyle(Theme.accent)
                                .accessibilityIdentifier("host.plugins.close")
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(manager.isBusy)
        .task {
            if connection.state == .idle { lifecycle.connect() }
        }
        .onDisappear {
            Task { await lifecycle.close() }
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch connection.state {
        case .idle, .connecting:
            ProgressView("Connecting to SSH host…")
                .tint(Theme.accent)
        case .failed(let message):
            Text("SSH connection failed")
                .font(Theme.title())
            Text(message)
                .font(Theme.body(13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Retry") { lifecycle.connect() }
                .tint(Theme.accent)
                .accessibilityIdentifier("host.plugins.retry")
        case .hostKeyChanged(let fingerprint):
            Text("SSH host key changed")
                .font(Theme.title())
            Text("Verify the changed fingerprint before reconnecting: \(fingerprint)")
                .font(Theme.body(13))
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
        case .connected:
            EmptyView()
        }
    }
}
