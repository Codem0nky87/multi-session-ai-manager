import Foundation

/// The host commands that open a browser space in the Herdr session a tab is
/// attached to.
///
/// A Unix host is sent `sh`. A Windows host is sent Windows PowerShell 5.1,
/// which is what `SSHService.run` wraps a command in there, and its
/// placeholder goes over SFTP.
enum BrowserSpaceCommands {
    static let label = "Browser"
    static let scriptPath = "$HOME/.local/share/msam/browser-space.sh"

    private static func quote(_ value: String, windows: Bool) -> String {
        windows ? WindowsShell.quote(value) : POSIXShell.quote(value)
    }

    /// `herdr`, speaking to the tab's own session.
    private static func herdr(_ sessionName: String?, windows: Bool = false) -> String {
        guard let sessionName, !sessionName.isEmpty else { return "herdr" }
        return "herdr --session \(quote(sessionName, windows: windows))"
    }

    /// Creates the space and selects it. Herdr answers with JSON naming its pane.
    static func createSpace(sessionName: String?, windows: Bool = false) -> String {
        "\(herdr(sessionName, windows: windows)) workspace create --label \(quote(label, windows: windows)) --focus"
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

    // MARK: - Windows

    /// Makes the placeholder's folder under the account's profile and says
    /// where the profile is: `MSAM_HOME=C:\Users\alice`, or `MSAM_FAILED=` and
    /// why not.
    static let windowsPrepareScript = """
        try {
          [void][System.IO.Directory]::CreateDirectory((Join-Path $env:USERPROFILE '.local\\share\\msam'))
          'MSAM_HOME='+$env:USERPROFILE
        } catch {
          $reason=$_.Exception
          while ($reason.InnerException) { $reason=$reason.InnerException }
          'MSAM_FAILED='+$reason.Message
        }
        exit 0
        """
    static let windowsPrepareCommand = WindowsShell.command(windowsPrepareScript)

    /// The profile `windowsPrepareScript` reported.
    static func windowsProfile(fromAnswer answer: String) throws -> String {
        let lines = answer.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if let failed = lines.last(where: { $0.hasPrefix("MSAM_FAILED=") }) {
            throw BrowserSpaceOpenError.placeholder(String(failed.dropFirst(12)))
        }
        let home = lines.last(where: { $0.hasPrefix("MSAM_HOME=") }).map { String($0.dropFirst(10)) } ?? ""
        guard RemoteFileUpload.isWindowsPath(home) else { throw BrowserSpaceOpenError.placeholder("") }
        return home
    }

    /// Where the placeholder goes, with forward slashes: SFTP on Windows wants
    /// them, PowerShell and cmd take them, and a pane that runs some other
    /// shell does not read them as escapes.
    static func windowsScriptPath(home: String) -> String {
        let base = home.hasSuffix("\\") ? String(home.dropLast()) : home
        return base.replacingOccurrences(of: "\\", with: "/") + "/.local/share/msam/browser-space.ps1"
    }

    /// What is typed into the new pane. Herdr's panes run PowerShell 7 where
    /// it is installed, Windows PowerShell otherwise, and cmd when configured;
    /// this line reads the same in all of them. `powershell.exe` is on every
    /// Windows and is what the placeholder is written for.
    static func windowsPlaceholderLine(path: String, id: String) -> String {
        // "C:/Users/Jane Smith" is an ordinary profile; a Windows path cannot
        // itself contain a quote.
        let plain = path.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || "/:._-".unicodeScalars.contains($0)
        }
        return "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File \(plain ? path : "\"\(path)\"") \(id)"
    }

    /// Starts the placeholder in the new pane. There is no `exec` here: the
    /// pane's shell waits underneath, and both end when Herdr closes the pane.
    static func runWindowsPlaceholder(path: String, paneID: String, id: String, sessionName: String?) -> String {
        // Windows PowerShell 5.1 wraps an argument that has a space in double
        // quotes but does not escape the double quotes inside it, so they go
        // in escaped. The line has no backslash to be escaped in turn.
        let line = windowsPlaceholderLine(path: path, id: id).replacingOccurrences(of: "\"", with: "\\\"")
        return "\(herdr(sessionName, windows: true)) pane run \(WindowsShell.quote(paneID)) \(WindowsShell.quote(line))"
    }

    static func newID() -> String {
        String(format: "%06x", UInt32.random(in: 0...0xFF_FFFF))
    }
}

