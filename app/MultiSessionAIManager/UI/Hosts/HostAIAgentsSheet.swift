import SwiftUI

/// One place to manage the AI agents on a host: the CLIs panel and the
/// rolling-update panel share a single SSH connection behind tabs. Replaces
/// the two separate cards (and two separate connections) the editor used to
/// offer.
@MainActor
struct HostAIAgentsSheet: View {
    enum Tab: String, CaseIterable {
        case clis = "Agent CLIs"
        case updates = "Rolling updates"
    }

    @State private var connection: HostConnection
    @State private var lifecycle: HerdrSSHConnectionLifecycle
    @State private var tab: Tab = .clis
    @State private var updatesPanel: HostAgentUpdatesPanel?
    @Environment(\.dismiss) private var dismiss

    init(
        host: Host,
        keyStore: KeyStore,
        knownHosts: KnownHostsStore,
        onSetupChanged: @escaping (HostAgentUpdaterSetup, HostGatekeeperPolicy) -> Void = { _, _ in }
    ) {
        let connection = HostConnection(host: host, keyStore: keyStore, knownHosts: knownHosts)
        _connection = State(initialValue: connection)
        _lifecycle = State(initialValue: HerdrSSHConnectionLifecycle(
            connect: { await connection.connect() },
            disconnect: { await connection.disconnect() }
        ))
        _updatesPanel = State(initialValue: HostAgentUpdatesPanel(
            host: host, connection: connection, onSetupChanged: onSetupChanged
        ))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                if connection.state == .connected {
                    VStack(spacing: 0) {
                        Picker("Section", selection: $tab) {
                            ForEach(Tab.allCases, id: \.self) { value in
                                Text(value.rawValue).tag(value)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, Theme.Space.md)
                        .padding(.vertical, Theme.Space.sm)
                        .accessibilityIdentifier("host.ai-agents.tabs")

                        switch tab {
                        case .clis:
                            HostSoftwarePanel(connection: connection)
                        case .updates:
                            if let updatesPanel {
                                updatesPanel
                            }
                        }
                    }
                } else {
                    connectionStatus
                }
            }
            .navigationTitle("AI Agents on \(connection.host.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { close() }
                        .foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("host.ai-agents.close")
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if case .idle = connection.state { lifecycle.connect() }
        }
        .onDisappear {
            Task { await lifecycle.close() }
        }
    }

    @ViewBuilder
    private var connectionStatus: some View {
        VStack(spacing: Theme.Space.md) {
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
        .padding(Theme.Space.lg)
    }

    private func close() {
        Task {
            await lifecycle.close()
            dismiss()
        }
    }
}
