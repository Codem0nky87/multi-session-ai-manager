import Foundation

enum WindowsShell {
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func command(_ script: String) -> String {
        // sshd and SCM can retain the machine PATH from before a user install.
        let environment = """
        $ProgressPreference='SilentlyContinue';
        $env:PATH=[Environment]::GetEnvironmentVariable('Path','User')+';'+$env:USERPROFILE+'/.local/bin;'+$env:USERPROFILE+'/.cargo/bin;'+$env:USERPROFILE+'/AppData/Local/agy/bin;'+$env:USERPROFILE+'/.herdr/bin;'+$env:PATH;
        [Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false);
        """
        let encoded = Data((environment + "\n" + script).utf16.flatMap { [UInt8($0 & 255), UInt8($0 >> 8)] }).base64EncodedString()
        return "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand " + encoded
    }

    static func wrapping(_ command: String) -> String {
        command.hasPrefix("powershell.exe ") ? command : Self.command(command + "; exit $LASTEXITCODE")
    }
}
