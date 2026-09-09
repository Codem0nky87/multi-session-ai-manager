import Foundation
import Observation

/// One native conversation-restore integration supported by Herdr 0.8.2.
///
/// These values are compiled into the app rather than learned from the host.
/// Besides keeping the UI stable, that makes every command this feature emits
/// independent of untrusted remote output.
struct HerdrIntegrationTarget: Equatable, Hashable, Identifiable, Sendable {
    let displayName: String
    let herdrTarget: String
    let executableAliases: [String]

    var id: String { herdrTarget }
}

enum HerdrIntegrationStatus: Equatable, Sendable {
    case current(version: String?)
    case notInstalled
    case outdated(versions: String?)
    case needsRepair(version: String?)
    /// The agent was detected, but Herdr did not report a state this version of
    /// the app understands. Unknown is deliberately not treated as current.
    case unknown

    var isCurrent: Bool {
        if case .current = self { return true }
        return false
    }

    var needsProvisioning: Bool {
        switch self {
        case .notInstalled, .outdated, .needsRepair:
            return true
        case .current, .unknown:
            return false
        }
    }

    var displayText: String {
        switch self {
        case .current(let version):
            return version.map { "Ready (\($0))" } ?? "Ready"
        case .notInstalled:
            return "Not enabled"
        case .outdated(let versions):
            return versions.map { "Update needed (\($0))" } ?? "Update needed"
        case .needsRepair(let version):
            return version.map { "Repair needed (\($0))" } ?? "Repair needed"
        case .unknown:
            return "Status unavailable"
        }
    }
}

struct HerdrAgentIntegration: Equatable, Identifiable, Sendable {
    let target: HerdrIntegrationTarget
    let status: HerdrIntegrationStatus

    var id: String { target.id }
}

struct HerdrIntegrationFailure: Equatable, Identifiable, Sendable {
    let herdrTarget: String
    let displayName: String
    let message: String

    var id: String { "\(herdrTarget):\(message)" }
}

enum HerdrIntegrationSummary: Equatable, Sendable {
    case idle
    case probing
    case noAgents
    case allCurrent
    case workNeeded(count: Int)
    case statusUnavailable(count: Int)
    case installing
    case partialFailure(messages: [String])
    case probeFailure(String)
}

/// Detects installed AI agents and provisions Herdr's native restore hooks over
/// the Host Setup screen's already-authenticated SSH connection.
@MainActor
@Observable
final class HerdrIntegrationManager {
    enum State: Equatable, Sendable {
        case idle
        case probing
        case ready
        case installing
        case failed(String)
    }

    private struct RemoteCommandFailure: Error {
        let exitStatus: Int32
        let output: String
    }

    nonisolated static let targets: [HerdrIntegrationTarget] = [
        .init(displayName: "Pi", herdrTarget: "pi", executableAliases: ["pi"]),
        .init(displayName: "OMP", herdrTarget: "omp", executableAliases: ["omp"]),
        .init(displayName: "Claude Code", herdrTarget: "claude", executableAliases: ["claude"]),
        .init(displayName: "Codex", herdrTarget: "codex", executableAliases: ["codex"]),
        .init(
            displayName: "GitHub Copilot", herdrTarget: "copilot", executableAliases: ["copilot"]),
        .init(displayName: "Devin", herdrTarget: "devin", executableAliases: ["devin"]),
        .init(displayName: "Droid", herdrTarget: "droid", executableAliases: ["droid"]),
        .init(displayName: "Kimi", herdrTarget: "kimi", executableAliases: ["kimi"]),
        .init(displayName: "OpenCode", herdrTarget: "opencode", executableAliases: ["opencode"]),
        .init(
            displayName: "Kilo Code", herdrTarget: "kilo", executableAliases: ["kilo", "kilo-code"]),
        .init(displayName: "Hermes", herdrTarget: "hermes", executableAliases: ["hermes"]),
        .init(displayName: "Qoder CLI", herdrTarget: "qodercli", executableAliases: ["qodercli"]),
        .init(displayName: "Qwen Code", herdrTarget: "qwen", executableAliases: ["qwen"]),
        .init(
            displayName: "Cursor Agent", herdrTarget: "cursor", executableAliases: ["cursor-agent"]),
        .init(
            displayName: "Mastra Code", herdrTarget: "mastracode", executableAliases: ["mastracode"]
        ),
        .init(
            displayName: "Antigravity CLI", herdrTarget: "antigravity-cli",
            executableAliases: ["agy", "antigravity", "antigravity-cli"]),
        .init(displayName: "Grok", herdrTarget: "grok", executableAliases: ["grok"]),
    ]

