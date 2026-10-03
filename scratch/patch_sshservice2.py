import re

with open("app/MultiSessionAIManager/Core/SSHService.swift", "r") as f:
    code = f.read()

# Add isWindows property
code = re.sub(
    r'(let knownHosts: KnownHostsStore\n)',
    r'\1    var isWindows: Bool = false\n',
    code
)

# Detect OS in connect
connect_replacement = """
    func connect(
        key: SSHKeyMaterial,
        confirmUntrusted: @escaping @Sendable (String, HostKeyVerdict) -> Bool
    ) async throws {
        let knownHostsKey = host.knownHostsKey
        let knownHosts = self.knownHosts
        try await transport.connect(host: host, key: key) { fingerprint in
            let verdict = knownHosts.verify(host: knownHostsKey, fingerprint: fingerprint)
            switch verdict {
            case .match:
                return true
            case .trustedNew:
                guard confirmUntrusted(fingerprint, .trustedNew) else { return false }
                knownHosts.pin(host: knownHostsKey, fingerprint: fingerprint)
                return true
            case .mismatch:
                guard confirmUntrusted(fingerprint, .mismatch) else { return false }
                knownHosts.pin(host: knownHostsKey, fingerprint: fingerprint)
                return true
            }
        }
        
        let probe = try? await transport.runCommand(.init(command: "echo %OS%", timeout: .seconds(3), outputLimit: 1024))
        self.isWindows = probe?.stdoutString.contains("Windows_NT") ?? false
    }
"""
code = re.sub(r'    func connect\([^}]+\) async throws \{.*?(?=\n    func runCommand)', connect_replacement.strip('\n'), code, flags=re.DOTALL)

# Modify run method
run_replacement = """    func run(
        _ command: String,
        timeout: Duration,
        outputLimit: Int
    ) async throws -> SSHCommandResult {
        let shellCmd = isWindows ? command : Self.provisioningShellCommand(command)
        return try await transport.runCommand(.init(
            command: shellCmd,
            timeout: timeout,
            outputLimit: outputLimit
        ))
    }"""
code = re.sub(r'    func run\([^}]+\) async throws -> SSHCommandResult \{.*?(?=\n    \})', run_replacement.strip('\n') + '\n', code, flags=re.DOTALL)

with open("app/MultiSessionAIManager/Core/SSHService.swift", "w") as f:
    f.write(code)
