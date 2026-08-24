import Foundation
import Observation

/// Installs or updates Herdr on a remote host over an already-authenticated SSH
/// connection.
///
/// The app deliberately does not detect the host's platform or architecture:
/// Herdr's official install script does that itself, so the only thing shipped
/// here is the decision of *whether* to run it and the verification of what it
/// produced. Every command is bounded (timeout + output limit) so an
/// unresponsive host cannot stall the sheet.
///
/// Trust boundary: `install()` pipes a remote script to a shell. That is Herdr's
/// documented installation method and it runs as the connecting user on a host
/// the user owns, but it is the highest-privilege action in this app — hence the
/// probe-then-confirm flow, and hence `installCommand` being the single source
/// of the string both shown to the user and sent to the host.
@MainActor
@Observable
final class HerdrInstaller {
    enum State: Equatable {
        case idle
        case probing
        /// Herdr is not installed. `curlAvailable` gates whether install is even offerable.
        case absent(curlAvailable: Bool)
        case present(version: String)
        case installing
        case ready(version: String)
        case failed(String)
    }

    /// The app requires 0.8.2 or newer; anything older is reported as a failure
    /// rather than a successful install.
    static let minimumVersion = "0.8.2"

    /// Shown in the UI *and* sent to the host — one constant so the promise and
    /// the action cannot drift apart.
    static let installCommand = "curl -fsSL https://herdr.dev/install.sh | sh"
    static let updateCommand = "herdr update"

    private static let probeTimeout = Duration.seconds(15)
    /// Exposed so the live diagnostic runs the same budget the app does.
    static var probeTimeoutForDiagnostics: Duration { probeTimeout }
    /// Generous on purpose. Herdr's installer allows 20s for the release
    /// manifest plus 120s per binary download, and retries the download up to
    /// three times — so the script alone can legitimately run for six minutes
    /// before any network latency to the host. A budget that expires mid-install
    /// is worse than a slow one: the transport cannot tell a cancelled channel
    /// from a dropped one, so an early deadline surfaces as "the connection
    /// dropped" and hides the real cause.
    static let installTimeout = Duration.seconds(600)
    private static let outputLimit = 64 * 1024

    let connection: HostConnection
    private(set) var state: State = .idle

    init(connection: HostConnection) {
        self.connection = connection
    }

    /// True only when Herdr is absent *and* the host can actually fetch the script.
    var canInstall: Bool {
        if case .absent(let curlAvailable) = state { return curlAvailable }
        return false
    }

    var canUpdate: Bool {
        if case .present = state { return true }
        return false
    }

    // MARK: - Version handling

    /// Extracts the version from `herdr --version` output (`herdr 0.8.2`).
    static func parseVersion(_ output: String) -> String? {
        for field in output.split(whereSeparator: \.isWhitespace) {
            let candidate = String(field)
            let parts = candidate.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
            else { continue }
            return candidate
        }
        return nil
    }

    /// Numeric comparison — a lexical one would rank `0.10.0` below `0.8.2`.
    static func meetsMinimum(_ version: String) -> Bool {
        func components(_ value: String) -> [Int] {
            value.split(separator: ".").map { Int($0) ?? 0 }
        }
        let lhs = components(version)
        let rhs = components(minimumVersion)
        for index in 0..<max(lhs.count, rhs.count) {
            let l = index < lhs.count ? lhs[index] : 0
            let r = index < rhs.count ? rhs[index] : 0
            if l != r { return l > r }
        }
        return true
    }

    // MARK: - Operations

    /// Reports what is on the host without changing anything.
    func probe() async {
        state = .probing
        do {
            let herdr = try await run(
                "command -v herdr >/dev/null 2>&1 && herdr --version",
                timeout: Self.probeTimeout
            )
            if let version = Self.parseVersion(herdr.stdoutString) {
                state = .present(version: version)
                return
            }
            let curl = try await run("command -v curl", timeout: Self.probeTimeout)
            let curlAvailable = !curl.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            state = .absent(curlAvailable: curlAvailable)
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    func install() async {
        await perform(Self.installCommand)
    }

    func update() async {
        await perform(Self.updateCommand)
    }

    private func perform(_ command: String) async {
        state = .installing

        // The install command's outcome is never trusted, in EITHER direction.
        //
        // Citadel's exec path does not reliably surface a remote exit status --
        // the stream simply ends and the channel closes -- so a failed command
        // can report 0. Less obviously, the reverse also happens: the installer
        // pulls a ~22 MB binary, and over a slow link (a WARP tunnel, a phone
        // connection) the channel can close before Citadel sees a clean finish,
        // so `run` THROWS while the installer on the host ran to completion.
        //
        // Treating that throw as failure is what made a host report "Herdr did
        // not install" with Herdr sitting installed on it. So a throw here is
        // recorded and verification runs anyway; only the host's own answer
        // decides.
        var installOutput = ""
        var installFailure: (any Error)?
        do {
            installOutput = Self.combinedOutput(try await run(command, timeout: Self.installTimeout))
        } catch {
            installFailure = error
        }

        let verify: SSHCommandResult
        do {
            verify = try await run("herdr --version", timeout: Self.probeTimeout)
        } catch {
            // Could not ask the host at all. If the install already failed, that
            // is the more useful error to report.
            state = .failed(Self.message(for: installFailure ?? error))
            return
        }

        guard let version = Self.parseVersion(verify.stdoutString) else {
            if let installFailure {
                state = .failed(Self.message(for: installFailure))
            } else {
                state = .failed(
                    installOutput.isEmpty
                        ? "Herdr is still not installed after running the installer."
                        : "Herdr is still not installed after running the installer. \(installOutput)"
                )
            }
            return
        }
        guard Self.meetsMinimum(version) else {
            state = .failed(
                "Installed Herdr \(version), but this app requires \(Self.minimumVersion) or newer."
            )
            return
        }
        state = .ready(version: version)
    }

    // MARK: - Plumbing

    private func run(_ command: String, timeout: Duration) async throws -> SSHCommandResult {
        guard let service = connection.provisioningCommandRunner else {
            throw HostConnection.PTYUnavailable()
        }
        return try await service.run(command, timeout: timeout, outputLimit: Self.outputLimit)
    }

    private static func combinedOutput(_ result: SSHCommandResult) -> String {
        let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        let stdout = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderr.isEmpty { return stderr }
        if !stdout.isEmpty { return stdout }
        return "Command exited with status \(result.exitStatus)."
    }

    private static func message(for error: Error) -> String {
        if error is HostConnection.PTYUnavailable {
            return "Connect and authenticate SSH to this host first."
        }
        if let execution = error as? SSHCommandExecutionError {
            switch execution {
            case .timedOut:
                return "The host did not finish installing in time. Tap Try again — if it did finish, the check will find it."
            case .cancelled: return "Cancelled."
            case .outputLimitExceeded: return "The host produced more output than expected."
            case .ambiguousDisconnect:
                // The transport cannot distinguish a dropped channel from one it
                // cancelled at the deadline, so never assert which happened — and
                // never imply the install failed, because it may have succeeded.
                return "The connection ended before Herdr reported a result, so the install may or may not have completed. Tap Try again to check the host."
            case .invalidRequest: return "Invalid command."
            }
        }
        return SSHFailure.classify(message: String(describing: error)).userMessage
    }
}