    nonisolated static let statusCommand = "herdr integration status"
    nonisolated static let detectionTimeout = Duration.seconds(30)
    nonisolated static let statusTimeout = Duration.seconds(30)
    nonisolated static let installTimeout = Duration.seconds(120)
    nonisolated static let outputLimit = 256 * 1024
    nonisolated static let maximumFailureMessageLength = 512

    /// A fixed POSIX program: every executable and marker comes from `targets`.
    nonisolated static let detectionCommand: String = targets.map { target in
        let probes = target.executableAliases
            .map { "command -v \(POSIXShell.quote($0)) >/dev/null 2>&1" }
            .joined(separator: " || ")
        let marker = POSIXShell.quote("MSAM_AGENT:\(target.herdrTarget)")
        return "if \(probes); then printf '%s\\n' \(marker); fi"
    }.joined(separator: "\n")

    let connection: HostConnection
    private(set) var state: State = .idle
    private(set) var agents: [HerdrAgentIntegration] = []
    private(set) var failures: [HerdrIntegrationFailure] = []
    private var operationGeneration: UInt64 = 0

    init(connection: HostConnection) {
        self.connection = connection
    }

    var summary: HerdrIntegrationSummary {
        Self.summary(state: state, agents: agents, failures: failures)
    }

    var canInstallOrRepair: Bool {
        state == .ready && agents.contains { $0.status.needsProvisioning }
    }

    nonisolated static func summary(
        state: State,
        agents: [HerdrAgentIntegration],
        failures: [HerdrIntegrationFailure]
    ) -> HerdrIntegrationSummary {
        switch state {
        case .idle:
            return .idle
        case .probing:
            return .probing
        case .installing:
            return .installing
        case .failed(let message):
            return .probeFailure(message)
        case .ready:
            if !failures.isEmpty {
                return .partialFailure(messages: failures.map(\.message))
            }
            if agents.isEmpty { return .noAgents }
            let workCount = agents.count { $0.status.needsProvisioning }
            if workCount > 0 { return .workNeeded(count: workCount) }
            let unavailableCount = agents.count { $0.status == .unknown }
            if unavailableCount > 0 { return .statusUnavailable(count: unavailableCount) }
            return .allCurrent
        }
    }

    /// Reports what is installed without changing the host.
    func probe() async {
        guard state != .probing, state != .installing else { return }
        operationGeneration &+= 1
        let generation = operationGeneration
        state = .probing
        failures = []

        do {
            guard let service = connection.provisioningCommandRunner else {
                throw HostConnection.PTYUnavailable()
            }
            let detected = try await Self.fetchAgents(using: service)
            guard operationGeneration == generation else { return }
            agents = detected
            state = .ready
        } catch {
            guard operationGeneration == generation else { return }
            agents = []
            state = .failed(Self.message(for: error))
        }
    }

