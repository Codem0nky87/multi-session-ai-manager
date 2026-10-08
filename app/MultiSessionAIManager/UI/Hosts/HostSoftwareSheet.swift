import SwiftUI

/// The AI-agent CLIs panel, shared by the merged AI Agents sheet and the
/// standalone sheet (kept for existing entry points and UITests).
@MainActor
struct HostSoftwarePanel: View {
    @State private var model: HostSoftwareManager
    private let connection: HostConnection
    @Environment(\.dismiss) private var dismiss

    init(connection: HostConnection) {
        self.connection = connection
        _model = State(initialValue: HostSoftwareManager(connection: connection))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                Text("Install AI command-line tools on \(connection.host.name). Existing installations are verified and kept. Sign in from a host terminal after installation.")
                    .font(Theme.body(14)).foregroundStyle(Theme.textSecondary)
                ForEach([AgentToolID.codex, .claude, .antigravity], id: \.self) { tool in
                    agentCard(tool)
                }
                if let step = model.step { ProgressView(step).tint(Theme.accent) }
                if let error = model.error { Text(error).foregroundStyle(Theme.danger).textSelection(.enabled) }
                if let notice = model.notice { Text(notice).foregroundStyle(Theme.success) }
            }
            .padding(Theme.Space.md)
        }
        .task(id: connection.state) { if connection.state == .connected { await model.refresh() } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(model.busy || connection.state != .connected)
                    .accessibilityLabel("Check installed AI tools")
            }
        }
        .accessibilityIdentifier("host.software.panel")
    }

    private func agentCard(_ tool: AgentToolID) -> some View {
        let status = model.agents.first { $0.id == tool }
        return GlassCard {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(AgentToolRegistry.definition(for: tool).displayName + " CLI").font(Theme.body(17))
                    Text(status.map { $0.installed ? "Installed · \($0.version ?? "")" : ($0.error ?? "Not installed") } ?? "Checking…")
                        .font(Theme.body(13)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if status?.installed == true {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.success)
                } else {
                    Button("Install") { Task { await model.install(tool) } }
                        .disabled(model.busy || status == nil || status?.path != nil)
                        .accessibilityIdentifier("host.software.install.\(tool.rawValue)")
                }
            }
        }
    }
}

/// Standalone entry point retained for callers that only want the CLIs view.
@MainActor
struct HostSoftwareSheet: View {
    @State private var connection: HostConnection
    @State private var lifecycle: HerdrSSHConnectionLifecycle
    @Environment(\.dismiss) private var dismiss

    init(host: Host, keyStore: KeyStore, knownHosts: KnownHostsStore) {
        let connection = HostConnection(host: host, keyStore: keyStore, knownHosts: knownHosts)
        _connection = State(initialValue: connection)
        _lifecycle = State(initialValue: HerdrSSHConnectionLifecycle(
            connect: { await connection.connect() }, disconnect: { await connection.disconnect() }))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                if connection.state == .connected {
                    HostSoftwarePanel(connection: connection)
                } else {
                    VStack(spacing: Theme.Space.md) {
                        switch connection.state {
                        case .failed(let reason):
                            Text(reason).foregroundStyle(Theme.danger)
                            Button("Retry") { lifecycle.connect() }
                        case .hostKeyChanged(let fingerprint):
                            Text("SSH host key changed. Verify this fingerprint before reconnecting: \(fingerprint)")
                                .foregroundStyle(Theme.warning).textSelection(.enabled)
                        default:
                            ProgressView("Connecting to host…").tint(Theme.accent)
                        }
                    }
                    .padding(Theme.Space.lg)
                }
            }
            .navigationTitle("AI Agent CLIs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { lifecycle.connect() }
        .onDisappear { Task { await lifecycle.close() } }
    }
}
