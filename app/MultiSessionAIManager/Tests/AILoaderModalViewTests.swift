import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct AILoaderModalViewTests {
    @Test func stateInitializesWithDefaults() {
        let term = TerminalAgentSession(
            paneID: "wQ:p2",
            tabID: "wQ:t1",
            name: "test-agent",
            provider: "claude",
            project: "/tmp/project"
        )
        let state = AILoaderState(
            provider: "codex",
            terminal: term
        )
        #expect(state.provider == "codex")
        #expect(state.terminal.paneID == "wQ:p2")
        #expect(state.statusMessage == "Analyzing previous session task…")
        #expect(state.isComplete == false)
    }

    @Test func stateAllowsCustomStatusAndDetails() {
        let term = TerminalAgentSession(
            paneID: "wD:p7",
            name: "worker",
            provider: "codex",
            project: "/home"
        )
        var state = AILoaderState(
            provider: "antigravity",
            terminal: term,
            statusMessage: "Recommended: gemini-2.5-pro",
            detailedMessage: "Project: /home"
        )
        #expect(state.statusMessage == "Recommended: gemini-2.5-pro")
        #expect(state.detailedMessage == "Project: /home")

        state.isComplete = true
        #expect(state.isComplete == true)
    }
}
