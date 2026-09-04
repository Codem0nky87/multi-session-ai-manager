import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct AgentUpdateRequestTests {
    private let batchID = UUID(uuidString: "12345678-1234-1234-1234-1234567890AB")!

    @Test func crossToolRequestSerializesDeterministicallyWithoutACommandField() throws {
        let request = AgentUpdateRequest(
            protocolVersion: 1,
            batchID: batchID,
            requestedTools: [.codex],
            targets: [
                target(tool: .antigravity, pane: "%3", conversation: "agy-3"),
                target(tool: .claude, pane: "%1", conversation: "claude-1"),
                target(tool: .codex, pane: "%2", conversation: "codex-2")
            ],
            gatekeeperPolicy: .manualApproval
        )

        let serialized = try request.serialized()

        #expect(serialized == """
        MSAM_AGENT_UPDATE_REQUEST\t1
        BATCH\t12345678-1234-1234-1234-1234567890AB
        POLICY\tmanualApproval
        UPDATE\tcodex
        TARGET\tdefault\t/tmp/herdr.sock\t%1\t101\tclaude\tclaude-1
        TARGET\tdefault\t/tmp/herdr.sock\t%2\t101\tcodex\tcodex-2
        TARGET\tdefault\t/tmp/herdr.sock\t%3\t101\tantigravity\tagy-3
        END

        """)
        #expect(!serialized.lowercased().contains("command"))
    }

    @Test func targetOrderDoesNotChangeSerialization() throws {
        let one = target(tool: .claude, pane: "%1", conversation: "c1")
        let two = target(tool: .codex, pane: "%2", conversation: "c2")
        let base = AgentUpdateRequest(
            protocolVersion: 1,
            batchID: batchID,
            requestedTools: [.claude, .codex],
            targets: [one, two],
            gatekeeperPolicy: .verifiedVendorArtifacts
        )
        let reversed = AgentUpdateRequest(
            protocolVersion: 1,
            batchID: batchID,
            requestedTools: [.codex, .claude],
            targets: [two, one],
            gatekeeperPolicy: .verifiedVendorArtifacts
        )

        #expect(try base.serialized() == reversed.serialized())
    }

    @Test func unsupportedProtocolAndEmptyUpdatesAreRejected() {
        var request = validRequest()
        request.protocolVersion = 2
        #expect(throws: AgentUpdateRequestValidationError.unsupportedProtocol(2)) {
            try request.validate()
        }

        request = validRequest()
        request.requestedTools = []
        #expect(throws: AgentUpdateRequestValidationError.noRequestedTools) {
            try request.validate()
        }
    }

    @Test func duplicatePaneTargetsAreRejected() {
        var request = validRequest()
        request.targets.append(request.targets[0])

        #expect(throws: AgentUpdateRequestValidationError.duplicateTarget("/tmp/herdr.sock:%1")) {
            try request.validate()
        }
    }

    @Test(arguments: ["relative/socket", "", "socket\nname", "socket\tname", "socket\0name"])
    func socketPathMustBeAbsoluteBoundedAndLineSafe(_ socket: String) {
        var request = validRequest()
        request.targets[0].socketPath = socket

        #expect(throws: AgentUpdateRequestValidationError.invalidSocketPath) {
            try request.validate()
        }
    }

    @Test(arguments: ["", "pane 1", "%1\nNEXT", "%1\tNEXT", "%1\0NEXT", String(repeating: "1", count: 129)])
    func paneIdentifierMustBeBoundedAndAllowlisted(_ pane: String) {
        var request = validRequest()
        request.targets[0].paneID = pane

        #expect(throws: AgentUpdateRequestValidationError.invalidPaneID) {
            try request.validate()
        }
    }

    @Test func conversationAndSessionFieldsRejectLineInjectionAndUnboundedValues() {
        for invalid in ["", "line\nnext", "tab\tnext", "nul\0next", String(repeating: "x", count: 2_049)] {
            var request = validRequest()
            request.targets[0].conversationID = invalid
            #expect(throws: AgentUpdateRequestValidationError.invalidConversationID) {
                try request.validate()
            }
        }

        var request = validRequest()
        request.targets[0].herdrSession = "bad\nSESSION"
        #expect(throws: AgentUpdateRequestValidationError.invalidSession) {
            try request.validate()
        }
    }

    @Test func unsupportedToolRawValueCannotDecodeIntoARequest() throws {
        let json = """
        {
          "protocolVersion": 1,
          "batchID": "\(batchID.uuidString)",
          "requestedTools": ["other-agent"],
          "targets": [],
          "gatekeeperPolicy": "manualApproval"
        }
        """

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AgentUpdateRequest.self, from: Data(json.utf8))
        }
    }

    private func validRequest() -> AgentUpdateRequest {
        AgentUpdateRequest(
            protocolVersion: 1,
            batchID: batchID,
            requestedTools: [.codex],
            targets: [target(tool: .codex, pane: "%1", conversation: "thread-1")],
            gatekeeperPolicy: .manualApproval
        )
    }

    private func target(
        tool: AgentToolID,
        pane: String,
        conversation: String
    ) -> AgentRollTarget {
        AgentRollTarget(
            herdrSession: "default",
            socketPath: "/tmp/herdr.sock",
            paneID: pane,
            foregroundPID: 101,
            tool: tool,
            conversationID: conversation
        )
    }
}
