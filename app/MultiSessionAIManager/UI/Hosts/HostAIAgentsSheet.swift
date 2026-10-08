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
/// the session re-launch roll (start, one by one, or skip).
@MainActor
struct AgentUpgradeFlowSheet: View {
    enum Stage: Equatable {
        case confirming
        case upgrading
        case sessions
        case rolling
        case done
        case failed(String)
    }

    let tool: AgentToolID
    let connection: HostConnection
    let manager: AgentUpdateManager
    let onFinished: () -> Void

    @State private var stage: Stage = .confirming
    @State private var preview: AgentUpdatePreview?
    @State private var sessions: [HerdrAgentSnapshot] = []
    @State private var unrestorable: [UnrestorablePane] = []
    @State private var closeUnrestorable = false
    @Environment(\.dismiss) private var dismiss

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
                    Button(stage == .done ? "Close" : "Cancel") { finish() }
                        .foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("host.agent-upgrade.close")
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(stage == .upgrading || stage == .rolling)
        .task(id: stage) {
            switch stage {
            case .upgrading, .rolling:
                // Stream the durable host status while the batch is active.
                while !Task.isCancelled, stage == .upgrading || stage == .rolling {
                    await manager.pollBatch()
                    applyBatchProgress()
                    guard stage == .upgrading || stage == .rolling else { break }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch stage {
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
                startUpgrade()
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
            Text(AgentUpdatePresentation.batchTitle(manager.batch ?? .idle))
                .font(Theme.mono(13))
                .foregroundStyle(Theme.textSecondary)
            Text(detail)
                .font(Theme.body(12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if let batch = manager.batch, batch.total > 0 {
                ProgressView(value: Double(batch.restored + batch.failed), total: Double(max(batch.total, 1)))
                    .tint(Theme.accent)
                    .padding(.horizontal, Theme.Space.xl)
            }
        }
        .padding(Theme.Space.lg)
    }

    private var sessionsView: some View {
        ScrollView {
            VStack(spacing: Theme.Space.md) {
                Label("Upgrade complete", systemImage: "checkmark.seal.fill")
                    .font(Theme.title(17))
                    .foregroundStyle(Theme.success)
                Text(sessions.isEmpty
                     ? "No \(definition.displayName) sessions are running — nothing to re-launch."
                     : "\(sessions.count) \(definition.displayName) session\(sessions.count == 1 ? "" : "s") will restart onto the new version, one by one. Working sessions wait until their current work finishes.")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                if !sessions.isEmpty {
                    GlassCard {
                        VStack(alignment: .leading, spacing: Theme.Space.sm) {
                            SectionLabel(text: "Sessions to re-launch")
                            ForEach(sessions, id: \.paneID) { session in
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
                if !unrestorable.isEmpty {
                    VStack(alignment: .leading, spacing: Theme.Space.xs) {
                        Text("Not restorable: \(unrestorable.map { $0.label }.joined(separator: ", "))")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.warning)
                        Toggle("Close these panes too", isOn: $closeUnrestorable)
                            .font(Theme.body(13))
                            .accessibilityIdentifier("host.agent-upgrade.close-unrestorable")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !sessions.isEmpty {
                    Button {
                        startRoll()
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
                ProgressView(value: Double((manager.batch?.restored ?? 0) + (manager.batch?.failed ?? 0)),
                             total: Double(max(manager.batch?.total ?? 1, 1)))
                    .tint(Theme.accent)
                Text(AgentUpdatePresentation.batchTitle(manager.batch ?? .idle))
                    .font(Theme.title(17))
                    .foregroundStyle(Theme.textPrimary)
                if let batch = manager.batch {
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
            if let batch = manager.batch, batch.failed > 0 {
                Text("\(batch.failed) session(s) need attention.")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.warning)
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
            Button("Try Again") { stage = .confirming }
                .buttonStyle(.borderedProminent)
        }
        .padding(Theme.Space.lg)
    }

    // MARK: Steps

    private func startUpgrade() {
        stage = .upgrading
        Task {
            do {
                let value = try await manager.prepareUpgradeOnly(tool)
                preview = value
                if let existing = value.existingBatch, existing.isActive {
                    // Another batch is already running on the host; watch it.
                    return
                }
                await manager.submit(value)
                if case .failed(let message) = manager.state {
                    stage = .failed(message)
                }
            } catch {
                stage = .failed(AgentUpdateManager.message(for: error))
            }
        }
    }

    private func applyBatchProgress() {
        guard let batch = manager.batch else { return }
        switch stage {
        case .upgrading:
            if batch.phase == .approvalRequired {
                stage = .failed("Open \(definition.displayName) once on the host to approve the new build, then retry.")
            } else if !batch.isActive {
                // Upgrade finished (or failed): move to the session step.
                if batch.phase == .failedUpdate {
                    stage = .failed("The host could not update \(definition.displayName). Check the updater service and retry.")
                    return
                }
                loadSessions()
            }
        case .rolling:
            if !batch.isActive {
                stage = batch.failed > 0 ? .done : .done
            }
        default:
            break
        }
    }

    private func loadSessions() {
        Task {
            do {
                let inventory = try await manager.inventory()
                sessions = inventory.filter { $0.tool == tool && $0.isRestorable }
                unrestorable = inventory
                    .filter { $0.tool == tool && !$0.isRestorable }
                    .map { UnrestorablePane(herdrSession: $0.herdrSession,
                                            socketPath: $0.socketPath, paneID: $0.paneID) }
                stage = .sessions
            } catch {
                // No sessions readable: the upgrade itself succeeded; finish.
                sessions = []
                stage = .sessions
            }
        }
    }

    private func startRoll() {
        stage = .rolling
        Task {
            do {
                var value = try await manager.prepareRelaunch(for: tool)
                value = value.withCloseUnrestorablePanes(closeUnrestorable)
                await manager.submit(value)
                if case .failed(let message) = manager.state {
                    stage = .failed(message)
                }
            } catch {
                stage = .failed(AgentUpdateManager.message(for: error))
            }
        }
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
