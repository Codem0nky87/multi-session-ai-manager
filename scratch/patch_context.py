import re

with open("app/MultiSessionAIManager/Core/AgentUpdaterInstaller.swift", "r") as f:
    code = f.read()

replacement = """    nonisolated static func contextCommand(isWindows: Bool) -> String {
        if isWindows {
            return "Write-Host \\"MSAM_HOME=$env:USERPROFILE\\"; Write-Host \\"MSAM_OS=Windows_NT\\"; Write-Host \\"MSAM_UID=0\\""
        } else {
            return \"\"\"
            printf 'MSAM_HOME=%s\\\\n' "$HOME"
            printf 'MSAM_OS=%s\\\\n' "$(uname -s 2>/dev/null || printf unknown)"
            printf 'MSAM_UID=%s\\\\n' "$(id -u 2>/dev/null || printf invalid)"
            \"\"\"
        }
    }"""

code = re.sub(r'    nonisolated static let contextCommand = """\n.*?    """', replacement, code, flags=re.DOTALL)

code = code.replace("Self.contextCommand", "Self.contextCommand(isWindows: requireService().isWindows)")

with open("app/MultiSessionAIManager/Core/AgentUpdaterInstaller.swift", "w") as f:
    f.write(code)
