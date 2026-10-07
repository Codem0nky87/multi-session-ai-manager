import Foundation

/// One-shot, password-authenticated SSH helper used only to install a public key
/// onto a host. Separate from the key-only `SSHTransport` seam.
protocol KeyInstaller: AnyObject, Sendable {
    func connect(host: Host, username: String, password: String,
                 hostKeyValidator: @escaping @Sendable (String) -> Bool) async throws
    func runCommand(_ cmd: String) async throws -> String
    func disconnect() async
}

enum KeyInstallError: Error, Equatable {
    case authFailed, unreachable, installFailed(String), verifyFailed, other(String)
}

/// Shell-script helpers for key installation. A namespace enum rather than a
/// static-on-protocol extension because Swift does not permit calling a static
/// member on a protocol metatype (`(any KeyInstaller).Type`).
enum KeyInstallerScript {
    static let platformProbe = "echo %OS% $env:OS"

    static func windowsAuthorizedKeysInstallScript(publicKey: String) -> String {
        let encodedKey = Data(publicKey.utf8).base64EncodedString()
        return WindowsShell.command("""
        $ErrorActionPreference='Stop';
        $key=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('\(encodedKey)'));
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent();
        $principal=New-Object Security.Principal.WindowsPrincipal($identity);
        $admin=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator);
        $file=if ($admin) { Join-Path $env:ProgramData 'ssh/administrators_authorized_keys' } else { Join-Path $env:USERPROFILE '.ssh/authorized_keys' };
        New-Item -ItemType Directory -Force (Split-Path $file) | Out-Null;
        if (!(Test-Path $file)) { [IO.File]::WriteAllText($file,'') };
        $lines=[IO.File]::ReadAllLines($file);
        if ($lines -notcontains $key) { [IO.File]::AppendAllText($file,"`r`n"+$key+"`r`n",(New-Object Text.UTF8Encoding($false))) };
        if ($admin) { & icacls.exe $file /inheritance:r /grant:r '*S-1-5-32-544:F' '*S-1-5-18:F' | Out-Null }
        else { & icacls.exe $file /inheritance:r /grant:r ($identity.Name+':F') '*S-1-5-18:F' | Out-Null };
        if ($LASTEXITCODE -ne 0) { throw 'Could not secure the SSH authorized keys file.' };
        Write-Output 'MSAM_KEY_INSTALLED'
        """)
    }

    /// Idempotent, shell-safe command that ensures ~/.ssh exists with correct perms
    /// and appends `publicKey` to authorized_keys only if the exact line is absent.
    static func authorizedKeysInstallScript(publicKey: String) -> String {
        let q = shellSingleQuote(publicKey)
        return [
            "mkdir -p ~/.ssh",
            "chmod 700 ~/.ssh",
            "touch ~/.ssh/authorized_keys",
            "chmod 600 ~/.ssh/authorized_keys",
            "grep -qxF \(q) ~/.ssh/authorized_keys || echo \(q) >> ~/.ssh/authorized_keys",
        ].joined(separator: " && ")
    }

    static func shellSingleQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
