import Foundation
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

struct PluginUpdateStatus: Decodable, Equatable, Sendable {
    let pluginID: String
    let source: String
    let installedCommit: String?
    let availableCommit: String?
    let trackingRef: String?
    let error: String?

    var isAvailable: Bool {
        guard error == nil, let installedCommit, let availableCommit,
              Self.isCommit(installedCommit), Self.isCommit(availableCommit),
              HerdrPluginManagement.isValidSource(source),
              trackingRef.map(HerdrPluginManagement.isValidRef) ?? true else { return false }
        return installedCommit.lowercased() != availableCommit.lowercased()
    }

    private static func isCommit(_ value: String) -> Bool {
        value.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) || (65...70).contains($0) }
    }
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
    typealias Failure = HostHelperScript.Failure

    /// Content-addressed helper: updates take effect on the next operation,
    /// without replacing or restarting the metrics/agent daemon.
    static let helper = HostHelperScript(resource: "msam-host-software.py", folder: "msam-host-software",
                                         filename: "software.py", prefix: "MSAM_SOFTWARE=")

    private struct Response: Decodable {
        var agents: [HostAgentInstallation]?
        var plugins: [PluginSetupStatus]?
    }

    static func decode<T: Decodable>(_ type: T.Type, from output: String) throws -> T {
        try helper.decode(type, from: output, missing: "The host did not return a software check.")
    }

    private static func execute<T: Decodable>(_ type: T.Type, _ args: [String], using service: SSHService,
                                             timeout: Duration = .seconds(120)) async throws -> T {
        try await helper.execute(type, args, using: service, timeout: timeout,
                                 missing: "The host did not return a software check.",
                                 failure: "The host software operation failed.")
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

    static func preparePlugin(source: String, ref: String?, trackingRef: String? = nil, using service: SSHService) async throws -> PluginDependencyPlan {
        try await execute(PluginDependencyPlan.self, ["prepare-plugin", source]
                          + (ref.flatMap { $0.isEmpty ? nil : $0 }.map { ["--ref", $0] } ?? [])
                          + (trackingRef.map { ["--tracking-ref", $0] } ?? []),
                          using: service, timeout: .seconds(3600))
    }

    static func pluginStatus(using service: SSHService) async throws -> [PluginSetupStatus] {
        try await execute(Response.self, ["plugin-status"], using: service).plugins ?? []
    }

    static func pluginUpdates(using service: SSHService) async throws -> [PluginUpdateStatus] {
        struct Updates: Decodable { let updates: [PluginUpdateStatus] }
        return try await execute(Updates.self, ["plugin-updates"], using: service, timeout: .seconds(180)).updates
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
