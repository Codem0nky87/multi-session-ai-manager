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
        #expect(BrowserSpaceOpenError.windowsHost.errorDescription == "Browser spaces need a Unix host.")
        #expect(BrowserSpaceOpenError.herdr("herdr: no server running").errorDescription == "herdr: no server running")
        #expect(BrowserSpaceOpenError.herdr("").errorDescription == "Herdr did not create the space.")
    }

    @Test func thisBuildCarriesThePlaceholder() throws {
        let script = try #require(BrowserSpaceOpener.bundledPlaceholder())
        #expect(script.hasPrefix("#!/bin/sh"))
        #expect(script.contains("[[AIM-BROWSER $id ${cols}x${rows}]]"))
    }
}
