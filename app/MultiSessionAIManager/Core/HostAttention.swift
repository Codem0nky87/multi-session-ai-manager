import Foundation

/// How urgent the most pressing thing on a host is. Drives the colour of the pill
/// beside the host's name.
enum HostAttentionLevel: Equatable, Sendable {
    /// An agent is blocked: it waits for an answer or a permission.
    case error
    /// A provider used on the host is rate limited.
    case warning
    /// An agent has finished and nobody has looked at it yet.
    case info
}

struct HostAttentionPill: Equatable, Sendable {
    let level: HostAttentionLevel
    /// How many things are at that level.
    let count: Int
}

/// What on a host is waiting for its user, as the host service reports it
/// (`msam-host-agent attention`).
///
/// Herdr offers no feed of the notifications it pops up. It does report the agent
/// state behind them, which is what this carries: `blocked` and `done`. Herdr
/// clears `done` itself once the agent's pane is viewed, so there is nothing to
/// dismiss here.
struct HostAttention: Decodable, Equatable, Sendable {
    struct Item: Decodable, Equatable, Sendable {
        /// The Herdr session the agent runs in.
        let session: String
        let paneID: String
        let name: String
        let agent: String?

        enum CodingKeys: String, CodingKey {
            case session
            case paneID = "pane_id"
            case name
            case agent
        }
    }

    static let linePrefix = "MSAM_ATTENTION="

    /// False when the service could not read Herdr's agents. Then nothing is known
    /// about blocked or finished agents, which is not the same as there being none.
    var available: Bool
    var blocked: [Item]
    var done: [Item]
    var rateLimited: [String]
    /// The lists are cut to a few entries; these are the full counts.
    var blockedCount: Int
    var doneCount: Int

    enum CodingKeys: String, CodingKey {
        case available, blocked, done
        case rateLimited = "rate_limited"
        case blockedCount = "blocked_count"
        case doneCount = "done_count"
    }

    /// One line of the notification stream, or nil for anything else the host printed.
    static func parse(line: String) -> HostAttention? {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix(linePrefix) else { return nil }
        return try? JSONDecoder().decode(HostAttention.self, from: Data(line.dropFirst(linePrefix.count).utf8))
    }

    /// What a tab bound to one Herdr session should show: that session's agents
    /// only. A tab on the host as a whole (no session name) sees every session.
    /// A rate limit belongs to the host either way.
    func scoped(to session: String?) -> HostAttention {
        guard let session, !session.isEmpty else { return self }
        var scoped = self
        scoped.blocked = blocked.filter { $0.session == session }
        scoped.done = done.filter { $0.session == session }
        scoped.blockedCount = scoped.blocked.count
        scoped.doneCount = scoped.done.count
        return scoped
    }

    /// The most pressing level and how many things are at it; nil when the host is quiet.
    var pill: HostAttentionPill? {
        if available, blockedCount > 0 { return HostAttentionPill(level: .error, count: blockedCount) }
        if !rateLimited.isEmpty { return HostAttentionPill(level: .warning, count: rateLimited.count) }
        if available, doneCount > 0 { return HostAttentionPill(level: .info, count: doneCount) }
        return nil
    }

    /// Everything the pill stands for, for VoiceOver: the pill shows one number.
    var spokenSummary: String? {
        var parts: [String] = []
        if available, blockedCount > 0 {
            parts.append(blockedCount == 1 ? "1 agent is waiting for you" : "\(blockedCount) agents are waiting for you")
        }
        if !rateLimited.isEmpty {
            parts.append(rateLimited.count == 1 ? "1 provider is rate limited"
                                                : "\(rateLimited.count) providers are rate limited")
        }
        if available, doneCount > 0 {
            parts.append(doneCount == 1 ? "1 agent has finished" : "\(doneCount) agents have finished")
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
