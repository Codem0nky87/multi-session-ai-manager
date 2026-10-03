import re

with open("app/MultiSessionAIManager/Core/MSAMMetricsInstaller.swift", "r") as f:
    code = f.read()

replacement = """    static func install(using service: SSHService) async throws {
        let isWindows = service.isWindows
        let ext = isWindows ? "ps1" : "py"
        
        guard let scriptURL = Bundle.main.url(forResource: "msam-metrics", withExtension: ext) else {
            throw Failure.scriptNotFound
        }
        
        let scriptData: Data
        do {
            scriptData = try Data(contentsOf: scriptURL)
        } catch {
            throw Failure.uploadFailed("Could not read msam-metrics.\\(ext) from bundle: \\(error)")
        }

        let home: String
        do {
            if isWindows {
                let probe = try await service.runCommand("powershell -Command \\"if (!(Test-Path \\\\$env:USERPROFILE\\\\.local\\\\bin)) { New-Item -ItemType Directory -Force -Path \\\\$env:USERPROFILE\\\\.local\\\\bin | Out-Null }; Write-Host -NoNewline \\\\$env:USERPROFILE\\"")
                home = probe.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                let probe = try await service.run(
                    "mkdir -p \\"$HOME/.local/bin\\" && printf %s \\"$HOME\\"",
                    timeout: timeout,
                    outputLimit: outputLimit
                )
                home = probe.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            throw Failure.uploadFailed("could not prepare ~/.local/bin: \\(error)")
        }
        
        if !isWindows {
            guard home.hasPrefix("/") else {
                throw Failure.uploadFailed("the host did not report a home directory")
            }
        }

        let winPath = home + "\\\\.local\\\\bin\\\\msam-metrics.ps1"
        let posixPath = home + "/" + scriptRelativePath
        
        do {
            if isWindows {
                // write to windows path
                // SSHService.writeFile on Windows uses SFTP which uses POSIX style paths relative to home usually, or absolute
                // Actually SFTP supports absolute Windows paths if formatted properly.
                // Let's use service.writeFile and cross fingers.
                try await service.writeFile(scriptData, to: winPath.replacingOccurrences(of: "\\\\", with: "/"))
            } else {
                try await service.writeFile(scriptData, to: posixPath)
            }
        } catch {
            throw Failure.uploadFailed("\\(error)")
        }

        if !isWindows {
            do {
                _ = try await service.run("chmod 0755 \\"$HOME/\\(scriptRelativePath)\\"", timeout: timeout, outputLimit: outputLimit)
            } catch {
                throw Failure.uploadFailed("could not make script executable: \\(error)")
            }
        }
    }"""
    
code = re.sub(r'    static func install\(using service: SSHService\) async throws \{.*?(?=\n    \}\n\})', replacement.strip('\n'), code, flags=re.DOTALL)

with open("app/MultiSessionAIManager/Core/MSAMMetricsInstaller.swift", "w") as f:
    f.write(code)
