import SwiftUI

struct AddHostWizardView: View {
    let store: HostStore
    let keyStore: KeyStore
    let knownHosts: KnownHostsStore
    let onSaved: (Host, Bool) -> Void

    @State private var step = 1
    @State private var draft = Host(name: "", address: "", username: "", keyID: "", defaultWorkdir: "")
    @State private var provisioning: AddHostProvisioningModel?
    @State private var operations = HostSetupRestoreOperationCoordinator()
    @State private var isWorking = false
    @State private var isClosing = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if step == 1 {
                HostEditView(store: store, keyStore: keyStore, knownHosts: knownHosts,
                             host: draft, onContinue: beginSetup)
            } else if let model = provisioning {
                setupSteps(model)
            }
        }
        .interactiveDismissDisabled(isWorking || isClosing)
        .onDisappear { closeConnection() }
        .alert("Host Setup Error", isPresented: Binding(
            get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func setupSteps(_ model: AddHostProvisioningModel) -> some View {
        ZStack {
            AppBackground()
            ScrollView {
                VStack(spacing: Theme.Space.lg) {
                    if step == 2 {
                        herdrCard(model)
                        servicesCard(model)
                        NeonButton(title: "Next", systemImage: "arrow.right", enabled: model.canContinue && !isWorking) {
                            draft.agentUpdaterSetup = model.updaterSetup
                            step = 3
                            run { await model.integrations.probe() }
                        }
                    } else if step == 3 {
                        settingsCard(model)
                        NeonButton(title: "Next", systemImage: "arrow.right", enabled: !isWorking) { step = 4 }
                    } else {
                        summaryCard(model)
                    }
                }
                .padding(Theme.Space.md)
            }
        }
        .navigationTitle("Add Host - Step \(step) of 4")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Back") { goBack() }
                    .disabled(isWorking || isClosing)
            }
        }
        .disabled(isClosing)
    }

    private func herdrCard(_ model: AddHostProvisioningModel) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                SectionLabel(text: "1 · Herdr on this host")
                switch model.connection.state {
                case .idle, .connecting:
                    progress("Connecting to \(draft.address)…")
                case .failed(let message):
                    problem(message)
                    retryDiscovery(model)
                case .hostKeyChanged(let fingerprint):
                    problem("The SSH host key changed (\(fingerprint)). Verify the host's fingerprint before trusting it again.")
                case .connected:
                    herdrStatus(model)
                }
            }
        }
    }

    @ViewBuilder
    private func herdrStatus(_ model: AddHostProvisioningModel) -> some View {
        switch model.herdr.state {
        case .idle, .probing:
            progress("Checking whether Herdr is installed…")
        case .absent(let curlAvailable):
            Text("Herdr is not installed.")
                .foregroundStyle(Theme.warning)
            if curlAvailable {
                command(model.herdr.platformInstallCommand)
                NeonButton(title: "Install Herdr", systemImage: "arrow.down.circle", enabled: !isWorking) {
                    run { await model.installHerdr() }
                }
            } else {
                problem("Install curl on the host, then check again to enable Herdr installation.")
            }
            retryDiscovery(model)
        case .present(let version), .ready(let version):
            if model.herdrReady {
                Label("Herdr \(version) is ready", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(Theme.success)
            } else {
                problem("Found Herdr \(version). This app needs \(HerdrInstaller.minimumVersion) or newer before setting up services.")
                command(HerdrInstaller.updateCommand)
                NeonButton(title: "Update Herdr", systemImage: "arrow.down.circle", enabled: !isWorking) {
                    run { await model.installHerdr() }
                }
            }
        case .installing:
            progress("Installing and verifying Herdr…")
        case .failed(let message):
            problem(message)
            retryDiscovery(model)
        }
    }

    private func servicesCard(_ model: AddHostProvisioningModel) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                SectionLabel(text: "2 · Host services")
                if !model.herdrReady {
                    Text("Verify Herdr first, then install the host service for agents, updates, and hardware metrics.")
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    switch model.metricsState {
                    case .idle:
                        Text("Host service: ready to install")
                    case .installing:
                        progress("Installing the host service…")
                    case .ready:
                        Label("Host service and metrics installed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.success)
                    case .failed(let message):
                        problem("Host service: \(message)")
                    }
                    updaterStatus(model.updater)
                    if let warning = HostAgentUpdaterPresentation.warning(for: model.updaterSetup),
                       model.canSkipUpdater || model.updaterSetup == .skipped {
                        problem(warning)
                    }
                    if !model.canContinue {
                        NeonButton(title: isWorking ? "Setting up services…" : "Install or Check Services",
                                   systemImage: "gearshape.2", enabled: !isWorking) {
                            run { await model.installServices() }
                        }
                    }
                    if model.canSkipUpdater {
                        Button("Continue without Background Updater") { model.skipUpdater() }
                            .foregroundStyle(Theme.warning)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func updaterStatus(_ installer: AgentUpdaterInstaller) -> some View {
        switch installer.state {
        case .idle:
            Text("Background updater: waiting for setup")
        case .probing:
            progress("Checking the background updater…")
        case .absent:
            Text("Background updater is not installed.")
        case .installing:
            progress("Installing and verifying the background updater…")
        case .ready:
            Label("Background updater is ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(Theme.success)
        case .approvalRequired(let approval):
            let presentation = HostAgentUpdaterPresentation.approval(approval)
            problem(presentation.title)
            ForEach(Array(presentation.instructions.enumerated()), id: \.offset) { _, instruction in
                Text(instruction).textSelection(.enabled)
            }
        case .failed(let message):
            problem(message)
        }
    }

    private func settingsCard(_ model: AddHostProvisioningModel) -> some View {
        VStack(spacing: Theme.Space.lg) {
            GlassCard {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    SectionLabel(text: "Updater Settings")
                    if let warning = HostAgentUpdaterPresentation.warning(for: model.updaterSetup) {
                        problem(warning)
                    } else {
                        Text("The host service processes updates you queue from AI Agent Updates, even after the iPad disconnects.")
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text("macOS downloaded-app approval")
                    Picker("Downloaded-app approval", selection: $draft.gatekeeperPolicy) {
                        Text("Manual").tag(HostGatekeeperPolicy.manualApproval)
                        Text("Verified artifacts").tag(HostGatekeeperPolicy.verifiedVendorArtifacts)
                    }
                    .pickerStyle(.segmented)
                    Text(HostAgentUpdaterPresentation.gatekeeperDetail(for: draft.gatekeeperPolicy))
                        .font(Theme.body(13))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            GlassCard {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    SectionLabel(text: "Session restore")
                    Text("Enable Herdr integrations so supported agents can resume saved conversations. This does not restart arbitrary shell processes.")
                        .foregroundStyle(Theme.textSecondary)
                    integrationStatus(model.integrations)
                    if model.integrations.canInstallOrRepair {
                        NeonButton(title: "Enable or Repair Session Restore", systemImage: "arrow.clockwise", enabled: !isWorking) {
                            run { await model.integrations.installOrRepairAll() }
                        }
                    }
                    Button("Check Again") {
                        run { await model.integrations.probe() }
                    }
                    .disabled(isWorking)
                }
            }
        }
    }

    @ViewBuilder
    private func integrationStatus(_ manager: HerdrIntegrationManager) -> some View {
        switch manager.state {
        case .idle, .probing:
            progress("Discovering installed agents and restore integrations…")
        case .installing:
            progress("Enabling and verifying restore integrations…")
        case .failed(let message):
            problem(message)
        case .ready:
            if manager.agents.isEmpty {
                Text("No supported AI agents were found on this host.")
            }
        }
        ForEach(manager.agents) { agent in
            LabeledContent(agent.target.displayName, value: agent.status.displayText)
        }
        ForEach(manager.failures) { failure in
            problem("\(failure.displayName): \(failure.message)")
        }
    }

    private func summaryCard(_ model: AddHostProvisioningModel) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                SectionLabel(text: "Summary")
                LabeledContent("Name", value: draft.name)
                LabeledContent("SSH", value: "\(draft.username)@\(draft.address):\(draft.port)")
                LabeledContent("Workdir", value: draft.defaultWorkdir.isEmpty ? "Host default" : draft.defaultWorkdir)
                LabeledContent("Background updater", value: model.updaterSetup == .ready ? "Ready" : "Skipped")
                LabeledContent("Downloaded-app approval", value: draft.gatekeeperPolicy == .manualApproval ? "Manual" : "Verified artifacts")
                NeonButton(title: "Save Host", systemImage: "checkmark", enabled: model.canContinue && !isWorking) {
                    do {
                        draft.agentUpdaterSetup = model.updaterSetup
                        let host = try draft.validated()
                        store.add(host)
                        onSaved(host, true)
                        dismiss()
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }

    private func progress(_ message: String) -> some View {
        HStack { ProgressView(); Text(message) }
            .foregroundStyle(Theme.textSecondary)
    }

    private func problem(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(Theme.warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func command(_ value: String) -> some View {
        Text(value).font(Theme.mono(12)).textSelection(.enabled)
    }

    private func retryDiscovery(_ model: AddHostProvisioningModel) -> some View {
        Button("Check Again") { run { await model.discover() } }
            .disabled(isWorking)
    }

    private func beginSetup(_ host: Host) {
        draft = host
        let model = AddHostProvisioningModel(connection: HostConnection(
            host: host, keyStore: keyStore, knownHosts: knownHosts
        ))
        provisioning = model
        step = 2
        run { await model.discover() }
    }

    private func run(_ action: @escaping @MainActor @Sendable () async -> Void) {
        guard !isWorking, !isClosing else { return }
        isWorking = true
        if !operations.start({
            await action()
            isWorking = false
        }) {
            isWorking = false
        }
    }

    private func goBack() {
        if step > 2 {
            step -= 1
        } else {
            guard let model = provisioning else { return }
            isClosing = true
            Task {
                await operations.cancelAndWait()
                await model.connection.disconnect()
                provisioning = nil
                step = 1
                isClosing = false
            }
        }
    }

    private func closeConnection() {
        guard let model = provisioning else { return }
        isClosing = true
        Task {
            await operations.cancelAndWait()
            await model.connection.disconnect()
        }
    }
}
