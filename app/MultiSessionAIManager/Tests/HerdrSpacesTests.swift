import Foundation
import Testing
@testable import MultiSessionAIManager

/// The spaces of a Herdr session, as the phone's drawer lists them.
@Suite struct HerdrSpacesTests {
    private let answer = """
    {"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[
    {"active_tab_id":"w1:t1","agent_status":"working","focused":false,"label":"api server","number":1,"pane_count":2,"tab_count":1,"workspace_id":"w1"},
    {"active_tab_id":"w2:t1","agent_status":"blocked","focused":true,"label":"billing","number":2,"pane_count":1,"tab_count":3,"workspace_id":"w2"},
    {"active_tab_id":"w3:t1","agent_status":"unknown","focused":false,"label":"","number":3,"pane_count":1,"tab_count":1,"workspace_id":"w3"}
    ]}}
    """

    @Test func theAnswerIsReadInHerdrsOrderWithNameFocusAndAgentState() throws {
        let spaces = try #require(HerdrSpaceCommands.spaces(fromAnswer: answer))
        #expect(spaces.map(\.id) == ["w1", "w2", "w3"])
        #expect(spaces.map(\.name) == ["api server", "billing", "Space 3"])
        #expect(spaces.map(\.isFocused) == [false, true, false])
        #expect(spaces.map(\.status) == [.working, .blocked, .unknown])
    }

    /// A login banner before the JSON, or a prompt after it, is not part of it.
    @Test func textAroundTheAnswerIsIgnoredAndSomethingElseIsNotAList() {
        #expect(HerdrSpaceCommands.spaces(fromAnswer: "Welcome\n" + answer + "\n$ ")?.count == 3)
        #expect(HerdrSpaceCommands.spaces(fromAnswer: "herdr: no server is running") == nil)
        #expect(HerdrSpaceCommands.spaces(fromAnswer: "") == nil)
        #expect(HerdrSpaceCommands.spaces(fromAnswer: #"{"id":"x","result":{"type":"workspace_list","workspaces":[]}}"#) == [])
    }

    @Test func eachSpaceSaysWhatItsAgentsAreDoing() throws {
        func detail(_ status: HerdrAgentLifecycle) -> String {
            HerdrSpace(id: "w", name: "n", isFocused: false, status: status).detail
        }
        #expect(detail(.working) == "Working")
        #expect(detail(.blocked) == "Waiting for you")
        #expect(detail(.idle) == "Idle")
        #expect(detail(.done) == "Done")
        #expect(detail(.error) == "Error")
        #expect(detail(.unknown) == "No agent")
    }

    @Test func theSummaryCountsWhatMattersAndLeavesOutWhatIsZero() throws {
        let spaces = try #require(HerdrSpaceCommands.spaces(fromAnswer: answer))
        #expect(HerdrSpace.summary(of: spaces) == "1 waiting · 1 working")
        #expect(HerdrSpace.waitingCount(in: spaces) == 1)
        let idle = [HerdrSpace(id: "a", name: "a", isFocused: true, status: .idle),
                    HerdrSpace(id: "b", name: "b", isFocused: false, status: .idle)]
        #expect(HerdrSpace.summary(of: idle) == "2 idle")
        #expect(HerdrSpace.waitingCount(in: idle) == 0)
        #expect(HerdrSpace.summary(of: []) == "")
    }

    @Test func theTopLineNamesTheSpaceOnScreenOverItsHost() throws {
        let spaces = try #require(HerdrSpaceCommands.spaces(fromAnswer: answer))
        let heading = HerdrSpace.heading(host: "Build host", spaces: spaces)
        #expect(heading.title == "billing")
        #expect(heading.subtitle == "Build host · 1 waiting · 1 working")
        // Until the spaces are known, the host is all there is to say.
        let unknown = HerdrSpace.heading(host: "Build host", spaces: [])
        #expect(unknown.title == "Build host")
        #expect(unknown.subtitle == "")
    }

