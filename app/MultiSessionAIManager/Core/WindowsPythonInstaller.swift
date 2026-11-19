import Foundation
import Observation

/// How Python gets onto a Windows host.
struct WindowsPythonPlan: Equatable, Sendable {
    /// Shown to the user and sent to the host, so that what is promised and
    /// what is done cannot differ. Nil when the host has nothing to install
    /// Python with and it has to be done at the host itself.
    let command: String?
    let explanation: String
}

/// Python 3 on a Windows host. The host service is written in Python, and
/// Windows, unlike macOS and Linux, does not come with it.
@MainActor
@Observable
final class WindowsPythonInstaller {
    enum State: Equatable {
        case idle
        case probing
        case ready(version: String)
        case absent(WindowsPythonPlan)
        case installing(WindowsPythonPlan)
        /// The plan stays with a failure: its command can still be run at the host.
        case failed(String, WindowsPythonPlan?)
    }

    /// What a host answers when asked about Python.
    struct Probe: Equatable, Sendable {
        /// The version of the Python the host service would be run with.
        let version: String?
        let isServer: Bool
        let hasStore: Bool
        let hasWinget: Bool

        /// The version, if the host service can run on it.
        var usableVersion: String? {
            guard let version else { return nil }
            let parts = version.split(separator: ".").map { Int($0) ?? 0 }
            let major = parts.first ?? 0, minor = parts.count > 1 ? parts[1] : 0
            return (major, minor) >= WindowsPythonInstaller.minimumVersion ? version : nil
        }
    }

    nonisolated static let minimumVersion = (3, 9)

    /// A Windows client gets Python from the Microsoft Store, as python.org
    /// documents it: the install manager first, then the current Python with it.
    nonisolated static let storeCommand = """
        winget install 9NQ7512CXL7T -e --source msstore --accept-source-agreements --accept-package-agreements --disable-interactivity
        py install default
        """
    /// A server, or a client without the Store, gets it for every account.
    nonisolated static let machineCommand =
        "winget install --id Python.Python.3.14 -e --scope machine --source winget --accept-source-agreements --accept-package-agreements --disable-interactivity"

    nonisolated static let storeExplanation =
        "Python 3 is not installed on this host. The host service needs it; on this edition of Windows it comes from the Microsoft Store."
    nonisolated static let machineExplanation =
        "Python 3 is not installed on this host. The host service needs it; winget installs it for every account on the host."
    nonisolated static let manualExplanation =
        "Python 3 is not installed on this host, and the host has no winget to install it with. "
        + "At the host, install Python 3.14 from python.org for all users and add it to PATH, then check again."

    /// Reports the Python the host service would use, and what the host could
    /// install one with. It looks for Python the way `HostServiceInstaller.python`
    /// runs it. Windows keeps a `python.exe` that only points at the Store; it
    /// prints no version, so it is not taken for Python.
    nonisolated static let probeScript = """
        $ErrorActionPreference='SilentlyContinue'
        $version=''
        $py=Get-Command py.exe
        $found=if ($py) { & $py.Source -3 --version 2>$null } elseif (Get-Command python.exe) { & python.exe --version 2>$null }
        if ("$found" -match 'Python (\\d+\\.\\d+\\.\\d+)') { $version=$Matches[1] }
        'MSAM_PYTHON='+$version
        'MSAM_WINDOWS='+$(if ((Get-CimInstance Win32_OperatingSystem).ProductType -eq 1) { 'client' } else { 'server' })
        'MSAM_STORE='+$(if (Get-AppxPackage -Name Microsoft.WindowsStore) { 'yes' } else { 'no' })
        'MSAM_WINGET='+$(if (Get-Command winget.exe) { 'yes' } else { 'no' })
        exit 0
        """

