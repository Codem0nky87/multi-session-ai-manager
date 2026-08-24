import Foundation

enum POSIXShell {
    /// Quote one value for a POSIX shell without allowing interpolation,
    /// substitution, globbing, or command separators to escape the argument.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

struct SSHCommandRequest: Equatable, Sendable {
    let command: String
    let timeout: Duration
    let outputLimit: Int
}

struct SSHCommandResult: Equatable, Sendable {
    let exitStatus: Int32
    let stdout: Data
    let stderr: Data

    var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
    var stderrString: String { String(decoding: stderr, as: UTF8.self) }
}

enum SSHCommandExecutionError: Error, Equatable, Sendable {
    case invalidRequest
    case timedOut
    case cancelled
    case outputLimitExceeded(limit: Int)
    /// The exec channel ended before a definite remote exit status arrived.
    /// A caller must not assume a mutating command did or did not run.
    case ambiguousDisconnect
}

/// Key material handed to a transport, NIO-agnostic. The real transport builds
/// whatever nio-ssh type it needs from the raw ed25519 seed.
struct SSHKeyMaterial: Equatable {
    let ed25519Seed: Data   // 32-byte CryptoKit rawRepresentation
}

/// Errors surfaced by any SSHTransport implementation.
enum SSHTransportError: Error {
    case notConnected
    case hostKeyRejected
    case commandFailed(String)
}

/// An interactive pseudo-terminal channel.
protocol PTYChannel: AnyObject {
    /// Whether the client-side PTY stream is still open.
    var isOpen: Bool { get }
    func send(_ data: Data)
    func resize(cols: Int, rows: Int)
    func close()
}

/// One raw TCP stream carried by an SSH `direct-tcpip` child channel.
protocol DirectTCPIPChannel: AnyObject, Sendable {
    func send(_ data: Data)
    func close()
}

/// One SSH connection to one host. Implementations provide real and test seams.
protocol SSHTransport: AnyObject, Sendable {
    /// Connect + authenticate. `hostKeyValidator` is called with the server key's
    /// SHA256 fingerprint (base64, no padding) and returns true to accept.
    /// `@Sendable` because the real transport invokes it from a nio EventLoop
    /// (off the main thread) inside the host-key validation callback.
    func connect(host: Host, key: SSHKeyMaterial,
                 hostKeyValidator: @escaping @Sendable (String) -> Bool) async throws
    /// Run a non-interactive command, return combined stdout as a String.
    func runCommand(_ cmd: String) async throws -> String
    /// Run one bounded command and retain stdout/stderr plus a definite exit
    /// status. Real transports override this at their streaming boundary.
    func runCommand(_ request: SSHCommandRequest) async throws -> SSHCommandResult
    /// Open an interactive PTY running `command`, delivering output bytes to `onOutput`.
    /// `onOutput` is `@Sendable` because the real transport delivers bytes on a
    /// nio EventLoop (off the main thread). The UI bridge hops to main itself.
    func openPTY(command: String, cols: Int, rows: Int,
                 onOutput: @escaping @Sendable (Data) -> Void) async throws -> PTYChannel
    /// Open a raw TCP connection FROM the SSH server to `targetHost:targetPort`
    /// on this already-authenticated SSH connection.
    func openDirectTCPIP(
        targetHost: String,
        targetPort: Int,
        onOutput: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) async throws -> any DirectTCPIPChannel
    /// Write `data` to an absolute path on the host over SFTP, on THIS
    /// already-authenticated connection. Riding the existing connection rather
    /// than dialling a second one keeps the upload on the same host key the
    /// user already accepted, and costs no extra authentication.
    func writeFile(_ data: Data, to path: String) async throws
    /// Read a file from the host over SFTP on THIS connection.
    func readFile(at path: String) async throws -> Data
    /// Size in bytes, WITHOUT reading the file. Checked before `readFile` so a
    /// multi-gigabyte log is refused rather than pulled onto an iPad.
    func fileSize(at path: String) async throws -> Int
    func disconnect() async
}

/// Preserve compatibility for specialized transports that do not offer tunnelling
/// (for example a probe-only test double). The real and general fake transports
/// override this; callers receive an explicit disabled/error state, never fake success.
extension SSHTransport {
    func runCommand(_ request: SSHCommandRequest) async throws -> SSHCommandResult {
        guard !request.command.isEmpty,
              request.outputLimit > 0,
              request.timeout > .zero else {
            throw SSHCommandExecutionError.invalidRequest
        }
        do {
            return try await SSHCommandDeadline.run(timeout: request.timeout) {
                let value = try await self.runCommand(request.command)
                let bytes = Data(value.utf8)
                guard bytes.count <= request.outputLimit else {
                    throw SSHCommandExecutionError.outputLimitExceeded(
                        limit: request.outputLimit
                    )
                }
                return SSHCommandResult(
                    exitStatus: 0,
                    stdout: bytes,
                    stderr: Data()
                )
            }
        } catch is CancellationError {
            throw SSHCommandExecutionError.cancelled
        } catch let error as SSHCommandExecutionError {
            throw error
        } catch {
            throw SSHCommandExecutionError.ambiguousDisconnect
        }
    }

    func openDirectTCPIP(
        targetHost: String,
        targetPort: Int,
        onOutput: @escaping @Sendable (Data) -> Void,
        onClose: @escaping @Sendable () -> Void
    ) async throws -> any DirectTCPIPChannel {
        throw SSHTransportError.commandFailed("direct-tcpip is not supported by this transport")
    }

    func writeFile(_ data: Data, to path: String) async throws {
        throw SSHTransportError.commandFailed("file upload is not supported by this transport")
    }

    func readFile(at path: String) async throws -> Data {
        throw SSHTransportError.commandFailed("file download is not supported by this transport")
    }

    func fileSize(at path: String) async throws -> Int {
        throw SSHTransportError.commandFailed("file download is not supported by this transport")
    }
}
