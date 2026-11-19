import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct BrowserSpaceCommandsTests {
    /// What Herdr 0.9.5 answers to `workspace create`.
    private static let created = #"{"id":"cli:workspace:create","result":{"root_pane":{"pane_id":"w2:p1","tab_id":"w2:t1"},"type":"workspace_created","workspace":{"workspace_id":"w2"}}}"#

    @Test func theSpaceIsCreatedInTheTabsOwnSessionAndSelected() {
        #expect(BrowserSpaceCommands.createSpace(sessionName: nil)
                == "herdr workspace create --label 'Browser' --focus")
        #expect(BrowserSpaceCommands.createSpace(sessionName: "")
                == "herdr workspace create --label 'Browser' --focus")
        #expect(BrowserSpaceCommands.createSpace(sessionName: "night shift")
                == "herdr --session 'night shift' workspace create --label 'Browser' --focus")
    }

    @Test func thePaneIsReadFromHerdrsAnswer() {
        #expect(BrowserSpaceCommands.paneID(fromAnswer: Self.created) == "w2:p1")
        // A login shell may print before it.
        #expect(BrowserSpaceCommands.paneID(fromAnswer: "motd\n" + Self.created + "\n") == "w2:p1")
    }

    @Test(arguments: ["", "herdr: no server running", #"{"result":{"root_pane":{"pane_id":"w2;rm -rf"}}}"#])
    func anAnswerWithoutAUsablePaneGivesNone(answer: String) {
        #expect(BrowserSpaceCommands.paneID(fromAnswer: answer) == nil)
    }

    @Test func thePlaceholderIsWrittenAndMadeThePanesProcess() {
        let command = BrowserSpaceCommands.runPlaceholder(
            script: "#!/bin/sh\necho 'it'\n", paneID: "w2:p1", id: "7f3a2c", sessionName: "work")
        let lines = command.components(separatedBy: "\n")
        #expect(lines.first == #"mkdir -p "$HOME/.local/share/msam" && cat > "$HOME/.local/share/msam/browser-space.sh" <<'AIM_BROWSER_SPACE_END'"#)
        #expect(lines.contains("echo 'it'"), "The script goes in as it is, unquoted by the here-document")
        #expect(lines.contains("AIM_BROWSER_SPACE_END"))
        #expect(lines.last == #"herdr --session 'work' pane run 'w2:p1' 'exec sh "$HOME/.local/share/msam/browser-space.sh" 7f3a2c'"#)
    }

    @Test func anIdIsSixHexDigits() {
        for _ in 0..<50 {
            let id = BrowserSpaceCommands.newID()
            #expect(id.count == 6 && id.allSatisfy { $0.isHexDigit && !$0.isUppercase }, "\(id)")
        }
    }

    private func service() async throws -> (SSHService, FakeSSHTransport) {
        let transport = FakeSSHTransport()
        let host = Host(name: "Forge", address: "192.0.2.24", port: 22, username: "alice", keyID: "test-key", defaultWorkdir: "/")
        let defaults = try #require(UserDefaults(suiteName: "browser-space-\(UUID().uuidString)"))
        let service = SSHService(host: host, transport: transport, knownHosts: KnownHostsStore(defaults: defaults))
        try await service.connect(key: SSHKeyMaterial(ed25519Seed: Data(repeating: 7, count: 32))) { _, _ in true }
        return (service, transport)
    }

    /// What was run on the host after connecting (connecting asks which system it is).
    private func commands(on transport: FakeSSHTransport) -> [String] {
        transport.structuredCommandsRun.map(\.command).filter { !$0.hasPrefix("echo %OS%") }
    }

    private func result(_ status: Int32, _ out: String = "", _ err: String = "") -> Result<SSHCommandResult, SSHCommandExecutionError> {
        .success(SSHCommandResult(exitStatus: status, stdout: Data(out.utf8), stderr: Data(err.utf8)))
    }

    @Test func openingCreatesTheSpaceThenRunsThePlaceholderInItsPane() async throws {
        let (service, transport) = try await service()
        transport.structuredCommandResults = [result(0, Self.created), result(0)]

        let id = try await BrowserSpaceOpener.open(using: service, sessionName: nil, script: "#!/bin/sh\n", id: "7f3a2c")

        #expect(id == "7f3a2c")
        let commands = commands(on: transport)
        #expect(commands.count == 2)
        #expect(commands.first?.contains("workspace create --label") == true)
        #expect(commands.last?.contains("pane run") == true && commands.last?.contains("w2:p1") == true)
    }

    @Test func aHerdrThatRefusesIsQuoted() async throws {
        let (service, transport) = try await service()
        transport.structuredCommandResults = [result(1, "", "herdr: no server running\n")]

        await #expect(throws: BrowserSpaceOpenError.herdr("herdr: no server running")) {
            _ = try await BrowserSpaceOpener.open(using: service, sessionName: nil, script: "#!/bin/sh\n", id: "7f3a2c")
        }
        #expect(commands(on: transport).count == 1, "Nothing is run in a pane that was not made")
    }

    @Test func aPlaceholderThatCouldNotBeRunIsReported() async throws {
        let (service, transport) = try await service()
        transport.structuredCommandResults = [result(0, Self.created), result(1, "", "pane not found")]

        await #expect(throws: BrowserSpaceOpenError.herdr("pane not found")) {
            _ = try await BrowserSpaceOpener.open(using: service, sessionName: nil, script: "#!/bin/sh\n", id: "7f3a2c")
        }
    }

    @Test func theErrorsReadAsSentences() {
        #expect(BrowserSpaceOpenError.herdr("herdr: no server running").errorDescription == "herdr: no server running")
        #expect(BrowserSpaceOpenError.herdr("").errorDescription == "Herdr did not create the space.")
        #expect(BrowserSpaceOpenError.placeholder("Access to the path is denied.").errorDescription
                == "The host could not take the browser space helper: Access to the path is denied.")
        #expect(BrowserSpaceOpenError.placeholder("").errorDescription
                == "The host did not say where its profile is, so the browser space helper has nowhere to go.")
        #expect(BrowserSpaceOpenError.missingPlaceholder.errorDescription
                == "This build is missing the browser space helper.")
    }

    @Test func thisBuildCarriesThePlaceholder() throws {
        let script = try #require(BrowserSpaceOpener.bundledPlaceholder())
        #expect(script.hasPrefix("#!/bin/sh"))
        #expect(script.contains("[[AIM-BROWSER $id ${cols}x${rows}]]"))
    }
}

