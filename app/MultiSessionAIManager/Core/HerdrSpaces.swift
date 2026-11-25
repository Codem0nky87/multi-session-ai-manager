//
//  HerdrSpaces.swift
//  MultiSessionAIManager
//
//  The spaces (Herdr calls them workspaces) of the session a tab is attached
//  to, read from Herdr itself. On a narrow screen Herdr draws no sidebar: it
//  lists its spaces behind a small "switch" word, as rows of terminal text that
//  are hard to hit with a thumb. The app's drawer lists them natively from
//  this, and tells Herdr which one to show.
//

import Foundation
import Observation

/// One space of a Herdr session.
struct HerdrSpace: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    /// The one Herdr is showing.
    let isFocused: Bool
    /// What its agents are doing, as Herdr sums them up for the space.
    let status: HerdrAgentLifecycle

    /// Said under the space's name.
    var detail: String {
        switch status {
        case .working: "Working"
        case .blocked: "Waiting for you"
        case .idle: "Idle"
        case .done: "Done"
        case .error: "Error"
        case .unknown: "No agent"
        }
    }

    /// What a narrow screen's top line says: the space on screen over its host
    /// and what the session's agents are doing, or only the host while the
    /// spaces are not known.
    static func heading(host: String, spaces: [HerdrSpace]) -> (title: String, subtitle: String) {
        guard let current = spaces.first(where: \.isFocused) else { return (host, "") }
        return (current.name, [host, summary(of: spaces)].filter { !$0.isEmpty }.joined(separator: " · "))
    }

    /// Spaces whose agent has stopped to ask something.
    static func waitingCount(in spaces: [HerdrSpace]) -> Int {
        spaces.filter { $0.status == .blocked }.count
    }

    /// One line for the whole session: what waits first, then what works, then
    /// what idles. A count of zero is left out; a space with no agent is not counted.
    static func summary(of spaces: [HerdrSpace]) -> String {
        let parts: [(HerdrAgentLifecycle, String)] = [
            (.blocked, "waiting"), (.error, "failed"), (.working, "working"), (.done, "done"), (.idle, "idle"),
        ]
        return parts.compactMap { status, word in
            let count = spaces.filter { $0.status == status }.count
            return count == 0 ? nil : "\(count) \(word)"
        }
        .joined(separator: " · ")
    }
}

/// The host commands behind the list, and how their answer is read.
enum HerdrSpaceCommands {
    private static func quote(_ value: String, windows: Bool) -> String {
        windows ? WindowsShell.quote(value) : POSIXShell.quote(value)
    }

    /// `herdr`, speaking to the tab's own session.
    private static func herdr(_ sessionName: String?, windows: Bool) -> String {
        guard let sessionName, !sessionName.isEmpty else { return "herdr" }
        return "herdr --session \(quote(sessionName, windows: windows))"
    }

    static func list(sessionName: String?, windows: Bool = false) -> String {
        "\(herdr(sessionName, windows: windows)) workspace list"
    }

    /// Shows a space. `nil` for an id that is not one: the id comes from the
    /// host, and only letters, digits, `:`, `_`, `.` and `-` are ever sent back.
    static func focus(_ id: String, sessionName: String?, windows: Bool = false) -> String? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:_.-")
        guard !id.isEmpty, id.count <= 64, id.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return "\(herdr(sessionName, windows: windows)) workspace focus \(quote(id, windows: windows))"
    }

    /// Makes a new space and shows it.
    static func create(sessionName: String?, windows: Bool = false) -> String {
        "\(herdr(sessionName, windows: windows)) workspace create --focus"
    }

    /// The spaces in Herdr's answer to `list`, in its order. `nil` when the
    /// answer is not that list (Herdr not running, an error message).
    static func spaces(fromAnswer answer: String) -> [HerdrSpace]? {
        struct Answer: Decodable {
            struct Result: Decodable {
                struct Workspace: Decodable {
                    let workspace_id: String
                    let label: String?
                    let focused: Bool?
                    let agent_status: String?
                    let number: Int?
                }
                let workspaces: [Workspace]
            }
            let result: Result
        }
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let decoded = try? JSONDecoder().decode(Answer.self, from: Data(answer[start...end].utf8)) else {
            return nil
        }
        return decoded.result.workspaces.enumerated().map { index, space in
            let label = space.label?.trimmingCharacters(in: .whitespaces) ?? ""
            return HerdrSpace(
                id: space.workspace_id,
                name: label.isEmpty ? "Space \(space.number ?? index + 1)" : label,
                isFocused: space.focused ?? false,
                status: space.agent_status.flatMap(HerdrAgentLifecycle.init(rawValue:)) ?? .unknown)
        }
    }
}

