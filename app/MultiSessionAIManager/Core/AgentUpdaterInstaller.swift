import Foundation
import Observation

enum AgentUpdaterPlatform: Equatable, Sendable {
    case macOS
    case linux
    case unsupported(String)
}

struct AgentUpdaterHostContext: Equatable, Sendable {
    let home: String
    let platform: AgentUpdaterPlatform
    let uid: Int
}

struct AgentUpdaterServiceStatus: Equatable, Sendable {
    let platform: AgentUpdaterPlatform
    let helperProtocol: Int?
    let serviceActive: Bool
    let stateWritable: Bool
    let selfTestPassed: Bool
    let lingerEnabled: Bool?

    var isReady: Bool {
        helperProtocol == 1 && serviceActive && stateWritable && selfTestPassed
    }
}

enum AgentUpdaterApproval: Equatable, Sendable {
    case macOSLoginDomain([String])
    case linuxLingerDisabled([String])
    case administratorAction([String])
    case unsupportedPlatform(String)
}

enum AgentUpdaterInstallerError: Error, Equatable, Sendable {
    case notConnected
    case invalidHostContext
    case missingResource
    case verification(String)
}

@MainActor
@Observable
final class AgentUpdaterInstaller {
    enum State: Equatable {
        case idle
        case probing
        case absent(AgentUpdaterHostContext)
        case installing
        case approvalRequired(AgentUpdaterApproval)
        case ready(AgentUpdaterServiceStatus)
        case failed(String)
    }

    nonisolated static let serviceLabel = "com.codem0nky87.msam-agent-updater"
    nonisolated static let serviceFileName = "msam-agent-updater.service"
    nonisolated static let commandTimeout = Duration.seconds(45)
    nonisolated static let installTimeout = Duration.seconds(120)
    nonisolated static let outputLimit = 64 * 1024
    nonisolated static let contextCommand = """
        printf 'MSAM_HOME=%s\\n' "$HOME"
        printf 'MSAM_OS=%s\\n' "$(uname -s 2>/dev/null || printf unknown)"
        printf 'MSAM_UID=%s\\n' "$(id -u 2>/dev/null || printf invalid)"
        """

    let connection: HostConnection
    private let helperLoader: () throws -> Data
    private(set) var state: State = .idle
    private(set) var context: AgentUpdaterHostContext?

    init(
        connection: HostConnection,
        helperLoader: @escaping () throws -> Data = AgentUpdaterInstaller.loadBundledHelper
    ) {
        self.connection = connection
        self.helperLoader = helperLoader
    }

