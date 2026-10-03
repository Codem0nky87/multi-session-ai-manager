import SwiftUI

struct HostInfoSheet: View {
    let host: Host
    let keyStore: KeyStore
    let knownHosts: KnownHostsStore

    @State private var isLoading = false
    @State private var osVersion = "Unknown"
    @State private var serviceVersion = "Unknown"
    @State private var isRunning = false
    @State private var error: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Host Info") {
                    if isLoading {
                        ProgressView("Probing host...")
                    } else if let error = error {
                        Text(error).foregroundColor(.red)
                    } else {
                        LabeledContent("OS Version", value: osVersion)
                        LabeledContent("Service Version", value: serviceVersion)
                        LabeledContent("Service Running", value: isRunning ? "Yes" : "No")
                    }
                }
            }
            .navigationTitle("Host Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                await probeHost()
            }
        }
    }

    private func probeHost() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        
        let connection = HostConnection(
            host: host,
            keyStore: keyStore,
            knownHosts: knownHosts
        )
        await connection.connect()
        guard connection.state == .connected, let service = connection.provisioningCommandRunner else {
            self.error = "Failed to connect via SSH."
            return
        }

        do {
            let contextResult = try await service.run(
                AgentUpdaterInstaller.contextCommand(isWindows: service.isWindows),
                timeout: .seconds(10),
                outputLimit: 65536
            )
            let context = try AgentUpdaterInstaller.parseHostContext(contextResult.stdoutString)
            switch context.platform {
            case .macOS: self.osVersion = "macOS"
            case .linux: self.osVersion = "Linux"
            case .unsupported(let os): self.osVersion = os
            }
            
            if service.isWindows {
                self.serviceVersion = "N/A"
                self.isRunning = false
            } else {
                let verifyResult = try await service.run(
                    AgentUpdaterInstaller.verificationCommand(for: context),
                    timeout: .seconds(10),
                    outputLimit: 65536
                )
                let status = try AgentUpdaterInstaller.parseVerification(verifyResult.stdoutString, platform: context.platform)
                self.serviceVersion = status.helperProtocol == 1 ? "v1 (Installed)" : "Unknown"
                self.isRunning = status.serviceActive
            }
        } catch {
            self.error = error.localizedDescription
        }
        await connection.disconnect()
    }
}
