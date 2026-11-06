import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct HerdrSessionRolloverTests {
    @Test func makeAnalysisCommandQuotesArguments() {
        let cmd = HerdrSessionRollover.makeAnalysisCommand(
            transcriptPath: "/tmp/path with space/turn.jsonl",
            provider: "codex"
        )
        #expect(cmd.contains("analyze-task"))
        #expect(cmd.contains("'/tmp/path with space/turn.jsonl'"))
        #expect(cmd.contains("'codex'"))
        #expect(cmd.contains("PATH=\"$HOME/.local/bin:$PATH\""))
    }

    @Test func parseAnalysisResultDecodesValidJSON() {
        let json = "{\"model\": \"gpt-6.1-sol\", \"effort\": \"high\", \"is_complex\": true, \"summary\": \"Deep reasoning recommended\"}"
        let result = HerdrSessionRollover.parseAnalysisResult(json: json)
        #expect(result?.model == "gpt-6.1-sol")
        #expect(result?.effort == "high")
        #expect(result?.isComplex == true)
        #expect(result?.summary == "Deep reasoning recommended")
    }

    @Test func parseAnalysisResultHandlesSurroundingLogOutput() {
        let output = "INFO: running analyzer\n{\"model\": \"gemini-2.5-pro\", \"effort\": \"medium\"}\nDEBUG: finished"
        let result = HerdrSessionRollover.parseAnalysisResult(json: output)
        #expect(result?.model == "gemini-2.5-pro")
        #expect(result?.effort == "medium")
    }

    @Test func extractWorkspaceIDParsesColonPrefix() {
        #expect(HerdrSessionRollover.extractWorkspaceID(from: "wQ:t1") == "wQ")
        #expect(HerdrSessionRollover.extractWorkspaceID(from: "wD:t7") == "wD")
        #expect(HerdrSessionRollover.extractWorkspaceID(from: "workspace") == "workspace")
        #expect(HerdrSessionRollover.extractWorkspaceID(from: "") == nil)
    }

    @Test func makeCreateTabCommandIncludesWorkspaceAndFocus() {
        let cmd = HerdrSessionRollover.makeCreateTabCommand(
            workspaceID: "wQ",
            cwd: "/home/rufus/Projects/IronMentor",
            label: "Codex - Resume"
        )
        #expect(cmd.contains("herdr tab create"))
        #expect(cmd.contains("--workspace 'wQ'"))
        #expect(cmd.contains("--cwd '/home/rufus/Projects/IronMentor'"))
        #expect(cmd.contains("--label 'Codex - Resume'"))
        #expect(cmd.contains("--focus"))
    }

    @Test func parseCreatedTabResultExtractsIDs() {
        let json = """
        {"id":"cli:tab:create","result":{"root_pane":{"agent_status":"unknown","cwd":"/home/rufus/Projects/multi-session-ai-manager","focused":false,"pane_id":"wQ:pF","tab_id":"wQ:tE","workspace_id":"wQ"},"tab":{"agent_status":"unknown","focused":false,"label":"msam-test","number":14,"pane_count":1,"tab_id":"wQ:tE","workspace_id":"wQ"},"type":"tab_created"}}
        """
        let ids = HerdrSessionRollover.parseCreatedTabResult(json: json)
        #expect(ids?.tabID == "wQ:tE")
        #expect(ids?.paneID == "wQ:pF")
    }

    @Test func makeRunCommandFormatsCorrectInvocation() {
        let cmd = HerdrSessionRollover.makeRunCommand(paneID: "wQ:pF", command: "codex --yolo")
        #expect(cmd.contains("herdr pane run 'wQ:pF' 'codex --yolo'"))
    }

    @Test func makeLaunchCommandFormatsProvidersProperly() {
        let codex = HerdrSessionRollover.makeLaunchCommand(
            provider: "codex",
            model: "gpt-6.1-sol",
            effort: "high",
            autoApprove: true,
            transcriptPath: "/tmp/t.jsonl",
            project: "/app"
        )
        #expect(codex.contains("codex --model gpt-6.1-sol -c model_effort=high --yolo"))
        #expect(codex.contains("/tmp/t.jsonl"))

        let claude = HerdrSessionRollover.makeLaunchCommand(
            provider: "claude",
            model: "claude-3-7-sonnet",
            effort: "medium",
            autoApprove: true,
            transcriptPath: nil,
            project: "/app"
        )
        #expect(claude.contains("claude --model claude-3-7-sonnet --dangerously-skip-permissions"))

        let agy = HerdrSessionRollover.makeLaunchCommand(
            provider: "antigravity",
            model: "gemini-2.5-pro",
            effort: "high",
            autoApprove: false,
            transcriptPath: nil,
            project: "/app"
        )
        #expect(agy.contains("agy --model gemini-2.5-pro"))
        #expect(!agy.contains("--yolo"))

        let hermes = HerdrSessionRollover.makeLaunchCommand(
            provider: "hermes",
            model: "qwen3.8-flash-next",
            effort: "high",
            autoApprove: true,
            transcriptPath: nil,
            project: "/app"
        )
        #expect(hermes.contains("hermes chat -q"))
        #expect(hermes.contains("--yolo"))
        #expect(hermes.contains("-m qwen3.8-flash-next"))
        #expect(!hermes.contains("-z"))
    }

    @Test func openMonitorWorkspaceCommandIsFormattedProperly() throws {
        let cmd = HerdrSessionRollover.makeOpenMonitorWorkspaceCommand()
        #expect(cmd.contains("PATH=\"$HOME/.local/bin:$PATH\""))
        #expect(cmd.contains("python3 -c"))
        #expect(cmd.contains("import base64;exec(base64.b64decode("))

        guard let firstQuote = cmd.range(of: "base64.b64decode('"),
              let closingQuote = cmd.range(of: "')", range: firstQuote.upperBound..<cmd.endIndex) else {
            Issue.record("Failed to extract base64 payload from open monitor workspace command")
            return
        }
        let b64 = String(cmd[firstQuote.upperBound..<closingQuote.lowerBound])
        let data = try #require(Data(base64Encoded: b64))
        let script = try #require(String(data: data, encoding: .utf8))

        #expect(script.contains("herdr workspace list"))
        #expect(script.contains("\"monitor\""))
        #expect(script.contains("workspace focus"))
        #expect(script.contains("workspace create"))
        #expect(script.contains("--label monitor --focus"))
        #expect(script.contains("herdr pane run"))
        #expect(script.contains("msam-host-agent"))
        #expect(script.contains("monitor"))
        #expect(script.contains("--current"))
    }
}
