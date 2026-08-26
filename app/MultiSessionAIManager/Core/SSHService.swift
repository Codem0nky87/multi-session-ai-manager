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
    }

    func runCommand(_ command: String) async throws -> String {
        try await transport.runCommand(Self.loginShellCommand(command))
    }

    /// Cheapest possible round trip on this connection: liveness proof and
    /// NAT-refreshing keepalive traffic in one. Raw exec, no login shell --
    /// the probe must not depend on the host's profile, and it must stay
    /// small enough to run on a heartbeat.
    func ping(timeout: Duration) async throws {
        _ = try await transport.runCommand(.init(
            command: "true",
            timeout: timeout,
            outputLimit: 1024
        ))
    }

    func run(
        _ command: String,
        timeout: Duration,
        outputLimit: Int
    ) async throws -> SSHCommandResult {
        try await transport.runCommand(.init(
            command: Self.provisioningShellCommand(command),
            timeout: timeout,
            outputLimit: outputLimit
        ))
    }

    /// Upload bytes to an absolute remote path on this connection. Used by
    /// `RemoteImageUpload`; deliberately takes an absolute path, because the
    /// caller also types that path into a pane whose cwd it cannot see.
    func writeFile(_ data: Data, to path: String) async throws {
        try await transport.writeFile(data, to: path)
    }

    /// Download a file from an absolute remote path on this connection.
    func readFile(at path: String) async throws -> Data {
        try await transport.readFile(at: path)
    }

    /// Size of a remote file without reading it.
    func fileSize(at path: String) async throws -> Int {
        try await transport.fileSize(at: path)
    }

    func openPTY(
        command: String,
        cols: Int,
        rows: Int,
        onOutput: @escaping @Sendable (Data) -> Void
    ) async throws -> PTYChannel {
        try await transport.openPTY(
            command: command,
            cols: cols,
            rows: rows,
            onOutput: onOutput
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
