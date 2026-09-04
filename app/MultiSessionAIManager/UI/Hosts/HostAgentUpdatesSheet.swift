import SwiftUI

@MainActor
struct HostAgentUpdatesSheet: View {
    @State private var connection: HostConnection
    @State private var installer: AgentUpdaterInstaller
    @State private var manager: AgentUpdateManager
    @State private var lifecycle: HerdrSSHConnectionLifecycle
    @State private var operations = HostSetupRestoreOperationCoordinator()
    @State private var policy: HostGatekeeperPolicy
    @State private var preview: AgentUpdatePreview?
    @State private var showingConfirmation = false
    private let initialSetup: HostAgentUpdaterSetup
    private let onSetupChanged: (HostAgentUpdaterSetup, HostGatekeeperPolicy) -> Void
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
        _installer = State(initialValue: AgentUpdaterInstaller(connection: connection))
        _manager = State(initialValue: AgentUpdateManager(connection: connection))
        _lifecycle = State(initialValue: HerdrSSHConnectionLifecycle(
            connect: { await connection.connect() },
            disconnect: { await connection.disconnect() }
        ))
        _policy = State(initialValue: host.gatekeeperPolicy)
        initialSetup = host.agentUpdaterSetup
        self.onSetupChanged = onSetupChanged
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
                        refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(connection.state != .connected || manager.state == .refreshing)
                    .accessibilityLabel("Refresh")
                    .accessibilityIdentifier("host.agent-updates.refresh")
                }
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(manager.state == .submitting)
        .confirmationDialog(
            "Update AI agents on this host?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Queue Rolling Update") {
                guard let preview else { return }
                operations.start { await manager.submit(preview) }
            }
            Button("Cancel", role: .cancel) { preview = nil }
        } message: {
            Text(preview.map(AgentUpdatePresentation.confirmation(for:)) ?? "")
        }
        .task {
            if case .idle = connection.state { lifecycle.connect() }
        }
        .task(id: connection.state) {
            guard case .connected = connection.state else { return }
            operations.start {
                await installer.probe()
                await manager.refresh()
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
            Task {
                await operations.cancelAndWait()
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
            updatesContent
        }
    }

    private var updatesContent: some View {
        ScrollView {
            VStack(spacing: Theme.Space.lg) {
                serviceCard
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
        .accessibilityIdentifier("host.agent-updates.sheet")
    }

    private var serviceCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                SectionLabel(text: "Host-owned service")
                if manager.serviceStatus?.isReady == true {
                    Label("Service and helper verified", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.success)
                } else if let message = manager.serviceMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Checking service…", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(Theme.textSecondary)
                }

                Picker("macOS Gatekeeper", selection: $policy) {
                    Text("Manual approval").tag(HostGatekeeperPolicy.manualApproval)
                    Text("Verified artifacts").tag(HostGatekeeperPolicy.verifiedVendorArtifacts)
                }
                .pickerStyle(.segmented)
                Text(HostAgentUpdaterPresentation.gatekeeperDetail(for: policy))
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                serviceAction

                if let checked = manager.lastChecked {
                    Text("Checked \(checked.formatted(date: .abbreviated, time: .shortened))")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
        .accessibilityIdentifier("host.agent-updates.service")
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
                SectionLabel(text: "Installed agents")
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
        .accessibilityIdentifier("host.agent-updates.tools")
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
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("host.agent-updates.row.\(version.tool.rawValue)")
    }

    private func batchCard(_ status: AgentUpdateBatchStatus) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                SectionLabel(text: "Rolling update")
                Text(AgentUpdatePresentation.batchTitle(status))
                    .font(Theme.title(17))
                    .foregroundStyle(status.attention > 0 || status.failed > 0 ? Theme.warning : Theme.textPrimary)
                Text(AgentUpdatePresentation.batchSummary(status))
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.textSecondary)
                if !status.targets.isEmpty {
                    ForEach(status.targets, id: \.index) { target in
                        HStack(alignment: .top) {
                            Text("#\(target.index)")
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.textMuted)
                            Text(target.message.replacingOccurrences(of: "_", with: " "))
                                .font(Theme.body(12))
                                .foregroundStyle(target.phase == "failed" ? Theme.danger : Theme.textSecondary)
                            Spacer()
                            if target.attempts > 0 {
                                Text("attempt \(target.attempts)/3")
                                    .font(Theme.mono(10))
                                    .foregroundStyle(Theme.textMuted)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("host.agent-updates.batch")
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

    private func refresh() {
        operations.start {
            await installer.probe()
            await manager.refresh()
        }
    }

    private func close() {
        Task {
            await operations.cancelAndWait()
            await lifecycle.close()
            dismiss()
        }
    }

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