/// The list as the drawer shows it. It asks the host through whatever runs a
/// command over the tab's own connection, so a test can stand in for that.
@MainActor
@Observable
final class HerdrSpaceList {
    /// Runs a command on the host and hands back what it printed.
    typealias Run = @MainActor (String) async throws -> String

    private(set) var spaces: [HerdrSpace] = []
    /// Why the last listing did not arrive. What was known stays on screen.
    private(set) var failure: String?

    var current: HerdrSpace? { spaces.first(where: \.isFocused) }

    func refresh(sessionName: String?, windows: Bool = false, run: Run) async {
        do {
            let answer = try await run(HerdrSpaceCommands.list(sessionName: sessionName, windows: windows))
            guard let listed = HerdrSpaceCommands.spaces(fromAnswer: answer) else {
                failure = "Herdr did not answer with its spaces."
                return
            }
            spaces = listed
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }

    func focus(_ space: HerdrSpace, sessionName: String?, windows: Bool = false, run: Run) async {
        guard let command = HerdrSpaceCommands.focus(space.id, sessionName: sessionName, windows: windows) else {
            failure = "That space cannot be shown."
            return
        }
        await act(command, sessionName: sessionName, windows: windows, run: run)
    }

    func create(sessionName: String?, windows: Bool = false, run: Run) async {
        await act(HerdrSpaceCommands.create(sessionName: sessionName, windows: windows),
                  sessionName: sessionName, windows: windows, run: run)
    }

    /// Does one thing and reads the list again, so the screen shows what Herdr
    /// now has rather than what was hoped for.
    private func act(_ command: String, sessionName: String?, windows: Bool, run: Run) async {
        do {
            _ = try await run(command)
        } catch {
            failure = error.localizedDescription
            return
        }
        await refresh(sessionName: sessionName, windows: windows, run: run)
    }
}

extension HerdrHostSession {
    /// Runs a Herdr command for this tab's session over its own connection.
    private func runForSpaces(_ command: String) async throws -> String {
        guard status == .live, let service = connection.provisioningCommandRunner else {
            throw HerdrSpaceListFailure.notConnected
        }
        let result = try await service.run(command, timeout: .seconds(10))
        guard result.exitStatus == 0 else {
            let said = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw HerdrSpaceListFailure.refused(said.isEmpty ? "Herdr refused (\(result.exitStatus))." : said)
        }
        return result.stdoutString
    }

    private var isWindowsHost: Bool { connection.provisioningCommandRunner?.isWindows ?? false }

    func refreshSpaces() async {
        await spaces.refresh(sessionName: sessionName, windows: isWindowsHost, run: runForSpaces)
    }

    func showSpace(_ space: HerdrSpace) async {
        await spaces.focus(space, sessionName: sessionName, windows: isWindowsHost, run: runForSpaces)
    }

    func newSpace() async {
        await spaces.create(sessionName: sessionName, windows: isWindowsHost, run: runForSpaces)
    }
}

enum HerdrSpaceListFailure: Error, Equatable, LocalizedError {
    case notConnected
    case refused(String)

    var errorDescription: String? {
        switch self {
        case .notConnected: "Not connected to the host."
        case .refused(let said): said
        }
    }
}
