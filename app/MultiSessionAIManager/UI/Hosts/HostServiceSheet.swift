import SwiftUI

@MainActor
struct HostServiceSheet: View {
    let host: Host
    let keyStore: KeyStore
    let knownHosts: KnownHostsStore
    private let onSetupChanged: (HostAgentUpdaterSetup, HostGatekeeperPolicy) -> Void
    @State private var connection: HostConnection
    @State private var manager: HostServiceManager
    @State private var task: Task<Void, Never>?
    @State private var showAgents = false
    @State private var confirmRemove = false
    @Environment(\.dismiss) private var dismiss

    init(host: Host, keyStore: KeyStore, knownHosts: KnownHostsStore,
         onSetupChanged: @escaping (HostAgentUpdaterSetup, HostGatekeeperPolicy) -> Void = { _, _ in }) {
        self.host = host
        self.keyStore = keyStore
        self.knownHosts = knownHosts
        self.onSetupChanged = onSetupChanged
        let connection = HostConnection(host: host, keyStore: keyStore, knownHosts: knownHosts)
        _connection = State(initialValue: connection)
        _manager = State(initialValue: HostServiceManager(connection: connection) { status in
            onSetupChanged(status.setupState, host.gatekeeperPolicy)
        })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Host service") {
                    Text(host.name).font(.headline)
                    Text("One background service for LLM agents, updates, and hardware metrics.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let status = manager.installation {
                        LabeledContent("Status", value: status.running ? "Running" : status.installed ? "Stopped" : "Not installed")
                            .accessibilityIdentifier("host.service.status")
                        if !status.version.isEmpty { LabeledContent("Version", value: status.version) }
                        if let components = status.components, !components.isEmpty {
                            // Friendly names first, then raw script digests.
                            let friendly: [(String, String)] = [
                                ("service", "Service"),
                                ("metrics", "Metrics collector"),
                                ("metrics_windows", "Metrics collector (Windows)"),
                                ("updater", "Updater protocol"),
                            ]
                            ForEach(friendly.filter { components[$0.0] != nil }, id: \.0) { key, label in
                                LabeledContent(label, value: components[key] ?? "")
                            }
                            let digests = components.keys.filter { $0.hasSuffix(".py") || $0.hasSuffix(".txt") }.sorted()
                            if !digests.isEmpty {
                                DisclosureGroup("Script digests") {
                                    ForEach(digests, id: \.self) { name in
                                        LabeledContent(name, value: components[name] ?? "")
                                            .font(.caption.monospaced())
                                    }
                                }
                            }
                        }
                        if status.running {
                            LabeledContent("Metrics", value: status.metrics == true ? "Collecting" : "Unavailable")
                                .accessibilityIdentifier("host.service.metrics")
                            LabeledContent("Agent updates", value: status.updates == true ? "Ready" : "Unavailable")
                        }
                    } else {
                        LabeledContent("Status", value: manager.isBusy ? "Checking…" : "Unknown")
                            .accessibilityIdentifier("host.service.status")
                    }
                    if manager.isBusy || connection.state == .connecting {
                        ProgressView("Working on the host…")
                    }
                    if let error = manager.error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
                    if let message = manager.message { Text(message).foregroundStyle(.secondary) }
                    if case .failed(let message) = connection.state { Text(message).foregroundStyle(.red) }
                    if case .hostKeyChanged(let fingerprint) = connection.state {
                        Text("SSH host key changed. Verify this fingerprint before reconnecting: \(fingerprint)").foregroundStyle(.red)
                    }
                }
                Section {
                    Button(manager.installation.map { $0.installed ? "Update / Repair Service" : "Install Host Service" } ?? "Install / Repair Service") {
                        perform("install")
                    }
                    .accessibilityIdentifier("host.service.install")
                    if manager.installation?.installed == true {
                        Button(manager.installation?.running == true ? "Restart Service" : "Start Service") {
                            perform(manager.installation?.running == true ? "restart" : "start")
                        }
                        .accessibilityIdentifier("host.service.restart")
                        if manager.installation?.running == true {
                            Button("Stop Service") { perform("stop") }
                                .accessibilityIdentifier("host.service.stop")
                        }
                        Button("Remove Service", role: .destructive) { confirmRemove = true }
                            .accessibilityIdentifier("host.service.remove")
                    }
                } footer: {
                    Text("Updates replace the previous service and standalone metrics collectors. Agent conversations, update history, and queued requests are preserved.")
                }
                .disabled(connection.state != .connected || manager.isBusy)
                Section("LLM agents") {
                    Button("Manage Agents and Updates") { showAgents = true }
                        .disabled(manager.isBusy)
                }
            }
            .navigationTitle("Host Service")
            .navigationBarTitleDisplayMode(.inline)
            .accessibilityIdentifier("host.service.sheet")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }.disabled(manager.isBusy)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        task = Task {
                            if connection.state != .connected { await connection.connect() }
                            await manager.refresh()
                        }
                    }.disabled(manager.isBusy)
                }
            }
            .confirmationDialog("Remove the host service?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove Service", role: .destructive) { perform("remove") }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Background metrics and agent updates will stop. Your conversations and update history will be kept.")
            }
            .sheet(isPresented: $showAgents) {
                HostAIAgentsSheet(host: host, keyStore: keyStore, knownHosts: knownHosts,
                                  onSetupChanged: onSetupChanged)
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(manager.isBusy)
        .task {
            await connection.connect()
            await manager.refresh()
        }
        .onDisappear {
            task?.cancel()
            Task { await task?.value; await connection.disconnect() }
        }
    }

    private func perform(_ action: String) {
        task = Task {
            await manager.perform(action)
        }
    }
}
