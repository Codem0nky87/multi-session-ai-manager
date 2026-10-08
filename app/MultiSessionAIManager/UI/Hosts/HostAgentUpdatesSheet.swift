import SwiftUI

/// The AI-agent rolling update panel, shared by the merged AI Agents sheet
/// and the standalone sheet (kept for the host-service entry point).
@MainActor
struct HostAgentUpdatesPanel: View {
    @State private var installer: AgentUpdaterInstaller
    @State private var manager: AgentUpdateManager
    @State private var operations = HostSetupRestoreOperationCoordinator()
    @State private var policy: HostGatekeeperPolicy
    @State private var preview: AgentUpdatePreview?
    @State private var showingConfirmation = false
    private let connection: HostConnection
    private let initialSetup: HostAgentUpdaterSetup
    private let onSetupChanged: (HostAgentUpdaterSetup, HostGatekeeperPolicy) -> Void

    init(
        host: Host,
        connection: HostConnection,
        onSetupChanged: @escaping (HostAgentUpdaterSetup, HostGatekeeperPolicy) -> Void = { _, _ in }
    ) {
        self.connection = connection
        _installer = State(initialValue: AgentUpdaterInstaller(connection: connection))
        _manager = State(initialValue: AgentUpdateManager(connection: connection))
        _policy = State(initialValue: host.gatekeeperPolicy)
        initialSetup = host.agentUpdaterSetup
        self.onSetupChanged = onSetupChanged
    }