    func probe() async {
        state = .probing
        do {
            let context = try await discoverContext()
            self.context = context
            guard case .unsupported(let os) = context.platform else {
                let service = try requireService()
                let presence = try await service.run(
                    Self.helperPresenceCommand(for: context),
                    timeout: Self.commandTimeout,
                    outputLimit: Self.outputLimit
                )
                guard presence.exitStatus == 0 else {
                    state = .absent(context)
                    return
                }
                guard try await requireMacLoginDomainIfNeeded(context, using: service) else {
                    return
                }
                let status = try await verify(context)
                publish(status, context: context)
                return
            }
            state = .approvalRequired(.unsupportedPlatform(
                "Background agent updates are not supported on \(os). Claude Code, Codex, and Antigravity versions can still be checked manually."
            ))
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    func installOrRepair(policy _: HostGatekeeperPolicy) async {
        state = .installing
        do {
            let context = try await discoverContext()
            self.context = context
            if case .unsupported(let os) = context.platform {
                state = .approvalRequired(.unsupportedPlatform(
                    "Background agent updates are not supported on \(os). No service files were changed."
                ))
                return
            }
            let service = try requireService()
            guard try await requireMacLoginDomainIfNeeded(context, using: service) else {
                return
            }

            let helper = try helperLoader()
            guard !helper.isEmpty else { throw AgentUpdaterInstallerError.missingResource }
            _ = try await service.run(
                Self.prepareCommand(for: context),
                timeout: Self.commandTimeout,
                outputLimit: Self.outputLimit
            )
            try await service.writeFile(helper, to: Self.helperPath(for: context))
            let serviceData: Data
            switch context.platform {
            case .macOS:
                serviceData = Data(Self.launchAgent(
                    helperPath: Self.helperPath(for: context),
                    statePath: Self.statePath(for: context)
                ).utf8)
            case .linux:
                serviceData = Data(Self.systemdUnit(
                    helperPath: Self.helperPath(for: context),
                    statePath: Self.statePath(for: context)
                ).utf8)
            case .unsupported:
                return
            }
            try await service.writeFile(serviceData, to: Self.servicePath(for: context))

            var finaliseError: Error?
            do {
                _ = try await service.run(
                    Self.finaliseCommand(for: context),
                    timeout: Self.installTimeout,
                    outputLimit: Self.outputLimit
                )
            } catch {
                // A dropped exec channel is indeterminate. The capability probe
                // below, not this command result, decides whether setup worked.
                finaliseError = error
            }

            do {
                let status = try await verify(context)
                publish(status, context: context)
            } catch {
                throw finaliseError ?? error
            }
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    nonisolated static func parseHostContext(_ output: String) throws -> AgentUpdaterHostContext {
        let fields = markerFields(output, prefixes: ["MSAM_HOME", "MSAM_OS", "MSAM_UID"])
        guard let home = fields["MSAM_HOME"],
              home.hasPrefix("/"), home.utf8.count <= 1_024,
              !home.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let os = fields["MSAM_OS"],
              let uidText = fields["MSAM_UID"], let uid = Int(uidText), uid >= 0 else {
            throw AgentUpdaterInstallerError.invalidHostContext
        }
        let platform: AgentUpdaterPlatform = switch os {
        case "Darwin": .macOS
        case "Linux": .linux
        default: .unsupported(os)
        }
        return AgentUpdaterHostContext(home: home, platform: platform, uid: uid)
    }

    nonisolated static func helperPath(for context: AgentUpdaterHostContext) -> String {
        "\(context.home)/.local/libexec/msam-agent-updater"
    }

    nonisolated static func statePath(for context: AgentUpdaterHostContext) -> String {
        "\(context.home)/.local/state/msam-agent-updater"
    }

    nonisolated static func servicePath(for context: AgentUpdaterHostContext) -> String {
        switch context.platform {
        case .macOS:
            "\(context.home)/Library/LaunchAgents/\(serviceLabel).plist"
        case .linux:
            "\(context.home)/.config/systemd/user/\(serviceFileName)"
        case .unsupported:
            ""
        }
    }

    nonisolated static func launchAgent(helperPath: String, statePath: String) -> String {
        let helper = xmlEscaped(helperPath)
        let state = xmlEscaped(statePath)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key><string>\(serviceLabel)</string>
          <key>ProgramArguments</key>
          <array><string>\(helper)</string><string>service</string></array>
          <key>EnvironmentVariables</key>
          <dict><key>MSAM_AGENT_UPDATER_STATE_DIR</key><string>\(state)</string></dict>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ProcessType</key><string>Background</string>
          <key>LimitLoadToSessionType</key><string>Aqua</string>
          <key>StandardOutPath</key><string>\(state)/service.stdout.log</string>
          <key>StandardErrorPath</key><string>\(state)/service.stderr.log</string>
        </dict>
        </plist>
        """
    }

    nonisolated static func systemdUnit(helperPath: String, statePath: String) -> String {
        let helper = systemdQuoted(helperPath)
        let state = systemdQuoted(statePath)
        return """
        [Unit]
        Description=MSAM host-owned AI agent updater

        [Service]
        Type=simple
        Environment=MSAM_AGENT_UPDATER_STATE_DIR=\(state)
        ExecStart=\(helper) service
        Restart=on-failure
        RestartSec=2
        NoNewPrivileges=true

        [Install]
        WantedBy=default.target
        """
    }

    nonisolated static func prepareCommand(for context: AgentUpdaterHostContext) -> String {
        switch context.platform {
        case .macOS:
            "mkdir -p \(POSIXShell.quote(context.home + "/.local/libexec")) "
                + "\(POSIXShell.quote(context.home + "/.local/state/msam-agent-updater")) "
                + "\(POSIXShell.quote(context.home + "/Library/LaunchAgents"))"
        case .linux:
            "mkdir -p \(POSIXShell.quote(context.home + "/.local/libexec")) "
                + "\(POSIXShell.quote(context.home + "/.local/state/msam-agent-updater")) "
                + "\(POSIXShell.quote(context.home + "/.config/systemd/user"))"
        case .unsupported:
            "false"
        }
    }

    nonisolated static func helperPresenceCommand(
        for context: AgentUpdaterHostContext
    ) -> String {
        "test -x \(POSIXShell.quote(helperPath(for: context)))"
    }

    nonisolated static func finaliseCommand(for context: AgentUpdaterHostContext) -> String {
        let helper = POSIXShell.quote(helperPath(for: context))
        let service = POSIXShell.quote(servicePath(for: context))
        switch context.platform {
        case .macOS:
            let domain = "gui/\(context.uid)"
            return """
            chmod 0700 \(helper) && chmod 0600 \(service) || exit 1
            launchctl bootout \(domain)/\(serviceLabel) >/dev/null 2>&1 || :
            launchctl bootstrap \(domain) \(service) || exit 1
            launchctl enable \(domain)/\(serviceLabel) || exit 1
            launchctl kickstart -k \(domain)/\(serviceLabel) || exit 1
            """
        case .linux:
            return """
            chmod 0700 \(helper) && chmod 0600 \(service) || exit 1
            systemctl --user daemon-reload || exit 1
            systemctl --user enable --now \(serviceFileName) || exit 1
            """
        case .unsupported:
            return "false"
        }
    }

    nonisolated static func verificationCommand(for context: AgentUpdaterHostContext) -> String {
        let helper = POSIXShell.quote(helperPath(for: context))
        let state = POSIXShell.quote(statePath(for: context))
        let serviceProbe: String
        let lingerProbe: String
        switch context.platform {
        case .macOS:
            serviceProbe = "launchctl print gui/\(context.uid)/\(serviceLabel) >/dev/null 2>&1"
            lingerProbe = "printf n/a"
        case .linux:
            serviceProbe = "systemctl --user is-active --quiet \(serviceFileName)"
            lingerProbe = "loginctl show-user \(context.uid) -p Linger --value 2>/dev/null || printf unknown"
        case .unsupported:
            serviceProbe = "false"
            lingerProbe = "printf unknown"
        }
        return """
        protocol=$(\(helper) protocol 2>/dev/null || printf unknown)
        if \(serviceProbe); then service=active; else service=inactive; fi
        verify_dir=\(state)/.verify.$$
        if mkdir -p \(state) && mkdir "$verify_dir" && rmdir "$verify_dir"; then writable=yes; else writable=no; fi
        if \(helper) verify-service 2>/dev/null | grep -F 'MSAM_AGENT_UPDATER_VERIFY\t1\tready' >/dev/null; then selftest=yes; else selftest=no; fi
        linger=$(\(lingerProbe))
        printf 'MSAM_VERIFY_BEGIN\\n'
        printf 'protocol=%s\\n' "$protocol"
        printf 'service=%s\\n' "$service"
        printf 'writable=%s\\n' "$writable"
        printf 'selftest=%s\\n' "$selftest"
        printf 'platform=%s\\n' "$(uname -s 2>/dev/null || printf unknown)"
        printf 'linger=%s\\n' "$linger"
        printf 'MSAM_VERIFY_END\\n'
        """
    }

    nonisolated static func parseVerification(
        _ output: String,
        platform: AgentUpdaterPlatform
    ) throws -> AgentUpdaterServiceStatus {
        let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let begin = lines.firstIndex(of: "MSAM_VERIFY_BEGIN"),
              let end = lines[(begin + 1)...].firstIndex(of: "MSAM_VERIFY_END") else {
            throw AgentUpdaterInstallerError.verification("The service did not return a complete verification result.")
        }
        var fields: [String: String] = [:]
        for line in lines[(begin + 1)..<end] {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            fields[String(pair[0])] = String(pair[1])
        }
        let status = AgentUpdaterServiceStatus(
            platform: platform,
            helperProtocol: fields["protocol"].flatMap(Int.init),
            serviceActive: fields["service"] == "active",
            stateWritable: fields["writable"] == "yes",
            selfTestPassed: fields["selftest"] == "yes",
            lingerEnabled: platform == .linux ? fields["linger"] == "yes" : nil
        )
        guard status.helperProtocol == 1 else {
            throw AgentUpdaterInstallerError.verification("The installed helper protocol is missing or out of date.")
        }
        guard status.serviceActive else {
            throw AgentUpdaterInstallerError.verification("The background service is not active.")
        }
        guard status.stateWritable else {
            throw AgentUpdaterInstallerError.verification("The service state directory is not writable.")
        }
        guard status.selfTestPassed else {
            throw AgentUpdaterInstallerError.verification("The updater self-test did not pass.")
        }
        return status
    }

    private func discoverContext() async throws -> AgentUpdaterHostContext {
        let result = try await requireService().run(
            Self.contextCommand,
            timeout: Self.commandTimeout,
            outputLimit: Self.outputLimit
        )
        return try Self.parseHostContext(result.stdoutString)
    }

    private func verify(_ context: AgentUpdaterHostContext) async throws -> AgentUpdaterServiceStatus {
        let result = try await requireService().run(
            Self.verificationCommand(for: context),
            timeout: Self.commandTimeout,
            outputLimit: Self.outputLimit
        )
        return try Self.parseVerification(result.stdoutString, platform: context.platform)
    }

    private func requireMacLoginDomainIfNeeded(
        _ context: AgentUpdaterHostContext,
        using service: SSHService
    ) async throws -> Bool {
        guard context.platform == .macOS else { return true }
        let result = try await service.run(
            "launchctl print gui/\(context.uid) >/dev/null 2>&1",
            timeout: Self.commandTimeout,
            outputLimit: Self.outputLimit
        )
        guard result.exitStatus == 0 else {
            state = .approvalRequired(.macOSLoginDomain([
                "Sign in to the Mac desktop as \(connection.host.username) and leave that user logged in.",
                "Return to Host Setup and tap Test Again. A per-user LaunchAgent cannot start without that macOS login domain."
            ]))
            return false
        }
        return true
    }

    private func publish(_ status: AgentUpdaterServiceStatus, context: AgentUpdaterHostContext) {
        if context.platform == .linux, status.lingerEnabled == false {
            state = .approvalRequired(.linuxLingerDisabled([
                "On the host, an administrator must run: loginctl enable-linger \(connection.host.username)",
                "Then return here and tap Test Again. Without linger, queued updates stop when the SSH user logs out."
            ]))
        } else {
            state = .ready(status)
        }
    }

    private func requireService() throws -> SSHService {
        guard let service = connection.provisioningCommandRunner else {
            throw AgentUpdaterInstallerError.notConnected
        }
        return service
    }

    nonisolated private static func loadBundledHelper() throws -> Data {
        guard let url = Bundle.main.url(forResource: "msam-agent-updater", withExtension: "sh"),
              let data = try? Data(contentsOf: url) else {
            throw AgentUpdaterInstallerError.missingResource
        }
        return data
    }

    nonisolated private static func markerFields(_ output: String, prefixes: Set<String>) -> [String: String] {
        var result: [String: String] = [:]
        for line in output.split(separator: "\n") {
            let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { continue }
            let key = String(pair[0])
            if prefixes.contains(key) { result[key] = String(pair[1]) }
        }
        return result
    }

    nonisolated private static func xmlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    nonisolated private static func systemdQuoted(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "%", with: "%%")
        if escaped.contains(where: { $0.isWhitespace || $0 == "\"" || $0 == "\\" }) {
            return "\"\(escaped)\""
        }
        return escaped
    }

    nonisolated static func message(for error: Error) -> String {
        switch error {
        case AgentUpdaterInstallerError.notConnected:
            "Connect and authenticate SSH to this host first."
        case AgentUpdaterInstallerError.invalidHostContext:
            "The host did not report a safe home directory, platform, and user ID."
        case AgentUpdaterInstallerError.missingResource:
            "The app is missing its bundled updater helper."
        case AgentUpdaterInstallerError.verification(let message):
            message
        case SSHCommandExecutionError.ambiguousDisconnect:
            "The connection ended before setup reported a result. Test Again to verify the host before retrying."
        case SSHCommandExecutionError.timedOut:
            "Host setup did not finish in time. Test Again before retrying."
        case SSHCommandExecutionError.cancelled:
            "Cancelled."
        case SSHCommandExecutionError.outputLimitExceeded:
            "The host produced more setup output than expected."
        default:
            SSHFailure.classify(message: String(describing: error)).userMessage
        }
    }
}