    /// A host that leaves something unsaid is treated as the plainest kind: a
    /// server with nothing on it.
    nonisolated static func parse(_ output: String) -> Probe {
        var fields: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0].hasPrefix("MSAM_") else { continue }
            fields[String(pair[0])] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        let version = fields["MSAM_PYTHON"].flatMap { $0.isEmpty ? nil : $0 }
        return Probe(version: version, isServer: fields["MSAM_WINDOWS"] != "client",
                     hasStore: fields["MSAM_STORE"] == "yes", hasWinget: fields["MSAM_WINGET"] == "yes")
    }

    nonisolated static func plan(for probe: Probe) -> WindowsPythonPlan {
        let plan: WindowsPythonPlan
        if !probe.hasWinget {
            plan = .init(command: nil, explanation: manualExplanation)
        } else if !probe.isServer && probe.hasStore {
            plan = .init(command: storeCommand, explanation: storeExplanation)
        } else {
            plan = .init(command: machineCommand, explanation: machineExplanation)
        }
        guard let old = probe.version else { return plan }
        let needed = "\(minimumVersion.0).\(minimumVersion.1)"
        return .init(command: plan.command, explanation: plan.explanation.replacingOccurrences(
            of: "Python 3 is not installed on this host",
            with: "Python \(old) on this host is too old (\(needed) or newer is needed)"))
    }

    private static let probeTimeout = Duration.seconds(45)
    /// A download of some 30 MB and an installer, on a host that may be slow.
    private static let installTimeout = Duration.seconds(900)
    private static let outputLimit = 256 * 1024

    let connection: HostConnection
    private(set) var state: State = .idle

    init(connection: HostConnection) {
        self.connection = connection
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    /// The plan on offer, if there is one to act on.
    var plan: WindowsPythonPlan? {
        switch state {
        case .absent(let plan), .installing(let plan): plan
        case .failed(_, let plan): plan
        default: nil
        }
    }

    var canInstall: Bool {
        if case .installing = state { return false }
        return plan?.command != nil
    }

    /// Reports what is on the host without changing anything.
    func probe() async {
        state = .probing
        do {
            let probe = try await ask()
            state = probe.usableVersion.map { .ready(version: $0) } ?? .absent(Self.plan(for: probe))
        } catch {
            state = .failed(Self.message(for: error), nil)
        }
    }

    func install() async {
        guard canInstall, let plan, let command = plan.command else { return }
        state = .installing(plan)
        // As with Herdr, what the installer reports is not what decides: the
        // channel can close before its result arrives, and winget can report a
        // failure for a Python that is in place. Only the host's answer counts.
        var output = ""
        var failure: (any Error)?
        do {
            let result = try await run(command, timeout: Self.installTimeout)
            output = Self.said(result)
        } catch {
            failure = error
        }
        do {
            let probe = try await ask()
            if let version = probe.usableVersion {
                state = .ready(version: version)
            } else if let failure {
                state = .failed(Self.message(for: failure), Self.plan(for: probe))
            } else {
                let detail = output.isEmpty ? "" : " The host said: \(output)"
                state = .failed("Python is still not installed after running the installer.\(detail)", Self.plan(for: probe))
            }
        } catch {
            state = .failed(Self.message(for: failure ?? error), plan)
        }
    }

    private func ask() async throws -> Probe {
        Self.parse(try await run(Self.probeScript, timeout: Self.probeTimeout).stdoutString)
    }

    private func run(_ command: String, timeout: Duration) async throws -> SSHCommandResult {
        guard let service = connection.provisioningCommandRunner else {
            throw HostConnection.PTYUnavailable()
        }
        return try await service.run(command, timeout: timeout, outputLimit: Self.outputLimit)
    }

    /// The end of what an installer printed, without the progress it drew.
    nonisolated static func said(_ result: SSHCommandResult) -> String {
        let lines = (result.stdoutString + "\n" + result.stderrString)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in line.contains(where: \.isLetter) }
        return String(lines.suffix(6).joined(separator: " ").suffix(600))
    }

    private static func message(for error: Error) -> String {
        if error is HostConnection.PTYUnavailable {
            return "Connect and authenticate SSH to this host first."
        }
        switch error as? SSHCommandExecutionError {
        case .timedOut:
            return "The host did not finish installing Python in time. Check again: if it did finish, the check will find it."
        case .ambiguousDisconnect:
            return "The connection ended before the host reported a result, so Python may or may not be installed. Check again."
        case .cancelled:
            return "Cancelled."
        case .outputLimitExceeded:
            return "The host produced more output than expected."
        case .invalidRequest:
            return "Invalid command."
        case nil:
            return SSHFailure.classify(message: String(describing: error)).userMessage
        }
    }
}