    var body: some View {
        ScrollView {
            VStack(spacing: Theme.Space.lg) {
                serviceStatusLine
                toolsCard
                if let batch = manager.batch, batch.id != nil || batch.phase != .idle {
                    batchCard(batch)
                }
                if case .failed(let message) = manager.state {
                    GlassCard {
                        Label(message, systemImage: "xmark.octagon.fill")
                            .font(Theme.body(14))
                            .foregroundStyle(Theme.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(Theme.Space.md)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .task(id: connection.state) {
            guard case .connected = connection.state else { return }
            operations.start {
                await installer.probe()
                await manager.refresh()
            }
        }
        // Durable progress: while a batch is active on the host, keep polling
        // its status so the per-session rows update one by one without the
        // user pressing anything. The host service is the source of truth;
        // closing this view never affects the running batch.
        .task(id: manager.batch?.isActive ?? false) {
            guard manager.batch?.isActive == true else { return }
            while !Task.isCancelled, manager.batch?.isActive == true {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                await manager.pollBatch()
            }
        }
        .onChange(of: installer.state) { _, state in
            switch state {
            case .ready:
                onSetupChanged(.ready, policy)
            case .failed, .approvalRequired:
                onSetupChanged(.failed, policy)
            case .idle, .probing, .absent, .installing:
                break
            }
        }
        .onChange(of: policy) { _, value in
            manager.setGatekeeperPolicy(value)
            onSetupChanged(currentSetup, value)
        }
        .onDisappear {
            Task { await operations.cancelAndWait() }
        }
        .confirmationDialog(
            preview?.requestedTools.isEmpty == true
                ? "Re-launch AI agents on this host?"
                : "Update AI agents on this host?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button(preview?.requestedTools.isEmpty == true ? "Queue Rolling Re-launch" : "Queue Rolling Update") {
                guard let preview else { return }
                operations.start { await manager.submit(preview) }
            }
            .accessibilityIdentifier("host.agent-updates.confirm")
            Button("Cancel", role: .cancel) { preview = nil }
        } message: {
            Text(preview.map(AgentUpdatePresentation.confirmation(for:)) ?? "")
        }
        .accessibilityIdentifier("host.agent-updates.sheet")
    }

    /// The updater rides the host service installed from the Host Service
    /// sheet, so this is a status line rather than a second management card.
    private var serviceStatusLine: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                if manager.serviceStatus?.isReady == true {
                    Label("Updater service ready", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.success)
                } else if let message = manager.serviceMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.warning)
                } else {
                    Label("Checking updater service…", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if let checked = manager.lastChecked {
                    Text("Checked \(checked.formatted(date: .omitted, time: .shortened))")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .font(Theme.body(13))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("host.agent-updates.service")

            // Repair path stays available without a whole card: the probe can
            // land on absent/failed after a host-side change.
            serviceAction

            Picker("macOS Gatekeeper", selection: $policy) {
                Text("Manual approval").tag(HostGatekeeperPolicy.manualApproval)
                Text("Verified artifacts").tag(HostGatekeeperPolicy.verifiedVendorArtifacts)
            }
            .pickerStyle(.segmented)
            Text(HostAgentUpdaterPresentation.gatekeeperDetail(for: policy))
                .font(Theme.body(12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.Space.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
            .fill(Theme.bgElevated.opacity(0.6)))
    }

    @ViewBuilder
    private var serviceAction: some View {
        let action = AgentUpdatePresentation.serviceAction(
            setup: currentSetup,
            installer: installer.state
        )
        switch action {
        case .none:
            EmptyView()
        case .completeSetup:
            serviceButton("Complete Setup")
        case .repairService:
            serviceButton("Repair Service")
        case .approvalRequired, .administratorAction:
            if case .approvalRequired(let approval) = installer.state {
                let content = HostAgentUpdaterPresentation.approval(approval)
                Label(content.title, systemImage: "person.badge.key.fill")
                    .foregroundStyle(Theme.warning)
                ForEach(Array(content.instructions.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                }
                Button("Test Again") {
                    operations.start {
                        await installer.probe()
                        await manager.refresh()
                    }
                }
                .foregroundStyle(Theme.accent)
                .frame(minHeight: 44)
            } else {
                Label(
                    action == .administratorAction
                        ? "Administrator Action Required" : "Approval Required",
                    systemImage: "person.badge.key.fill"
                )
                .foregroundStyle(Theme.warning)
            }
        }
    }

    private func serviceButton(_ title: String) -> some View {
        Button(title) {
            operations.start {
                await installer.installOrRepair(policy: policy)
                await manager.refresh()
            }
        }
        .font(.system(.body, design: .rounded, weight: .semibold))
        .foregroundStyle(Theme.accent)
        .frame(minHeight: 44)
        .accessibilityIdentifier("host.agent-updates.service-action")
    }

    private var toolsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                HStack(alignment: .center) {
                    SectionLabel(text: "Installed agents")
                        .accessibilityIdentifier("host.agent-updates.tools")
                    Spacer()
                    if manager.tools.contains(where: { $0.installed != nil }) {
                        Button("Re-launch All Sessions") {
                            relaunch(nil)
                        }
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.accent)
                        .accessibilityIdentifier("host.agent-updates.relaunch-all")
                    }
                }
                if manager.tools.isEmpty {
                    HStack(spacing: Theme.Space.sm) {
                        ProgressView().tint(Theme.accent)
                        Text("Reading installed and latest versions…")
                            .font(Theme.body(13))
                            .foregroundStyle(Theme.textSecondary)
                    }
                } else {
                    ForEach(manager.tools, id: \.tool) { version in
                        toolRow(version)
                        if version.tool != manager.tools.last?.tool { Divider().overlay(Theme.hairline) }
                    }
                }
            }
        }
    }

    private func toolRow(_ version: AgentToolVersion) -> some View {
        let definition = AgentToolRegistry.definition(for: version.tool)
        let presentation = AgentUpdatePresentation.row(for: version)
        return VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(definition.displayName)
                        .font(Theme.title(16))
                        .foregroundStyle(Theme.textPrimary)
                        .accessibilityIdentifier("host.agent-updates.row.\(version.tool.rawValue)")
                    Text(presentation.status)
                        .font(Theme.mono(12))
                        .foregroundStyle(rowTint(presentation.state))
                }
                Spacer()
                if presentation.action == .update {
                    Button("Update") { prepare(version.tool) }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accent)
                        .accessibilityIdentifier("host.agent-updates.update.\(version.tool.rawValue)")
                } else if presentation.state == .current {
                    Button("Re-launch") { relaunch(version.tool) }
                        .buttonStyle(.bordered)
                        .tint(Theme.accent)
                        .accessibilityIdentifier("host.agent-updates.relaunch.\(version.tool.rawValue)")
                } else if presentation.action == .administratorAction {
                    Text("Administrator Action Required")
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.warning)
                        .multilineTextAlignment(.trailing)
                }
            }
            if let detail = presentation.detail {
                Text(detail)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let executablePath = version.executablePath {
                Text(executablePath)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textMuted)
                    .textSelection(.enabled)
            }
        }
    }

    private func batchCard(_ status: AgentUpdateBatchStatus) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                SectionLabel(text: "Rolling update")
                    .accessibilityIdentifier("host.agent-updates.batch")
                Text(AgentUpdatePresentation.batchTitle(status))
                    .font(Theme.title(17))
                    .foregroundStyle(status.attention > 0 || status.failed > 0 ? Theme.warning : Theme.textPrimary)
                Text(AgentUpdatePresentation.batchSummary(status))
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textSecondary)
                if status.total > 0 {
                    ProgressView(value: Double(status.restored + status.failed), total: Double(status.total))
                        .tint(status.failed > 0 ? Theme.warning : Theme.accent)
                }
                if status.phase == .approvalRequired {
                    let name = status.approvalTool.map {
                        AgentToolRegistry.definition(for: $0).displayName
                    } ?? "the updated agent"
                    Label("Open \(name) once on the host", systemImage: "person.badge.key.fill")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.warning)
                    Text("Sign in to the host, launch the exact executable path shown above, and choose Open in the macOS prompt. All conversations stay running until approval succeeds.")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Test Again") {
                        operations.start {
                            await installer.probe()
                            await manager.refresh()
                        }
                    }
                    .foregroundStyle(Theme.accent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("host.agent-updates.approval-test")
                }
                if !status.targets.isEmpty {
                    // One row per detected session, updating live as the host
                    // service works through them one by one.
                    ForEach(status.targets, id: \.index) { target in
                        targetRow(target)
                        .accessibilityIdentifier("host.agent-updates.target.\(target.index)")
                    }
                }
            }
        }
    }

    private func targetRow(_ target: AgentUpdateTargetStatus) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.sm) {
            Image(systemName: targetIcon(target))
                .font(.system(size: 12))
                .foregroundStyle(targetTint(target))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(targetLabel(target))
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textPrimary)
                Text(target.message.replacingOccurrences(of: "_", with: " "))
                    .font(Theme.mono(11))
                    .foregroundStyle(target.phase == "failed" ? Theme.danger : Theme.textSecondary)
            }
            Spacer()
            if target.attempts > 0 {
                Text("attempt \(target.attempts)/3")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    private func targetLabel(_ target: AgentUpdateTargetStatus) -> String {
        let toolName = target.tool.map { AgentToolRegistry.definition(for: $0).displayName }
        let shortConversation = target.conversationID.map {
            $0.count > 12 ? String($0.prefix(8)) + "…" + String($0.suffix(4)) : $0
        }
        let parts = [toolName, shortConversation].compactMap { $0 }
        return parts.isEmpty ? "Session #\(target.index)" : parts.joined(separator: " · ")
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

    private func prepare(_ tool: AgentToolID) {
        operations.start {
            do {
                let value = try await manager.prepareUpdate([tool])
                preview = value
                if value.existingBatch == nil {
                    showingConfirmation = true
                }
            } catch {
                // The observable manager publishes the bounded actionable error.
            }
        }
    }

    private func relaunch(_ tool: AgentToolID?) {
        operations.start {
            do {
                let value = try await manager.prepareRelaunch(for: tool)
                preview = value
                if value.existingBatch == nil {
                    showingConfirmation = true
                }
            } catch {
                // The observable manager publishes the bounded actionable error.
            }
        }
    }

    func refresh() {
        operations.start {
            await installer.probe()
            await manager.refresh()
        }
    }

    var isSubmitting: Bool { manager.state == .submitting }

    private var currentSetup: HostAgentUpdaterSetup {
        switch installer.state {
        case .ready: .ready
        case .failed, .approvalRequired: .failed
        case .idle, .probing, .absent, .installing: initialSetup
        }
    }

    private func rowTint(_ state: AgentUpdateRowState) -> Color {
        switch state {
        case .current: Theme.success
        case .updateAvailable: Theme.accent
        case .latestUnknown, .ambiguousInstall: Theme.warning
        case .notInstalled: Theme.textMuted
        }
    }
}

/// Standalone wrapper kept for the host-service entry point.
@MainActor
struct HostAgentUpdatesSheet: View {
    @State private var connection: HostConnection
    @State private var lifecycle: HerdrSSHConnectionLifecycle
    @State private var panel: HostAgentUpdatesPanel?
    @Environment(\.dismiss) private var dismiss

    init(
        host: Host,
        keyStore: KeyStore,
        knownHosts: KnownHostsStore,
        transport: (any SSHTransport)? = nil,
        onSetupChanged: @escaping (HostAgentUpdaterSetup, HostGatekeeperPolicy) -> Void = { _, _ in }
    ) {
        let connection = HostConnection(
            host: host,
            keyStore: keyStore,
            knownHosts: knownHosts,
            transport: transport ?? NIOSSHTransport()
        )
        _connection = State(initialValue: connection)
        _lifecycle = State(initialValue: HerdrSSHConnectionLifecycle(
            connect: { await connection.connect() },
            disconnect: { await connection.disconnect() }
        ))
        _panel = State(initialValue: HostAgentUpdatesPanel(
            host: host, connection: connection, onSetupChanged: onSetupChanged
        ))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                connectionContent
            }
            .navigationTitle("AI Agent Updates")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { close() }
                        .foregroundStyle(Theme.accent)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        panel?.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(connection.state != .connected)
                    .accessibilityLabel("Refresh")
                    .accessibilityIdentifier("host.agent-updates.refresh")
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(panel?.isSubmitting ?? false)
        .task {
            if case .idle = connection.state { lifecycle.connect() }
        }
        .onDisappear {
            Task {
                await lifecycle.close()
            }
        }
    }

    @ViewBuilder
    private var connectionContent: some View {
        switch connection.state {
        case .idle, .connecting:
            statusScreen(
                title: "Connecting to SSH host",
                detail: "Version checks start only while this sheet is visible.",
                image: "network",
                retry: nil
            )
        case .failed(let message):
            statusScreen(title: "SSH connection failed", detail: message, image: "wifi.exclamationmark") {
                lifecycle.connect()
            }
        case .hostKeyChanged(let fingerprint):
            statusScreen(
                title: "SSH host key changed",
                detail: "Verify the changed fingerprint before reconnecting: \(fingerprint)",
                image: "exclamationmark.shield.fill",
                retry: nil
            )
        case .connected:
            if let panel {
                panel
            }
        }
    }

    private func close() {
        Task {
            await lifecycle.close()
            dismiss()
        }
    }

    private func statusScreen(
        title: String,
        detail: String,
        image: String,
        retry: (() -> Void)?
    ) -> some View {
        VStack(spacing: Theme.Space.md) {
            Image(systemName: image)
                .font(.largeTitle)
                .foregroundStyle(Theme.accent)
            Text(title).font(Theme.title(18)).foregroundStyle(Theme.textPrimary)
            Text(detail)
                .font(Theme.body(13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            if let retry {
                Button("Retry", action: retry).buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Space.xl)
    }
}
