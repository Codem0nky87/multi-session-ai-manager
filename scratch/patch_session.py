import re

with open("app/MultiSessionAIManager/Core/HerdrHostSession.swift", "r") as f:
    code = f.read()

replacement = """    private func openMetricsCandidate(
        using service: SSHService,
        accumulator: NIOLockedValueBox<RemoteFileDownload.LineAccumulator>,
        metricsGeneration metricsAttemptGeneration: UInt64,
        sessionGeneration: UInt64
    ) async {
        do {
            try await MSAMMetricsInstaller.install(using: service)
            
            let isWindows = service.isWindows
            let cmd = isWindows ? "powershell -ExecutionPolicy Bypass -File \\"$env:USERPROFILE\\\\.local\\\\bin\\\\msam-metrics.ps1\\" --loop" : "$HOME/.local/bin/msam-metrics --loop"
            
            let candidate = try await service.openPTY(
                command: cmd,
                cols: 200,"""

code = re.sub(r'    private func openMetricsCandidate\([^}]+\) async \{\n        do \{\n            try await MSAMMetricsInstaller.install\(using: service\)\n            \n            let candidate = try await service.openPTY\(\n                command: "\$HOME/.local/bin/msam-metrics --loop",\n                cols: 200,', replacement.strip('\n'), code, flags=re.DOTALL)

with open("app/MultiSessionAIManager/Core/HerdrHostSession.swift", "w") as f:
    f.write(code)
