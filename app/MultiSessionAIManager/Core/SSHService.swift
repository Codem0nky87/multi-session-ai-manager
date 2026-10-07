import Foundation

/// Owns one SSH transport and centralizes host-key verification plus shell-safe
/// command execution. Herdr provisioning and private forwarding use this seam;
/// terminal panes themselves use Herdr's REST/WebSocket protocol.
final class SSHService: @unchecked Sendable {
    static func loginShellCommand(_ command: String) -> String {
        shellCommand(command, flags: "-lic")
    }

    static func probeShellCommand(_ command: String) -> String {
        shellCommand(command, flags: "-lc")
    }

    /// Provisioning uses a non-interactive login shell for the host's normal
    /// PATH while retaining stderr for structured diagnostics. The managed
    /// installers write into ~/.local/bin, so include that location explicitly
    /// even when a host's login profile omits it.
    static func provisioningShellCommand(_ command: String) -> String {
        let command = "PATH=\"$HOME/.local/bin:$PATH\"; export PATH; \(command)"
        return "$SHELL -lc \(POSIXShell.quote(command))"
    }

    private static func shellCommand(_ command: String, flags: String) -> String {
        "$SHELL \(flags) \(quote(command)) 2>/dev/null"
    }

    private static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    let host: Host
    private let transport: SSHTransport
    private let knownHosts: KnownHostsStore
    var isWindows: Bool = false

    init(host: Host, transport: SSHTransport, knownHosts: KnownHostsStore) {
        self.host = host
        self.transport = transport
        self.knownHosts = knownHosts
    }

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
        
        // CMD expands %OS%; PowerShell expands $env:OS. POSIX shells leave
        // these without Windows_NT, including WSL where cmd.exe may exist.
        let probe = try? await transport.runCommand(.init(command: "echo %OS% $env:OS", timeout: .seconds(3), outputLimit: 1024))
        self.isWindows = probe?.stdoutString.contains("Windows_NT") ?? false
    }
    func runCommand(_ command: String) async throws -> String {
        let shellCmd = isWindows ? WindowsShell.wrapping(command) : Self.loginShellCommand(command)
        return try await transport.runCommand(shellCmd)
    }

    /// Cheapest possible round trip on this connection: liveness proof and
    /// NAT-refreshing keepalive traffic in one. Raw exec, no login shell --
    /// the probe must not depend on the host's profile, and it must stay
    /// small enough to run on a heartbeat.
    func ping(timeout: Duration) async throws {
        _ = try await transport.runCommand(.init(
            command: isWindows ? "cmd /c exit 0" : "true",
            timeout: timeout,
            outputLimit: 1024
        ))
    }

    func run(
        _ command: String,
        timeout: Duration,
        outputLimit: Int
    ) async throws -> SSHCommandResult {
        let shellCmd = isWindows ? WindowsShell.wrapping(command) : Self.provisioningShellCommand(command)
        return try await transport.runCommand(.init(
            command: shellCmd,
            timeout: timeout,
            outputLimit: outputLimit
        ))
    }

    /// Bounded exec for commands that supply their own shell and do not need
    /// the user's login profile (for example, directory browsing).
    func runRaw(_ command: String, timeout: Duration, outputLimit: Int) async throws -> SSHCommandResult {
        try await transport.runCommand(.init(command: command, timeout: timeout, outputLimit: outputLimit))
    }


    /// Upload bytes to an absolute remote path on this connection. Used by
    /// `RemoteFileUpload`; deliberately takes an absolute path, because the
    /// caller also types that path into a pane whose cwd it cannot see.
    func writeFile(_ data: Data, to path: String) async throws {
        try await transport.transferFile(data, to: path, isWindows: isWindows)
    }

    func writeSetupFile(_ data: Data, to path: String, permissions: UInt16 = 0o600) async throws {
        try await transport.writeSetupFile(data, to: path, permissions: permissions, isWindows: isWindows)
    }

    /// Download a file from an absolute remote path on this connection.
    func readFile(at path: String) async throws -> Data {
        try await transport.receiveFile(at: path, isWindows: isWindows)
    }

    /// Size of a remote file without reading it.
    func fileSize(at path: String) async throws -> Int {
        try await transport.transferFileSize(at: path, isWindows: isWindows)
    }

    func openPTY(
        command: String,
        cols: Int,
        rows: Int,
        onOutput: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) async throws -> PTYChannel {
        try await transport.openPTY(
            command: command,
            cols: cols,
            rows: rows,
            onOutput: onOutput,
            onClose: onClose
        )
    }

    func openExecStream(command: String,
                        onOutput: @escaping @Sendable (Data) -> Void) async throws -> PTYChannel {
        try await transport.openExecStream(command: command, onOutput: onOutput, onClose: {})
    }

    func openPTY(
        command: String,
        cols: Int,
        rows: Int,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> PTYChannel {
        try await openPTY(
            command: command,
            cols: cols,
            rows: rows,
            onOutput: onOutput,
            onClose: {}
        )
    }

    func openDirectTCPIP(
        targetHost: String,
        targetPort: Int,
        onOutput: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) async throws -> any DirectTCPIPChannel {
        try await transport.openDirectTCPIP(
            targetHost: targetHost,
            targetPort: targetPort,
            onOutput: onOutput,
            onClose: onClose
        )
    }

    func disconnect() async {
        await transport.disconnect()
    }
}
