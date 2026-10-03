import re

with open("app/MultiSessionAIManager/UI/Hosts/HostInfoSheet.swift", "r") as f:
    code = f.read()

replacement = """    private func probeHost() async {
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
    }"""

code = re.sub(r'    private func probeHost\(\) async \{.*?\n    \}', replacement, code, flags=re.DOTALL)

with open("app/MultiSessionAIManager/UI/Hosts/HostInfoSheet.swift", "w") as f:
    f.write(code)
