import Foundation

/// The host commands that open a browser space in the Herdr session a tab is
/// attached to.
enum BrowserSpaceCommands {
    static let label = "Browser"
    static let scriptPath = "$HOME/.local/share/msam/browser-space.sh"

    /// `herdr`, speaking to the tab's own session.
    private static func herdr(_ sessionName: String?) -> String {
        guard let sessionName, !sessionName.isEmpty else { return "herdr" }
        return "herdr --session \(POSIXShell.quote(sessionName))"
    }

    /// Creates the space and selects it. Herdr answers with JSON naming its pane.
    static func createSpace(sessionName: String?) -> String {
        "\(herdr(sessionName)) workspace create --label \(POSIXShell.quote(label)) --focus"
    }

    /// The pane of the space Herdr just created.
    static func paneID(fromAnswer answer: String) -> String? {
        struct Answer: Decodable {
            struct Result: Decodable {
                struct Pane: Decodable { let pane_id: String }
                let root_pane: Pane
            }
            let result: Result
        }
        guard let start = answer.firstIndex(of: "{"), let end = answer.lastIndex(of: "}"), start < end,
              let decoded = try? JSONDecoder().decode(Answer.self, from: Data(answer[start...end].utf8)) else {
            return nil
        }
        let pane = decoded.result.root_pane.pane_id
        // It goes into a command line next.
        let allowed = pane.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ":._-".contains($0)) }
        return !pane.isEmpty && allowed ? pane : nil
    }

    /// Puts this build's placeholder on the host and makes it the pane's process:
    /// with `exec`, closing the space ends the placeholder and the reverse.
    static func runPlaceholder(script: String, paneID: String, id: String, sessionName: String?) -> String {
        let run = "exec sh \"\(scriptPath)\" \(id)"
        return [
            "mkdir -p \"$HOME/.local/share/msam\" && cat > \"\(scriptPath)\" <<'AIM_BROWSER_SPACE_END'",
            script.trimmingCharacters(in: .newlines),
            "AIM_BROWSER_SPACE_END",
            "\(herdr(sessionName)) pane run \(POSIXShell.quote(paneID)) \(POSIXShell.quote(run))",
        ].joined(separator: "\n")
    }

    static func newID() -> String {
        String(format: "%06x", UInt32.random(in: 0...0xFF_FFFF))
    }
}

enum BrowserSpaceOpenError: Error, LocalizedError, Equatable {
    case windowsHost
    /// Herdr's own words, when it had any.
    case herdr(String)

    var errorDescription: String? {
        switch self {
        case .windowsHost: "Browser spaces need a Unix host."
        case .herdr(let words): words.isEmpty ? "Herdr did not create the space." : words
        }
    }
}

enum BrowserSpaceOpener {
    /// Opens a browser space in the tab's Herdr session and returns its id.
    @discardableResult
    static func open(using service: SSHService, sessionName: String?, script: String,
                     id: String = BrowserSpaceCommands.newID()) async throws -> String {
        guard !service.isWindows else { throw BrowserSpaceOpenError.windowsHost }
        let created = try await service.run(BrowserSpaceCommands.createSpace(sessionName: sessionName),
                                            timeout: .seconds(20))
        guard created.exitStatus == 0,
              let pane = BrowserSpaceCommands.paneID(fromAnswer: created.stdoutString) else {
            throw BrowserSpaceOpenError.herdr(words(of: created))
        }
        let ran = try await service.run(
            BrowserSpaceCommands.runPlaceholder(script: script, paneID: pane, id: id, sessionName: sessionName),
            timeout: .seconds(20))
        guard ran.exitStatus == 0 else { throw BrowserSpaceOpenError.herdr(words(of: ran)) }
        return id
    }

    /// The placeholder this build ships.
    static func bundledPlaceholder() -> String? {
        Bundle.main.url(forResource: "msam-browser-space", withExtension: "sh")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    private static func words(of result: SSHCommandResult) -> String {
        let said = result.stderrString.isEmpty ? result.stdoutString : result.stderrString
        return String(said.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }
}
