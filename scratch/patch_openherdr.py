import re

with open("app/MultiSessionAIManager/Core/HostConnection.swift", "r") as f:
    code = f.read()

replacement = """    func openHerdrPTY(
        sessionName: String?,
        cols: Int,
        rows: Int,
        onOutput: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) async throws -> PTYChannel {
        guard state == .connected else { throw PTYUnavailable() }
        let isWindows = service.isWindows
        let cmd = isWindows ? "powershell.exe" : HerdrLaunchCommand.launch(sessionName: sessionName)
        return try await service.openPTY(
            command: cmd,
            cols: cols,
            rows: rows,
            onOutput: onOutput,
            onClose: onClose
        )
    }"""

code = re.sub(r'    func openHerdrPTY\(\n        sessionName: String\?,\n        cols: Int,\n        rows: Int,\n        onOutput: @escaping @Sendable \(Data\) -> Void,\n        onClose: @escaping @Sendable \(\) -> Void\n    \) async throws -> PTYChannel \{\n        guard state == \.connected else \{ throw PTYUnavailable\(\) \}\n        return try await service\.openPTY\(\n            command: HerdrLaunchCommand\.launch\(sessionName: sessionName\),\n            cols: cols,\n            rows: rows,\n            onOutput: onOutput,\n            onClose: onClose\n        \)\n    \}', replacement, code, flags=re.DOTALL)

with open("app/MultiSessionAIManager/Core/HostConnection.swift", "w") as f:
    f.write(code)