    /// Installs or repairs every detected integration explicitly reported as
    /// missing, outdated, or needing repair, one at a time, then asks the host
    /// again. A failed agent never prevents a later one from being attempted,
    /// and command success alone is never trusted: only the final status probe
    /// decides readiness.
    func installOrRepairAll() async {
        guard canInstallOrRepair else { return }
        operationGeneration &+= 1
        let generation = operationGeneration
        let candidates = agents.filter { $0.status.needsProvisioning }
        let previousState = state
        let previousFailures = failures
        state = .installing
        failures = []

        guard !Task.isCancelled else {
            restoreAfterCancellation(
                generation: generation,
                state: previousState,
                failures: previousFailures
            )
            return
        }
        guard let service = connection.provisioningCommandRunner else {
            state = .failed(Self.message(for: HostConnection.PTYUnavailable()))
            return
        }

        var operationFailures: [HerdrIntegrationFailure] = []
        for agent in candidates {
            guard operationGeneration == generation else { return }
            guard !Task.isCancelled else {
                restoreAfterCancellation(
                    generation: generation,
                    state: previousState,
                    failures: previousFailures
                )
                return
            }
            guard
                let command = Self.installCommand(
                    forHerdrTarget: agent.target.herdrTarget
                )
            else {
                // `candidates` came from the immutable registry, so this is a
                // defensive invariant check rather than an output-derived path.
                operationFailures.append(
                    Self.failure(
                        for: agent.target,
                        message: "This app does not recognise the integration target."
                    ))
                continue
            }
            do {
                _ = try await Self.checkedRun(
                    command,
                    timeout: Self.installTimeout,
                    using: service
                )
                guard operationGeneration == generation else { return }
                guard !Task.isCancelled else {
                    restoreAfterCancellation(
                        generation: generation,
                        state: previousState,
                        failures: previousFailures
                    )
                    return
                }
            } catch {
                guard operationGeneration == generation else { return }
                guard !Task.isCancelled else {
                    restoreAfterCancellation(
                        generation: generation,
                        state: previousState,
                        failures: previousFailures
                    )
                    return
                }
                operationFailures.append(
                    Self.failure(
                        for: agent.target,
                        message: Self.message(for: error)
                    ))
            }
        }

        guard operationGeneration == generation else { return }
        guard !Task.isCancelled else {
            restoreAfterCancellation(
                generation: generation,
                state: previousState,
                failures: previousFailures
            )
            return
        }
        do {
            let refreshed = try await Self.fetchAgents(using: service)
            guard operationGeneration == generation else { return }
            guard !Task.isCancelled else {
                restoreAfterCancellation(
                    generation: generation,
                    state: previousState,
                    failures: previousFailures
                )
                return
            }

            let refreshedByTarget = Dictionary(
                uniqueKeysWithValues: refreshed.map {
                    ($0.target.herdrTarget, $0)
                })
            let verifiedCurrentTargets = Set(
                refreshed.filter(\.status.isCurrent).map(\.target.herdrTarget))
            var verificationFailures: [HerdrIntegrationFailure] = []
            for attempted in candidates {
                let verified = refreshedByTarget[attempted.target.herdrTarget]
                guard verified?.status.isCurrent == true else {
                    let detail = verified?.status.displayText ?? "Agent was no longer detected"
                    verificationFailures.append(
                        Self.failure(
                            for: attempted.target,
                            message: "Integration is still not ready: \(detail)."
                        ))
                    continue
                }
            }

            agents = refreshed
            failures =
                operationFailures.filter {
                    !verifiedCurrentTargets.contains($0.herdrTarget)
                } + verificationFailures
            state = .ready
        } catch {
            guard operationGeneration == generation else { return }
            guard !Task.isCancelled else {
                restoreAfterCancellation(
                    generation: generation,
                    state: previousState,
                    failures: previousFailures
                )
                return
            }
            failures = operationFailures
            state = .failed(
                Self.boundedFailureMessage(
                    "Could not verify integrations after installation. \(Self.message(for: error))"
                ))
        }
    }

    /// Returns a command only after matching a compiled registry target. The
    /// caller's value is never interpolated, even when it contains a valid
    /// target as a prefix.
    nonisolated static func installCommand(forHerdrTarget value: String) -> String? {
        guard let registered = targets.first(where: { $0.herdrTarget == value }) else {
            return nil
        }
        return "herdr integration install \(registered.herdrTarget)"
    }

    nonisolated static func boundedFailureMessage(_ value: String) -> String {
        guard value.count > maximumFailureMessageLength else { return value }
        return String(value.prefix(maximumFailureMessageLength - 1)) + "…"
    }

    /// Parses only the states Herdr 0.8.2 documents. Unknown target names and
    /// malformed lines are ignored; a detected target with no parsed line is
    /// surfaced separately as `.unknown` by `classify`.
    nonisolated static func parseStatuses(_ output: String) -> [String: HerdrIntegrationStatus] {
        let supported = Set(targets.map(\.herdrTarget))
        var statuses: [String: HerdrIntegrationStatus] = [:]

        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let target = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard supported.contains(target) else { continue }
            let state = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)

