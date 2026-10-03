import re

with open("app/MultiSessionAIManager/Core/SSHService.swift", "r") as f:
    code = f.read()

replacement = """    func runCommand(_ command: String) async throws -> String {
        let shellCmd = isWindows ? command : Self.loginShellCommand(command)
        return try await transport.runCommand(shellCmd)
    }"""
code = re.sub(r'    func runCommand\(_ command: String\) async throws -> String \{\n        try await transport.runCommand\(Self.loginShellCommand\(command\)\)\n    \}', replacement, code, flags=re.DOTALL)

with open("app/MultiSessionAIManager/Core/SSHService.swift", "w") as f:
    f.write(code)
