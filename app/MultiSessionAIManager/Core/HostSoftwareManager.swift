import Foundation
import CryptoKit
import Observation

struct HostAgentInstallation: Decodable, Identifiable, Equatable, Sendable {
    let id: AgentToolID
    let installed: Bool
    let version: String?
    let path: String?
    let error: String?
}

struct PluginSetupActionStatus: Decodable, Equatable, Sendable {
    let id: String
    let state: String
    let detail: String
    var canInstall: Bool { state == "missing" }
    var isReady: Bool { state == "ready" }
}

struct PluginSetupStatus: Decodable, Sendable {
    let pluginID: String
    let actions: [PluginSetupActionStatus]
}

struct PluginDependencyPlan: Decodable, Sendable {
    struct Dependency: Decodable, Sendable {
        let tool: String
        let status: String
    }
    let source: String
    let ref: String
    let pluginID: String
    let dependencies: [Dependency]
}

enum HostSoftwareProvisioning {
    enum Failure: LocalizedError {
        case failed(String)
        var errorDescription: String? { if case .failed(let reason) = self { reason } else { nil } }
    }

    private struct Response: Decodable {
        var agents: [HostAgentInstallation]?
        var plugins: [PluginSetupStatus]?
    }

    static func decode<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
        let prefix = "MSAM_SOFTWARE="
        guard let line = output.split(whereSeparator: \.isNewline).last(where: { $0.hasPrefix(prefix) }) else {
            throw Failure.failed(HerdrPluginManagement.tail(of: output, fallback: "The host did not return a software check."))
        }
        let data = Data(line.dropFirst(prefix.count).utf8)
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let error = object["error"] as? String {
            throw Failure.failed(error)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    /// Content-addressed helper: updates take effect on the next operation,
    /// without replacing or restarting the metrics/agent daemon.
    private static func command(_ arguments: [String], using service: SSHService) async throws -> String {
        let data = try HostServiceInstaller.resource("msam-host-software.py")
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let prepare = """
        from pathlib import Path
        import hashlib,json,sys
        p=Path.home()/'.local/libexec/msam-host-software'/sys.argv[1]/'software.py'
        p.parent.mkdir(parents=True,exist_ok=True)
        print('MSAM_SOFTWARE='+json.dumps(dict(path=str(p),present=p.is_file() and hashlib.sha256(p.read_bytes()).hexdigest()==sys.argv[1])))
        """
        struct Location: Decodable { let path: String; let present: Bool }
        let result = try await service.run(HostServiceInstaller.python(prepare, arguments: [hash], isWindows: service.isWindows),
                                          timeout: .seconds(30), outputLimit: 16 * 1024)
        let location = try decode(Location.self, from: result.stdoutString + result.stderrString)
        if !location.present {
            try await service.writeSetupFile(data, to: location.path.replacingOccurrences(of: "\\", with: "/"), permissions: 0o700)
        }
        let execute = "import runpy,sys; p=sys.argv.pop(1); sys.argv[0]=p; runpy.run_path(p,run_name='__main__')"
        return HostServiceInstaller.python(execute, arguments: [location.path] + arguments, isWindows: service.isWindows)
    }

    private static func execute<T: Decodable>(_ type: T.Type, _ args: [String], using service: SSHService,
                                             timeout: Duration = .seconds(120)) async throws -> T {
        let command = try await command(args, using: service)
        let result = try await service.run(command, timeout: timeout, outputLimit: 256 * 1024)
        let value = try decode(type, from: result.stdoutString + result.stderrString)
        guard result.exitStatus == 0 else { throw Failure.failed("The host software operation failed.") }
        return value
    }

    static func agents(using service: SSHService) async throws -> [HostAgentInstallation] {
        try await execute(Response.self, ["agents"], using: service).agents ?? []
    }

    static func install(_ tool: AgentToolID, using service: SSHService) async throws -> HostAgentInstallation {
        let result = try await execute(Response.self, ["install-agent", tool.rawValue], using: service, timeout: .seconds(2400))
        guard let agent = result.agents?.first(where: { $0.id == tool }), agent.installed else {
            throw Failure.failed("The installed CLI did not pass its version check.")
        }
        return agent
    }

    static func preparePlugin(source: String, ref: String?, using service: SSHService) async throws -> PluginDependencyPlan {
        try await execute(PluginDependencyPlan.self, ["prepare-plugin", source] + (ref.flatMap { $0.isEmpty ? nil : $0 }.map { ["--ref", $0] } ?? []),
                          using: service, timeout: .seconds(3600))
    }

    static func pluginStatus(using service: SSHService) async throws -> [PluginSetupStatus] {
        try await execute(Response.self, ["plugin-status"], using: service).plugins ?? []
    }
}

@MainActor @Observable
final class HostSoftwareManager {
    let connection: HostConnection
    private(set) var agents: [HostAgentInstallation] = []
    private(set) var busy = false
    private(set) var step: String?
    private(set) var error: String?
    private(set) var notice: String?

    init(connection: HostConnection) { self.connection = connection }

    func refresh() async {
        guard !busy, let service = connection.provisioningCommandRunner else { return }
        busy = true
        defer { busy = false }
        error = nil
        do { agents = try await HostSoftwareProvisioning.agents(using: service) }
        catch { self.error = error.localizedDescription }
    }

    func install(_ tool: AgentToolID) async {
        guard !busy, let service = connection.provisioningCommandRunner else { return }
        busy = true
        step = "Checking dependencies, installing and verifying \(AgentToolRegistry.definition(for: tool).displayName)…"
        defer { busy = false; step = nil }
        error = nil
        notice = nil
        do {
            let result = try await HostSoftwareProvisioning.install(tool, using: service)
            agents.removeAll { $0.id == tool }
            agents.append(result)
            notice = "\(AgentToolRegistry.definition(for: tool).displayName) \(result.version ?? "") verified. Open the CLI in a host terminal to sign in."
        } catch { self.error = error.localizedDescription }
    }
}
