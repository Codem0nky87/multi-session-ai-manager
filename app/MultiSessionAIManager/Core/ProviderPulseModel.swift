import Foundation
import Observation

public struct ResetCredits: Decodable, Equatable, Sendable {
    public let availableCount: Int
    public let expiresAt: [String]

    enum CodingKeys: String, CodingKey {
        case availableCount = "available_count"
        case expiresAt = "expires_at"
    }

    public init(availableCount: Int = 0, expiresAt: [String] = []) {
        self.availableCount = availableCount
        self.expiresAt = expiresAt
    }
}

public struct UsageWindow: Decodable, Equatable, Identifiable, Sendable {
    public var id: String { "\(group):\(windowMinutes)" }
    public let group: String
    public let windowMinutes: Int
    public let usedPercent: Double
    public let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case group
        case windowMinutes = "window_minutes"
        case usedPercent = "used_percent"
        case resetsAt = "resets_at"
    }

    public init(group: String, windowMinutes: Int, usedPercent: Double, resetsAt: String? = nil) {
        self.group = group
        self.windowMinutes = windowMinutes
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }
}

public struct ProviderQuota: Decodable, Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public let state: String // "HEALTHY", "RATE_LIMITED", "REFRESH_DELAYED", "SIGN_IN_REQUIRED", "UNAVAILABLE"
    public let usedPercent: Double
    public let resetsAt: String?
    public let plan: String?
    public let windows: [UsageWindow]
    public let resetCredits: ResetCredits?

    enum CodingKeys: String, CodingKey {
        case state
        case usedPercent = "used_percent"
        case resetsAt = "resets_at"
        case plan
        case windows
        case resetCredits = "reset_credits"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = ""
        self.state = try container.decodeIfPresent(String.self, forKey: .state) ?? "HEALTHY"
        self.usedPercent = try container.decodeIfPresent(Double.self, forKey: .usedPercent) ?? 0.0
        self.resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt)
        self.plan = try container.decodeIfPresent(String.self, forKey: .plan)
        self.windows = try container.decodeIfPresent([UsageWindow].self, forKey: .windows) ?? []
        self.resetCredits = try container.decodeIfPresent(ResetCredits.self, forKey: .resetCredits)
    }

    public init(name: String, state: String = "HEALTHY", usedPercent: Double = 0.0, resetsAt: String? = nil, plan: String? = nil, windows: [UsageWindow] = [], resetCredits: ResetCredits? = nil) {
        self.name = name
        self.state = state
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.plan = plan
        self.windows = windows
        self.resetCredits = resetCredits
    }

    public var isRateLimited: Bool {
        state == "RATE_LIMITED" || usedPercent >= 100.0
    }

    public var displayName: String {
        switch name {
        case "claude_code", "claude": return "Claude Code"
        case "codex": return "Codex"
        case "antigravity", "agy": return "Antigravity"
        case "hermes": return "Hermes"
        default: return name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

public struct TerminalAgentSession: Decodable, Equatable, Identifiable, Sendable {
    public var id: String { paneID }
    public let paneID: String
    public let tabID: String
    public let name: String
    public let provider: String
    public let project: String
    public let state: String
    public let model: String?
    public let sessionTokens: Int?
    public let transcriptPath: String?
    public let isLimitReached: Bool

    enum CodingKeys: String, CodingKey {
        case paneID = "pane_id"
        case tabID = "tab_id"
        case name
        case provider
        case project
        case state
        case model
        case sessionTokens = "session_tokens"
        case transcriptPath = "transcript_path"
        case isLimitReached = "is_limit_reached"
    }

    public init(paneID: String, tabID: String = "", name: String, provider: String, project: String, state: String = "idle", model: String? = nil, sessionTokens: Int? = nil, transcriptPath: String? = nil, isLimitReached: Bool = false) {
        self.paneID = paneID
        self.tabID = tabID
        self.name = name
        self.provider = provider
        self.project = project
        self.state = state
        self.model = model
        self.sessionTokens = sessionTokens
        self.transcriptPath = transcriptPath
        self.isLimitReached = isLimitReached
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let pane = try container.decodeIfPresent(String.self, forKey: .paneID) ?? ""
        self.paneID = pane
        self.tabID = try container.decodeIfPresent(String.self, forKey: .tabID) ?? ""
        self.name = try container.decodeIfPresent(String.self, forKey: .name) ?? (!pane.isEmpty ? pane : "terminal")
        self.provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? ""
        self.project = try container.decodeIfPresent(String.self, forKey: .project) ?? ""
        self.state = try container.decodeIfPresent(String.self, forKey: .state) ?? "idle"
        self.model = try container.decodeIfPresent(String.self, forKey: .model)
        self.sessionTokens = try container.decodeIfPresent(Int.self, forKey: .sessionTokens)
        self.transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        self.isLimitReached = try container.decodeIfPresent(Bool.self, forKey: .isLimitReached) ?? false
    }
}

@MainActor
@Observable
public final class ProviderPulseModel {
    public private(set) var providers: [String: ProviderQuota] = [:]
    public private(set) var terminalAgents: [TerminalAgentSession] = []
    public private(set) var installedIntegrations: [String] = []

    public init() {}

    public func update(
        providers: [String: ProviderQuota],
        terminals: [TerminalAgentSession],
        installedIntegrations: [String]? = nil
    ) {
        var named: [String: ProviderQuota] = [:]
        for (key, var val) in providers {
            val.name = key
            named[key] = val
        }
        self.providers = named
        self.terminalAgents = terminals
        if let installedIntegrations {
            self.installedIntegrations = installedIntegrations
        }
    }

    private func isIntegrationInstalled(for providerKey: String) -> Bool {
        guard !installedIntegrations.isEmpty else { return true }
        switch providerKey {
        case "claude_code", "claude":
            return installedIntegrations.contains("claude")
        case "codex":
            return installedIntegrations.contains("codex")
        case "antigravity", "agy":
            return installedIntegrations.contains("antigravity-cli") ||
                   installedIntegrations.contains("antigravity") ||
                   installedIntegrations.contains("agy")
        case "hermes":
            return installedIntegrations.contains("hermes")
        default:
            return installedIntegrations.contains(providerKey)
        }
    }

    public var activeProviders: [ProviderQuota] {
        let order = ["claude_code", "codex", "antigravity", "hermes"]
        var list: [ProviderQuota] = []
        for key in order {
            if let p = providers[key], isIntegrationInstalled(for: key) {
                list.append(p)
            }
        }
        for (key, p) in providers where !order.contains(key) {
            if isIntegrationInstalled(for: key) {
                list.append(p)
            }
        }
        return list
    }

    public var hasRateLimitedProvider: Bool {
        activeProviders.contains(where: \.isRateLimited)
    }

    public func terminals(for providerName: String) -> [TerminalAgentSession] {
        let target = providerName.lowercased()
        return terminalAgents.filter { agent in
            let p = agent.provider.lowercased()
            if p == target { return true }
            if (target.contains("claude") && p.contains("claude")) { return true }
            if (target.contains("codex") && p.contains("codex")) { return true }
            if ((target.contains("anti") || target.contains("agy")) && (p.contains("anti") || p.contains("agy"))) { return true }
            if (target.contains("hermes") && p.contains("hermes")) { return true }
            return false
        }
    }
}
