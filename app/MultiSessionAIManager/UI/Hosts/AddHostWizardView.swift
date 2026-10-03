import SwiftUI

struct AddHostWizardView: View {
    let store: HostStore
    let keyStore: KeyStore
    let knownHosts: KnownHostsStore
    let onSaved: (Host, Bool) -> Void

    @State private var step = 1

    @State private var name = ""
    @State private var address = ""
    @State private var port = 22
    @State private var username = ""
    @State private var defaultWorkdir = ""
    @State private var keyID = ""
    
    @State private var keyIDs: [String] = []

    @State private var step2Status = "Ready to install"
    @State private var isStep2Done = false
    @State private var isStep2Running = false
    
    @State private var enableDailyUpdates = true
    @State private var enableSessionRestore = true

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                AppBackground()
                ScrollView {
                    VStack(spacing: Theme.Space.lg) {
                        if step == 1 {
                            step1
                        } else if step == 2 {
                            step2
                        } else if step == 3 {
                            step3
                        } else {
                            step4
                        }
                    }
                    .padding(.horizontal, Theme.Space.md)
                    .padding(.top, Theme.Space.md)
                    .padding(.bottom, 100)
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
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .onAppear {
                keyIDs = keyStore.allKeyIDs().sorted()
            }
        }
    }

    private var step1: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                SectionLabel(text: "Basic Details")
                DarkField(label: "Name", text: $name, placeholder: "My server")
                DarkField(label: "Address", text: $address, placeholder: "example.com", keyboard: .URL)
                DarkField(label: "Port", value: $port)
                DarkField(label: "Username", text: $username, placeholder: "root")
                DarkField(label: "Default workdir", text: $defaultWorkdir, placeholder: "~/projects")
                
                VStack(alignment: .leading, spacing: 6) {
                    Text("SSH KEY")
                        .font(Theme.label(12))
                        .foregroundStyle(Theme.textMuted)
                    Picker("Key", selection: $keyID) {
                        Text("None").tag("")
                        ForEach(keyIDs, id: \.self) { id in
                            Text(id).tag(id)
                        }
                    }
                    .pickerStyle(.menu)
                    .tint(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                            .fill(Theme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    )
                }
                
                NeonButton(title: "Next", systemImage: "arrow.right", enabled: true) { step = 2 }
            }
        }
    }

    private var step2: some View {
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
        
        step2Status = "Connecting to \(address)..."
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
            step2Status = "Failed to install metrics: \(error.localizedDescription)"
            return
        }
        
        step2Status = "Probing Agent Updater Service..."
        let updaterInstaller = AgentUpdaterInstaller(connection: connection)
        await updaterInstaller.probe()
        if case .absent = updaterInstaller.state {
             step2Status = "Installing Agent Updater Service..."
             await updaterInstaller.installOrRepair(policy: .manualApproval)
        }
        
        step2Status = "Installation Complete!"
        isStep2Done = true
        await connection.disconnect()
    }

    private var step3: some View {
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
    }

    private var step4: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                SectionLabel(text: "Summary")
                Text("Name: \(name)\nAddress: \(address)")
                    .font(Theme.body(15))
                    .foregroundStyle(Theme.textSecondary)
                NeonButton(title: "Save Host", systemImage: "checkmark", enabled: true) {
                    let host = Host(
                        id: UUID(),
                        name: name.isEmpty ? "My Host" : name,
                        address: address,
                        port: port,
                        username: username,
                        keyID: keyID,
                        defaultWorkdir: defaultWorkdir,
                        agentUpdaterSetup: .unchecked,
                        gatekeeperPolicy: .manualApproval
                    )
                    store.add(host)
                    onSaved(host, true)
                    dismiss()
                }
            }
        }
    }
}