/// A Windows host runs Herdr's panes in PowerShell, not `sh`: the placeholder is
/// a PowerShell script, it goes over SFTP, and every command sent is one
/// Windows PowerShell 5.1 can read.
@Suite struct BrowserSpaceOnWindowsTests {
    private static let created = #"{"id":"cli:workspace:create","result":{"root_pane":{"pane_id":"w2:p1","tab_id":"w2:t1"},"type":"workspace_created","workspace":{"workspace_id":"w2"}}}"#
    private static let path = "C:/Users/alice/.local/share/msam/browser-space.ps1"
    private static let line = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File \(path) 7f3a2c"

    private func service() async throws -> (SSHService, FakeSSHTransport) {
        let transport = FakeSSHTransport()
        // What the connection asks to tell Windows from everything else.
        transport.commandResponses["echo %OS% $env:OS"] = "Windows_NT"
        let host = Host(name: "Windows", address: "192.0.2.30", port: 22, username: "alice", keyID: "test-key", defaultWorkdir: "")
        let defaults = try #require(UserDefaults(suiteName: "browser-space-windows-\(UUID().uuidString)"))
        let service = SSHService(host: host, transport: transport, knownHosts: KnownHostsStore(defaults: defaults))
        try await service.connect(key: SSHKeyMaterial(ed25519Seed: Data(repeating: 7, count: 32))) { _, _ in true }
        #expect(service.isWindows)
        return (service, transport)
    }

    /// The scripts sent after connecting, as PowerShell is given them.
    private func scripts(on transport: FakeSSHTransport) -> [String] {
        transport.structuredCommandsRun.map(\.command).filter { !$0.hasPrefix("echo %OS%") }
            .map { WindowsHostFixture.script($0) ?? "NOT POWERSHELL: \($0)" }
    }

    private func result(_ status: Int32, _ out: String = "", _ err: String = "") -> Result<SSHCommandResult, SSHCommandExecutionError> {
        .success(SSHCommandResult(exitStatus: status, stdout: Data(out.utf8), stderr: Data(err.utf8)))
    }

