import re

with open("app/MultiSessionAIManager/UI/Hosts/AddHostWizardView.swift", "r") as f:
    code = f.read()

replacement_state = """    @State private var keyIDs: [String] = []

    @State private var step2Status = "Ready to install"
    @State private var isStep2Done = false
    @State private var isStep2Running = false
    
    @State private var enableDailyUpdates = true
    @State private var enableSessionRestore = true

    @Environment(\\.dismiss) private var dismiss"""

code = code.replace("""    @State private var keyIDs: [String] = []

    @Environment(\\.dismiss) private var dismiss""", replacement_state)


replacement_step2 = """    private var step2: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                SectionLabel(text: "Install Tools")
                Text("Connect to host, verify, install Herdr, and the backend hardware metrics service.")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textSecondary)
                
                Text(step2Status)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.accent)
                    .padding(.vertical, 8)
                
                if !isStep2Done {
                    NeonButton(title: isStep2Running ? "Installing..." : "Start Installation", systemImage: "play.fill", enabled: !isStep2Running) {
                        Task { await runStep2() }
                    }
                } else {
                    NeonButton(title: "Next", systemImage: "arrow.right", enabled: true) { step = 3 }
                }
            }
        }
    }

    private func runStep2() async {
        isStep2Running = true
        defer { isStep2Running = false }
        
        let host = Host(
            id: UUID(),
            name: name.isEmpty ? "Temp" : name,
            address: address,
            port: port,
            username: username,
            keyID: keyID,
            defaultWorkdir: defaultWorkdir,
            agentUpdaterSetup: .unchecked,
            gatekeeperPolicy: .manualApproval
        )
        
        step2Status = "Connecting to \\(address)..."
        let connection = HostConnection(host: host, keyStore: keyStore, knownHosts: knownHosts)
        await connection.connect()
        
        guard connection.state == .connected, let service = connection.provisioningCommandRunner else {
            step2Status = "Failed to connect! Check basic details."
            return
        }
        
        step2Status = "Installing Hardware Metrics script..."
        do {
            try await MSAMMetricsInstaller.install(using: service)
        } catch {
            step2Status = "Failed to install metrics: \\(error.localizedDescription)"
            return
        }
        
        step2Status = "Probing Agent Updater Service..."
        let updaterInstaller = AgentUpdaterInstaller(connection: connection, knownHosts: knownHosts)
        await updaterInstaller.probe()
        if updaterInstaller.state == .absent {
             step2Status = "Installing Agent Updater Service..."
             await updaterInstaller.installOrRepair()
        }
        
        step2Status = "Installation Complete!"
        isStep2Done = true
        await connection.disconnect()
    }"""

code = re.sub(r'    private var step2: some View \{.*?\n    \}', replacement_step2, code, flags=re.DOTALL)


replacement_step3 = """    private var step3: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                SectionLabel(text: "Updater Settings")
                Text("The backend service continuously monitors and maintains the agent environment.")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.textSecondary)
                
                Toggle("Automatically install updates daily", isOn: $enableDailyUpdates)
                    .tint(Theme.accent)
                Toggle("Restart & restore sessions", isOn: $enableSessionRestore)
                    .tint(Theme.accent)
                    
                NeonButton(title: "Next", systemImage: "arrow.right", enabled: true) { step = 4 }
            }
        }
    }"""

code = re.sub(r'    private var step3: some View \{.*?\n    \}', replacement_step3, code, flags=re.DOTALL)

with open("app/MultiSessionAIManager/UI/Hosts/AddHostWizardView.swift", "w") as f:
    f.write(code)
