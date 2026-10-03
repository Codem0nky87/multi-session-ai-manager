import re

with open("app/MultiSessionAIManager/Core/HerdrHostSession.swift", "r") as f:
    code = f.read()

code = code.replace(
    'let cmd = isWindows ? "powershell -ExecutionPolicy Bypass -File \\"$env:USERPROFILE\\\\.local\\\\bin\\\\msam-metrics.ps1\\" --loop" : "$HOME/.local/bin/msam-metrics --loop"',
    'let cmd = isWindows ? "powershell -ExecutionPolicy Bypass -Command \\"& \\\\\\"$env:USERPROFILE\\\\.local\\\\bin\\\\msam-metrics.ps1\\\\\\" -loop\\"" : "$HOME/.local/bin/msam-metrics --loop"'
)

with open("app/MultiSessionAIManager/Core/HerdrHostSession.swift", "w") as f:
    f.write(code)