    @Test func namesAreQuotedTheWayPowerShellReadsThem() {
        #expect(BrowserSpaceCommands.createSpace(sessionName: nil, windows: true)
                == "herdr workspace create --label 'Browser' --focus")
        // A POSIX shell closes the quote, escapes one and opens it again;
        // PowerShell doubles it.
        #expect(BrowserSpaceCommands.createSpace(sessionName: "rufus's", windows: true)
                == "herdr --session 'rufus''s' workspace create --label 'Browser' --focus")
        #expect(BrowserSpaceCommands.createSpace(sessionName: "rufus's")
                == #"herdr --session 'rufus'\''s' workspace create --label 'Browser' --focus"#)
    }

    @Test func theFolderIsMadeByAScriptWindowsPowerShellCanRead() throws {
        let script = try #require(WindowsHostFixture.script(BrowserSpaceCommands.windowsPrepareCommand))
        // Windows PowerShell 5.1 has no `&&`, and its `mkdir` takes no `-p`.
        #expect(!script.contains("&&"))
        #expect(!script.contains("mkdir"))
        #expect(script.contains("$env:USERPROFILE"))
        #expect(script.contains(#"'.local\share\msam'"#))
        #expect(script.contains("'MSAM_HOME='"))
        #expect(script.contains("'MSAM_FAILED='"))
    }

    @Test func theProfileIsReadFromTheHostsAnswer() throws {
        #expect(try BrowserSpaceCommands.windowsProfile(fromAnswer: "MSAM_HOME=C:\\Users\\alice\r\n") == "C:\\Users\\alice")
        // Something a profile script printed first does not count.
        #expect(try BrowserSpaceCommands.windowsProfile(fromAnswer: "hello\r\nMSAM_HOME=D:\\Profiles\\Jane Smith\r\n")
                == "D:\\Profiles\\Jane Smith")
    }

    @Test func aHostThatCouldNotMakeTheFolderSaysWhy() {
        #expect(throws: BrowserSpaceOpenError.placeholder("Access to the path 'C:\\Users\\alice\\.local' is denied.")) {
            try BrowserSpaceCommands.windowsProfile(
                fromAnswer: "MSAM_FAILED=Access to the path 'C:\\Users\\alice\\.local' is denied.\r\n")
        }
    }

    @Test(arguments: ["", "MSAM_HOME=\r\n", "MSAM_HOME=/home/alice\n", "C:\\Users\\alice\r\n"])
    func anAnswerWithoutAProfileIsNoPlaceToWriteTo(answer: String) {
        #expect(throws: BrowserSpaceOpenError.placeholder("")) {
            try BrowserSpaceCommands.windowsProfile(fromAnswer: answer)
        }
    }

    @Test func thePlaceholderIsNamedTheWaySFTPAndEveryShellTakeIt() {
        // Forward slashes: SFTP on Windows wants them, PowerShell and cmd take
        // them, and a pane that runs another shell does not read them as escapes.
        #expect(BrowserSpaceCommands.windowsScriptPath(home: "C:\\Users\\alice") == Self.path)
        #expect(BrowserSpaceCommands.windowsScriptPath(home: "C:\\Users\\alice\\") == Self.path)
    }

    @Test func theLineTypedIntoThePaneStartsThePlaceholderInWindowsPowerShell() {
        // powershell.exe is on every Windows; the pane's own shell may be
        // PowerShell 7 or cmd, and this line reads the same in all of them.
        #expect(BrowserSpaceCommands.windowsPlaceholderLine(path: Self.path, id: "7f3a2c") == Self.line)
    }

    @Test func aProfileWithASpaceInItsNameIsTypedInQuotes() {
        #expect(BrowserSpaceCommands.windowsPlaceholderLine(
            path: "C:/Users/Jane Smith/.local/share/msam/browser-space.ps1", id: "7f3a2c")
            == #"powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "C:/Users/Jane Smith/.local/share/msam/browser-space.ps1" 7f3a2c"#)
        #expect(BrowserSpaceCommands.windowsPlaceholderLine(
            path: "C:/Users/R&D/.local/share/msam/browser-space.ps1", id: "7f3a2c")
            .contains(#"-File "C:/Users/R&D/.local/share/msam/browser-space.ps1" "#))
    }

    @Test func theLineReachesHerdrAsOneArgument() {
        #expect(BrowserSpaceCommands.runWindowsPlaceholder(path: Self.path, paneID: "w2:p1", id: "7f3a2c", sessionName: "work")
                == "herdr --session 'work' pane run 'w2:p1' '\(Self.line)'")
    }

    @Test func quotesInTheLineAreEscapedForTheProgramWindowsPowerShellStarts() {
        // Windows PowerShell 5.1 wraps an argument with a space in double
        // quotes but leaves the double quotes inside it alone, so Herdr would
        // be handed the line in pieces. Escaped, it arrives whole.
        let command = BrowserSpaceCommands.runWindowsPlaceholder(
            path: "C:/Users/Jane Smith/.local/share/msam/browser-space.ps1", paneID: "w2:p1", id: "7f3a2c", sessionName: nil)
        #expect(command == #"herdr pane run 'w2:p1' 'powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File \"C:/Users/Jane Smith/.local/share/msam/browser-space.ps1\" 7f3a2c'"#)
    }

    @Test func openingPutsThePlaceholderOnTheHostThenMakesTheSpaceAndStartsIt() async throws {
        let (service, transport) = try await service()
        transport.structuredCommandResults = [
            result(0, "MSAM_HOME=C:\\Users\\alice\r\n"), result(0, Self.created + "\r\n"), result(0),
        ]

        let id = try await BrowserSpaceOpener.open(using: service, sessionName: "work", script: "param($id)\n", id: "7f3a2c")

        #expect(id == "7f3a2c")
        #expect(transport.writtenFiles == [Self.path: Data("param($id)\n".utf8)])
        let scripts = scripts(on: transport)
        #expect(scripts.count == 3)
        guard scripts.count == 3 else { return }
        #expect(scripts[0].contains("'MSAM_HOME='"))
        #expect(scripts[1].contains("herdr --session 'work' workspace create --label 'Browser' --focus"))
        #expect(scripts[2].contains("herdr --session 'work' pane run 'w2:p1' '\(Self.line)'"))
        // Nothing a Unix shell would have been sent.
        for script in scripts {
            #expect(!script.contains("$HOME") && !script.contains("exec sh") && !script.contains("<<"), "\(script)")
        }
    }

    @Test func aHostThatCannotTakeThePlaceholderGetsNoSpace() async throws {
        let (service, transport) = try await service()
        transport.structuredCommandResults = [result(0, "MSAM_FAILED=Access to the path is denied.\r\n")]

        await #expect(throws: BrowserSpaceOpenError.placeholder("Access to the path is denied.")) {
            _ = try await BrowserSpaceOpener.open(using: service, sessionName: nil, script: "param($id)\n", id: "7f3a2c")
        }
        // An empty "Browser" space with a bare prompt in it would be left behind.
        #expect(scripts(on: transport).count == 1)
        #expect(transport.writtenFiles.isEmpty)
    }

    @Test func aQuestionThatFailedPassesOnWhatTheHostSaid() async throws {
        let (service, transport) = try await service()
        transport.structuredCommandResults = [result(1, "", "powershell.exe : The term is not recognized\r\n")]

        await #expect(throws: BrowserSpaceOpenError.placeholder("powershell.exe : The term is not recognized")) {
            _ = try await BrowserSpaceOpener.open(using: service, sessionName: nil, script: "param($id)\n", id: "7f3a2c")
        }
    }

    @Test func aPlaceholderThatCouldNotBeWrittenGetsNoSpace() async throws {
        let (service, transport) = try await service()
        transport.structuredCommandResults = [result(0, "MSAM_HOME=C:\\Users\\alice\r\n")]
        transport.writeFileError = SSHTransportError.commandFailed("upload to \(Self.path) failed: permission denied")

        await #expect(throws: BrowserSpaceOpenError.self) {
            _ = try await BrowserSpaceOpener.open(using: service, sessionName: nil, script: "param($id)\n", id: "7f3a2c")
        }
        #expect(scripts(on: transport).count == 1, "The space is not made before its placeholder is there")
    }

    @Test func aHerdrThatRefusesIsQuotedOnWindowsToo() async throws {
        let (service, transport) = try await service()
        transport.structuredCommandResults = [
            result(0, "MSAM_HOME=C:\\Users\\alice\r\n"), result(1, "", "herdr: no server running\r\n"),
        ]

        await #expect(throws: BrowserSpaceOpenError.herdr("herdr: no server running")) {
            _ = try await BrowserSpaceOpener.open(using: service, sessionName: nil, script: "param($id)\n", id: "7f3a2c")
        }
        #expect(scripts(on: transport).count == 2, "Nothing is run in a pane that was not made")
    }

    @Test func eachSystemIsGivenItsOwnPlaceholder() async throws {
        let (service, transport) = try await service()
        transport.structuredCommandResults = [
            result(0, "MSAM_HOME=C:\\Users\\alice\r\n"), result(0, Self.created), result(0),
        ]

        try await BrowserSpaceOpener.open(using: service, sessionName: nil, id: "7f3a2c")

        let written = try #require(transport.writtenFiles[Self.path])
        #expect(String(decoding: written, as: UTF8.self) == BrowserSpaceOpener.bundledPlaceholder(windows: true))
    }

    @Test func thisBuildCarriesTheWindowsPlaceholder() throws {
        let script = try #require(BrowserSpaceOpener.bundledPlaceholder(windows: true))
        // Windows PowerShell reads a script without a byte order mark in the
        // system's own code page: one character outside ASCII and the fill or
        // the mark would not be what the app looks for.
        let ascii = script.unicodeScalars.allSatisfy { $0.isASCII }
        #expect(ascii)
        #expect(script.contains("param([string]$id"))
        // The fill, U+2591, and the mark, exactly as the locator reads them.
        #expect(script.contains("[char]0x2591"))
        #expect(BrowserSpaceMarker.fill == "\u{2591}")
        #expect(script.contains(#""[[AIM-BROWSER $id $($size.Width)x$($size.Height)]]""#))
        #expect(BrowserSpaceMarker.text(id: "7f3a2c", columns: 113, rows: 39) == "[[AIM-BROWSER 7f3a2c 113x39]]")
        // And the Unix one is still the Unix one.
        #expect(BrowserSpaceOpener.bundledPlaceholder(windows: false)?.hasPrefix("#!/bin/sh") == true)
    }
}