enum BrowserSpaceOpenError: Error, LocalizedError, Equatable {
    /// Herdr's own words, when it had any.
    case herdr(String)
    /// The placeholder could not be put on a Windows host: the host's own
    /// words, or none when it did not even say where its profile is.
    case placeholder(String)
    case missingPlaceholder

    var errorDescription: String? {
        switch self {
        case .herdr(let words): words.isEmpty ? "Herdr did not create the space." : words
        case .placeholder(let words):
            words.isEmpty
                ? "The host did not say where its profile is, so the browser space helper has nowhere to go."
                : "The host could not take the browser space helper: \(words)"
        case .missingPlaceholder: "This build is missing the browser space helper."
        }
    }
}

enum BrowserSpaceOpener {
    /// Opens a browser space in the tab's Herdr session and returns its id.
    /// `script` is the placeholder to run there; left out, it is the one this
    /// build ships for the host's system.
    @discardableResult
    static func open(using service: SSHService, sessionName: String?, script: String? = nil,
                     id: String = BrowserSpaceCommands.newID()) async throws -> String {
        let windows = service.isWindows
        guard let script = script ?? bundledPlaceholder(windows: windows) else {
            throw BrowserSpaceOpenError.missingPlaceholder
        }
        // On Windows the placeholder goes first: were it to fail after the
        // space was made, a "Browser" space with a bare prompt would be left.
        let windowsPath: String? = if windows { try await putOnWindows(script, using: service) } else { nil }

        let created = try await service.run(
            BrowserSpaceCommands.createSpace(sessionName: sessionName, windows: windows), timeout: .seconds(20))
        guard created.exitStatus == 0,
              let pane = BrowserSpaceCommands.paneID(fromAnswer: created.stdoutString) else {
            throw BrowserSpaceOpenError.herdr(words(of: created))
        }
        let run = if let windowsPath {
            BrowserSpaceCommands.runWindowsPlaceholder(path: windowsPath, paneID: pane, id: id, sessionName: sessionName)
        } else {
            BrowserSpaceCommands.runPlaceholder(script: script, paneID: pane, id: id, sessionName: sessionName)
        }
        let ran = try await service.run(run, timeout: .seconds(20))
        guard ran.exitStatus == 0 else { throw BrowserSpaceOpenError.herdr(words(of: ran)) }
        return id
    }

    /// Writes the placeholder into the account's profile on a Windows host and
    /// returns where it is.
    private static func putOnWindows(_ script: String, using service: SSHService) async throws -> String {
        let asked = try await service.run(BrowserSpaceCommands.windowsPrepareCommand, timeout: .seconds(20))
        let home: String
        do {
            home = try BrowserSpaceCommands.windowsProfile(fromAnswer: asked.stdoutString)
        } catch BrowserSpaceOpenError.placeholder("") where asked.exitStatus != 0 {
            // The question itself failed: what the host printed is the only clue.
            throw BrowserSpaceOpenError.placeholder(words(of: asked))
        }
        let path = BrowserSpaceCommands.windowsScriptPath(home: home)
        do {
            try await service.writeFile(Data(script.utf8), to: path)
        } catch {
            throw BrowserSpaceOpenError.placeholder("\(error)")
        }
        return path
    }

    /// The placeholder this build ships: `sh` for a Unix host, PowerShell for
    /// a Windows one.
    static func bundledPlaceholder(windows: Bool = false) -> String? {
        Bundle.main.url(forResource: "msam-browser-space", withExtension: windows ? "ps1" : "sh")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    private static func words(of result: SSHCommandResult) -> String {
        let said = result.stderrString.isEmpty ? result.stdoutString : result.stderrString
        return String(said.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
    }
}