    @Test func theCommandsSpeakToTheTabsOwnSession() {
        #expect(HerdrSpaceCommands.list(sessionName: nil) == "herdr workspace list")
        #expect(HerdrSpaceCommands.list(sessionName: "work") == "herdr --session 'work' workspace list")
        #expect(HerdrSpaceCommands.focus("w2", sessionName: nil) == "herdr workspace focus 'w2'")
        #expect(HerdrSpaceCommands.focus("w2", sessionName: "work") == "herdr --session 'work' workspace focus 'w2'")
        #expect(HerdrSpaceCommands.create(sessionName: nil) == "herdr workspace create --focus")
    }

    /// The id comes from the host. One that is not an id is never put in a command.
    @Test func anIdThatIsNotAnIdIsNotSent() {
        #expect(HerdrSpaceCommands.focus("w2; rm -rf ~", sessionName: nil) == nil)
        #expect(HerdrSpaceCommands.focus("", sessionName: nil) == nil)
        #expect(HerdrSpaceCommands.focus("w1:t1", sessionName: nil) != nil)
    }
}

@MainActor
@Suite struct HerdrSpaceListTests {
    /// Stands in for the SSH connection: records what was asked, answers from a queue.
    @MainActor private final class Host {
        var asked: [String] = []
        var answers: [Result<String, Error>] = []
        func run(_ command: String) async throws -> String {
            asked.append(command)
            guard !answers.isEmpty else { return "" }
            return try answers.removeFirst().get()
        }
    }
    private struct Failed: Error, LocalizedError {
        var errorDescription: String? { "connection lost" }
    }

    private func listing(focused: String) -> String {
        let spaces = ["w1": "api server", "w2": "billing"].sorted { $0.key < $1.key }.map { id, name in
            #"{"agent_status":"idle","focused":\#(id == focused),"label":"\#(name)","number":1,"pane_count":1,"tab_count":1,"workspace_id":"\#(id)"}"#
        }
        return #"{"id":"cli:workspace:list","result":{"type":"workspace_list","workspaces":[\#(spaces.joined(separator: ","))]}}"#
    }

    @Test func refreshingAsksTheHostAndKeepsWhatItAnswers() async {
        let host = Host()
        host.answers = [.success(listing(focused: "w1"))]
        let list = HerdrSpaceList()

        await list.refresh(sessionName: "work", run: host.run)

        #expect(host.asked == ["herdr --session 'work' workspace list"])
        #expect(list.spaces.map(\.name) == ["api server", "billing"])
        #expect(list.current?.id == "w1")
        #expect(list.failure == nil)
    }

    @Test func choosingASpaceFocusesItAndListsAgain() async {
        let host = Host()
        host.answers = [.success(listing(focused: "w1"))]
        let list = HerdrSpaceList()
        await list.refresh(sessionName: nil, run: host.run)

        host.answers = [.success("{}"), .success(listing(focused: "w2"))]
        await list.focus(list.spaces[1], sessionName: nil, run: host.run)

        #expect(host.asked.suffix(2) == ["herdr workspace focus 'w2'", "herdr workspace list"])
        #expect(list.current?.id == "w2")
    }

    @Test func aListingThatFailsKeepsTheOldListAndSaysWhy() async {
        let host = Host()
        host.answers = [.success(listing(focused: "w1"))]
        let list = HerdrSpaceList()
        await list.refresh(sessionName: nil, run: host.run)

        host.answers = [.failure(Failed())]
        await list.refresh(sessionName: nil, run: host.run)

        #expect(list.spaces.count == 2, "what was known stays on screen")
        #expect(list.failure == "connection lost")

        // And an answer that is not a list says so without emptying it either.
        host.answers = [.success("herdr: no server is running")]
        await list.refresh(sessionName: nil, run: host.run)
        #expect(list.spaces.count == 2)
        #expect(list.failure != nil)

        host.answers = [.success(listing(focused: "w2"))]
        await list.refresh(sessionName: nil, run: host.run)
        #expect(list.failure == nil)
    }

    @Test func aNewSpaceIsCreatedFocusedAndTheListIsReadAgain() async {
        let host = Host()
        host.answers = [.success("{}"), .success(listing(focused: "w2"))]
        let list = HerdrSpaceList()

        await list.create(sessionName: nil, run: host.run)

        #expect(host.asked == ["herdr workspace create --focus", "herdr workspace list"])
        #expect(list.current?.id == "w2")
    }
}