            if hasStatePrefix("not installed", in: state) {
                statuses[target] = .notInstalled
            } else if hasStatePrefix("current", in: state) {
                statuses[target] = .current(
                    version: parenthesizedDetail(
                        after: "current", in: state
                    ))
            } else if hasStatePrefix("outdated", in: state) {
                statuses[target] = .outdated(
                    versions: parenthesizedDetail(
                        after: "outdated", in: state
                    ))
            } else if hasStatePrefix("needs repair", in: state) {
                statuses[target] = .needsRepair(
                    version: parenthesizedDetail(
                        after: "needs repair", in: state
                    ))
            }
        }
        return statuses
    }

    nonisolated static func classify(
        detectionOutput: String,
        statusOutput: String
    ) -> [HerdrAgentIntegration] {
        let supported = Dictionary(uniqueKeysWithValues: targets.map { ($0.herdrTarget, $0) })
        let detected = Set(
            detectionOutput
                .split(whereSeparator: \.isNewline)
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .compactMap { line -> String? in
                    let prefix = "MSAM_AGENT:"
                    guard line.hasPrefix(prefix) else { return nil }
                    let target = String(line.dropFirst(prefix.count))
                    return supported[target] == nil ? nil : target
                })
        let statuses = parseStatuses(statusOutput)

        return targets.compactMap { target in
            guard detected.contains(target.herdrTarget) else { return nil }
            return HerdrAgentIntegration(
                target: target,
                status: statuses[target.herdrTarget] ?? .unknown
            )
        }
    }

    private static func fetchAgents(using service: SSHService) async throws
        -> [HerdrAgentIntegration]
    {
        let detection = try await checkedRun(
            detectionCommand,
            timeout: detectionTimeout,
            using: service
        )
        try Task.checkCancellation()
        let status = try await checkedRun(
            statusCommand,
            timeout: statusTimeout,
            using: service
        )
        return classify(
            detectionOutput: detection.stdoutString,
            statusOutput: status.stdoutString
        )
    }

    private static func checkedRun(
        _ command: String,
        timeout: Duration,
        using service: SSHService
    ) async throws -> SSHCommandResult {
        try Task.checkCancellation()
        let result = try await service.run(
            command,
            timeout: timeout,
            outputLimit: outputLimit
        )
        try Task.checkCancellation()
        guard result.exitStatus == 0 else {
            let stderr = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RemoteCommandFailure(
                exitStatus: result.exitStatus,
                output: stderr.isEmpty ? stdout : stderr
            )
        }
        return result
    }

    nonisolated private static func hasStatePrefix(_ prefix: String, in value: String) -> Bool {
        value == prefix || value.hasPrefix(prefix + " ") || value.hasPrefix(prefix + "(")
    }

    nonisolated private static func parenthesizedDetail(
        after prefix: String,
        in value: String
    ) -> String? {
        let suffix = value.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard suffix.first == "(", let close = suffix.firstIndex(of: ")") else { return nil }
        let detail = suffix[suffix.index(after: suffix.startIndex)..<close]
            .trimmingCharacters(in: .whitespaces)
        return detail.isEmpty ? nil : detail
    }

    private static func message(for error: Error) -> String {
        if error is HostConnection.PTYUnavailable {
            return "Connect and authenticate SSH to this host first."
        }
        if error is CancellationError {
            return "Cancelled."
        }
        if let command = error as? RemoteCommandFailure {
            let detail = command.output.isEmpty ? "no error output" : command.output
            return boundedFailureMessage(
                "The host command exited with status \(command.exitStatus): \(detail)"
            )
        }
        if let execution = error as? SSHCommandExecutionError {
            switch execution {
            case .timedOut:
                return "The host did not answer before the integration command timed out."
            case .cancelled:
                return "Cancelled."
            case .outputLimitExceeded:
                return "The host produced more integration output than expected."
            case .ambiguousDisconnect:
                return "The SSH connection ended before the host reported an integration result."
            case .invalidRequest:
                return "The integration check command was invalid."
            }
        }
        return SSHFailure.classify(message: String(describing: error)).userMessage
    }

    nonisolated private static func failure(
        for target: HerdrIntegrationTarget,
        message: String
    ) -> HerdrIntegrationFailure {
        HerdrIntegrationFailure(
            herdrTarget: target.herdrTarget,
            displayName: target.displayName,
            message: boundedFailureMessage("\(target.displayName): \(message)")
        )
    }

    private func restoreAfterCancellation(
        generation: UInt64,
        state: State,
        failures: [HerdrIntegrationFailure]
    ) {
        guard operationGeneration == generation else { return }
        self.state = state
        self.failures = failures
    }
}
