import SwiftUI
import Observation

/// One place to manage the AI agents on a host. Each agent row carries its
/// own action: Install when missing, Upgrade when a newer release exists,
/// a seal when current. Upgrade opens a guided popup that streams the host
/// upgrade progress and then offers the session re-launch roll — which the
/// user may start or skip.
@MainActor
struct HostAIAgentsSheet: View {
    @State private var connection: HostConnection
    @State private var lifecycle: HerdrSSHConnectionLifecycle
    @State private var software: HostSoftwareManager
    @State private var updater: AgentUpdateManager
    @State private var installer: AgentUpdaterInstaller
    @State private var operations = HostSetupRestoreOperationCoordinator()
    @State private var upgradeTool: AgentToolID?
    @State private var updaterReady = false
    private let onSetupChanged: (HostAgentUpdaterSetup, HostGatekeeperPolicy) -> Void
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
        _software = State(initialValue: HostSoftwareManager(connection: connection))
        _updater = State(initialValue: AgentUpdateManager(connection: connection))
        _installer = State(initialValue: AgentUpdaterInstaller(connection: connection))
        self.onSetupChanged = onSetupChanged
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                if connection.state == .connected {
                    agentsList
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
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(software.busy)
                    .accessibilityLabel("Refresh agents")
                    .accessibilityIdentifier("host.ai-agents.refresh")
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $upgradeTool) { tool in
            AgentUpgradeFlowSheet(
                tool: tool,
                connection: connection,
                manager: updater,
                onFinished: { refresh() }
            )
        }
        .task {
            if case .idle = connection.state { lifecycle.connect() }
        }
        .task(id: connection.state) {
            guard case .connected = connection.state else { return }
            refresh()
        }
        .onDisappear {
            Task {
                await operations.cancelAndWait()
                await lifecycle.close()
            }
        }
    }

    // MARK: - List

    private var agentsList: some View {
        ScrollView {
            VStack(spacing: Theme.Space.md) {
                if !updaterReady {
                    updaterStatusLine
                }
                ForEach([AgentToolID.claude, .codex, .antigravity], id: \.self) { tool in
                    agentRow(tool)
                }
                if let step = software.step {
                    HStack(spacing: Theme.Space.sm) {
                        ProgressView().tint(Theme.accent)
                        Text(step).font(Theme.body(13)).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("host.ai-agents.install-progress")
                }
                if let error = software.error {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let notice = software.notice {
                    Label(notice, systemImage: "checkmark.circle.fill")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.success)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("host.ai-agents.list")
    }

    private func agentRow(_ tool: AgentToolID) -> some View {
        let definition = AgentToolRegistry.definition(for: tool)
        let installed = software.agents.first { $0.id == tool }
        let version = updater.tools.first { $0.tool == tool }
        let updateAvailable = version?.isUpdateAvailable == true
        return GlassCard {
            HStack(alignment: .center, spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(definition.displayName)
                        .font(Theme.title(16))
                        .foregroundStyle(Theme.textPrimary)
                        .accessibilityIdentifier("host.ai-agents.row.\(tool.rawValue)")
                    if installed?.installed == true, let v = installed?.version {
                        if updateAvailable, let latest = version?.latest {
                            Text("\(v) → \(latest)")
                                .font(Theme.mono(12))
                                .foregroundStyle(Theme.accent)
                        } else {
                            Text("Installed · \(v)")
                                .font(Theme.mono(12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    } else if let message = installed?.error ?? version?.error {
                        Text(message)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.textMuted)
                    } else {
                        Text(installed == nil ? "Checking…" : "Not installed")
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.textMuted)
                    }
                    if let path = installed?.path ?? version?.executablePath {
                        Text(path)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.textMuted)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                rowAction(tool, installed: installed, updateAvailable: updateAvailable)
            }
            .frame(minHeight: 56)
        }
    }

    @ViewBuilder
    private func rowAction(_ tool: AgentToolID, installed: HostAgentInstallation?, updateAvailable: Bool) -> some View {
        if installed?.installed == true {
            if updateAvailable {
                Button("Upgrade") {
                    upgradeTool = tool
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(!updaterReady || software.busy)
                .accessibilityIdentifier("host.ai-agents.upgrade.\(tool.rawValue)")
            } else if installed != nil {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.success)
                    .accessibilityIdentifier("host.ai-agents.current.\(tool.rawValue)")
            }
        } else if installed != nil {
            Button("Install") {
                operations.start { await software.install(tool) }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .disabled(software.busy)
            .accessibilityIdentifier("host.software.install.\(tool.rawValue)")
        }
    }

    private var updaterStatusLine: some View {
        HStack(spacing: Theme.Space.sm) {
            if let message = updater.serviceMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            } else {
                Label("Checking updater service…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .font(Theme.body(12))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("host.agent-updates.service")
    }

    // MARK: - Connection states

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
                    .accessibilityIdentifier("host.ai-agents.retry")
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

    // MARK: - Actions

    private func refresh() {
        operations.start {
            await software.refresh()
            await installer.probe()
            await updater.refresh()
            if case .ready = installer.state {
                updaterReady = true
                onSetupChanged(.ready, updater.gatekeeperPolicy)
            } else {
                updaterReady = false
                switch installer.state {
                case .failed, .approvalRequired:
                    onSetupChanged(.failed, updater.gatekeeperPolicy)
                default:
                    break
                }
            }
        }
    }

    private func close() {
        Task {
            await operations.cancelAndWait()
            await lifecycle.close()
            dismiss()
        }
    }
}

// MARK: - Upgrade flow popup

/// The guided upgrade popup: streams the host-side tool upgrade, then offers
/// the session re-launch roll (start, one by one, or skip). `AgentUpgradeFlow`
/// owns the steps; this view only draws them.
@MainActor
struct AgentUpgradeFlowSheet: View {
    let tool: AgentToolID
    let connection: HostConnection
    let manager: AgentUpdateManager
    let onFinished: () -> Void

    @State private var flow: AgentUpgradeFlow
    @Environment(\.dismiss) private var dismiss

    init(tool: AgentToolID, connection: HostConnection, manager: AgentUpdateManager,
         onFinished: @escaping () -> Void) {
        self.tool = tool
        self.connection = connection
        self.manager = manager
        self.onFinished = onFinished
        _flow = State(initialValue: AgentUpgradeFlow(tool: tool, manager: manager))
    }

    private var definition: AgentToolDefinition { AgentToolRegistry.definition(for: tool) }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                content
            }
            .navigationTitle("Upgrade \(definition.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(flow.stage == .done ? "Close" : "Cancel") { finish() }
                        .foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("host.agent-upgrade.close")
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(flow.isBusy)
        .task(id: flow.isBusy) {
            // Stream the durable host status while a step's batch is in flight.
            while !Task.isCancelled, flow.isBusy {
                await flow.poll()
                guard flow.isBusy else { break }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch flow.stage {
        case .confirming:
            confirmView
        case .upgrading:
            progressView(title: "Upgrading \(definition.displayName) on the host",
                         detail: "The host service downloads and verifies the new release. This window stays open until it finishes.")
        case .sessions:
            sessionsView
        case .rolling:
            rollView
        case .done:
            doneView
        case .failed(let message):
            failedView(message)
        }
    }

    // MARK: Stages

    private var confirmView: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.largeTitle)
                .foregroundStyle(Theme.accent)
            Text("Upgrade \(definition.displayName)?")
                .font(Theme.title(18))
                .foregroundStyle(Theme.textPrimary)
            if let version = manager.tools.first(where: { $0.tool == tool }) {
                Text("\(version.installed ?? "?") → \(version.latest ?? "?")")
                    .font(Theme.mono(14))
                    .foregroundStyle(Theme.accent)
            }
            Text("Only \(definition.displayName) sessions are affected. Other agents and ordinary panes keep running.")
                .font(Theme.body(13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button {
                Task { await flow.startUpgrade() }
            } label: {
                Text("Start Upgrade")
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .accessibilityIdentifier("host.agent-upgrade.start")
        }
        .padding(Theme.Space.lg)
    }

    private func progressView(title: String, detail: String) -> some View {
        VStack(spacing: Theme.Space.md) {
            ProgressView().controlSize(.large).tint(Theme.accent)
            Text(title)
                .font(Theme.title(17))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text(flow.statusLine)
                .font(Theme.mono(13))
                .foregroundStyle(Theme.textSecondary)
                .accessibilityIdentifier("host.agent-upgrade.status")
            Text(detail)
                .font(Theme.body(12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(Theme.Space.lg)
    }

    private var sessionsSummary: String {
        if let error = flow.sessionsError {
            return "The sessions on this host could not be listed: \(error)"
        }
        let count = flow.sessions.count
        if count > 0 {
            return "\(count) \(definition.displayName) session\(count == 1 ? "" : "s") will restart onto the new version, one by one. Working sessions wait until their current work finishes."
        }
        return flow.unrestorable.isEmpty
            ? "No \(definition.displayName) sessions are running — nothing to re-launch."
            : "None of the running \(definition.displayName) sessions can be re-launched automatically."
    }

    private var sessionsView: some View {
        ScrollView {
            VStack(spacing: Theme.Space.md) {
                Label("Upgrade complete", systemImage: "checkmark.seal.fill")
                    .font(Theme.title(17))
                    .foregroundStyle(Theme.success)
                Text(sessionsSummary)
                    .font(Theme.body(13))
                    .foregroundStyle(flow.sessionsError == nil ? Theme.textSecondary : Theme.warning)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("host.agent-upgrade.sessions-summary")
                if flow.sessionsError != nil {
                    Button("Check Again") {
                        Task { await flow.loadSessions() }
                    }
                    .font(Theme.body(14))
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("host.agent-upgrade.reload-sessions")
                }
                if !flow.sessions.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            SectionLabel(text: "Sessions to re-launch")
                            ForEach(flow.sessions, id: \.paneID) { session in
                                HStack(spacing: Theme.Space.sm) {
                                    Image(systemName: "circle")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textSecondary)
                                    Text(session.conversationID.map { shortID($0) } ?? "unknown")
                                        .font(Theme.mono(12))
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Text(session.lifecycle.rawValue)
                                        .font(Theme.mono(11))
                                        .foregroundStyle(Theme.textMuted)
                                }
                                .accessibilityIdentifier("host.agent-upgrade.session.\(session.paneID)")
                            }
                        }
                    }
                }
                if !flow.unrestorable.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("Not restorable: \(flow.unrestorable.map { $0.label }.joined(separator: ", "))")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.warning)
                        if !flow.sessions.isEmpty {
                            Toggle("Close these panes too", isOn: Binding(
                                get: { flow.closeUnrestorable },
                                set: { flow.closeUnrestorable = $0 }
                            ))
                            .font(Theme.body(13))
                            .accessibilityIdentifier("host.agent-upgrade.close-unrestorable")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !flow.sessions.isEmpty {
                    Button {
                        Task { await flow.startRoll() }
                    } label: {
                        Text("Re-launch Sessions One by One")
                            .font(.system(.body, design: .rounded, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .accessibilityIdentifier("host.agent-upgrade.relaunch")
                }
                Button("Skip — finish upgrade") {
                    finish()
                }
                .font(Theme.body(14))
                .foregroundStyle(Theme.textSecondary)
                .frame(minHeight: 44)
                .accessibilityIdentifier("host.agent-upgrade.skip")
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
    }

    private var rollView: some View {
        ScrollView {
            VStack(spacing: Theme.Space.md) {
                if let batch = flow.progress {
                    ProgressView(value: Double(batch.restored + batch.failed),
                                 total: Double(max(batch.total, 1)))
                        .tint(Theme.accent)
                } else {
                    // Queued, not picked up yet: there is no count to show.
                    ProgressView().tint(Theme.accent)
                }
                Text(flow.statusLine)
                    .font(Theme.title(17))
                    .foregroundStyle(Theme.textPrimary)
                    .accessibilityIdentifier("host.agent-upgrade.status")
                if let batch = flow.progress, !batch.targets.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            ForEach(batch.targets, id: \.index) { target in
                                HStack(alignment: .top, spacing: Theme.Space.sm) {
                                    Image(systemName: targetIcon(target))
                                        .font(.system(size: 12))
                                        .foregroundStyle(targetTint(target))
                                        .frame(width: 16)
                                    Text(target.conversationID.map { shortID($0) }
                                         ?? "Session #\(target.index)")
                                        .font(Theme.mono(12))
                                        .foregroundStyle(Theme.textPrimary)
                                    Spacer()
                                    Text(target.message.replacingOccurrences(of: "_", with: " "))
                                        .font(Theme.mono(11))
                                        .foregroundStyle(target.phase == "failed" ? Theme.danger : Theme.textSecondary)
                                }
                                .accessibilityIdentifier("host.agent-upgrade.target.\(target.index)")
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
    }

    private var doneView: some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.success)
            Text("Done")
                .font(Theme.title(20))
                .foregroundStyle(Theme.textPrimary)
            if let result = flow.rollResult {
                Text("\(result.restored) of \(result.total) session\(result.total == 1 ? "" : "s") re-launched.")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textSecondary)
                    .accessibilityIdentifier("host.agent-upgrade.result")
                if result.failed > 0 {
                    Text("\(result.failed) session(s) need attention.")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.warning)
                }
            }
        }
        .padding(Theme.Space.lg)
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.danger)
            Text(message)
                .font(Theme.body(14))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Button("Try Again") { flow.retry() }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("host.agent-upgrade.retry")
        }
        .padding(Theme.Space.lg)
    }

    private func finish() {
        onFinished()
        dismiss()
    }

    private func shortID(_ id: String) -> String {
        id.count > 14 ? String(id.prefix(8)) + "…" + String(id.suffix(4)) : id
    }

    private func targetIcon(_ target: AgentUpdateTargetStatus) -> String {
        switch target.phase {
        case "restored": "checkmark.circle.fill"
        case "failed": "xmark.circle.fill"
        case "exited", "exiting": "arrow.triangle.2.circlepath"
        default: target.message == "working" ? "hammer" : "circle"
        }
    }

    private func targetTint(_ target: AgentUpdateTargetStatus) -> Color {
        switch target.phase {
        case "restored": Theme.success
        case "failed": Theme.danger
        case "exited", "exiting": Theme.accent
        default: Theme.textSecondary
        }
    }
}
