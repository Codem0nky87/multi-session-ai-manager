import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct AgentUpdatePresentationTests {
    @Test func rowsDistinguishCurrentAvailableUnknownMissingAndAmbiguous() {
        #expect(AgentUpdatePresentation.row(for: version("1.0.0", "1.0.0", .native)).action == .none)
        #expect(AgentUpdatePresentation.row(for: version("1.0.0", "2.0.0", .native)).action == .update)
        #expect(AgentUpdatePresentation.row(for: version("1.0.0", nil, .native)).action == .refresh)
        #expect(AgentUpdatePresentation.row(for: version(nil, "2.0.0", .unknown)).state == .notInstalled)
        #expect(AgentUpdatePresentation.row(for: version("1.0.0", "2.0.0", .ambiguous)).action == .administratorAction)
    }

    @Test func homebrewCaskOwnershipHasAHumanReadableLabel() {
        let row = AgentUpdatePresentation.row(for: version("1.0.0", "1.0.0", .homebrewCask))

        #expect(row.detail == "Channel: latest · Homebrew cask")
    }

    @Test func serviceStatesChooseSetupRepairApprovalOrAdministratorAction() {
        #expect(AgentUpdatePresentation.serviceAction(setup: .unchecked, installer: .idle) == .completeSetup)
        #expect(AgentUpdatePresentation.serviceAction(
            setup: .failed,
            installer: .failed("broken")
        ) == .repairService)
        #expect(AgentUpdatePresentation.serviceAction(
            setup: .failed,
            installer: .approvalRequired(.macOSLoginDomain(["Sign in"]))
        ) == .approvalRequired)
        #expect(AgentUpdatePresentation.serviceAction(
            setup: .failed,
            installer: .approvalRequired(.administratorAction(["Ask admin"]))
        ) == .administratorAction)
        #expect(AgentUpdatePresentation.serviceAction(
            setup: .ready,
            installer: .ready(.init(
                platform: .macOS, helperProtocol: 1, serviceActive: true,
                stateWritable: true, selfTestPassed: true, lingerEnabled: nil
            ))
        ) == .none)
    }

    @Test func confirmationExplicitlyIncludesEveryAgentAndOrdinaryPaneSafety() {
        let preview = AgentUpdatePreview(
            requestedTools: [.codex],
            request: nil,
            existingBatch: nil,
            totalConversations: 7,
            workingConversations: 2,
            attentionConversations: 1
        )
        let copy = AgentUpdatePresentation.confirmation(for: preview)
        #expect(copy.contains("Claude Code"))
        #expect(copy.contains("Codex"))
        #expect(copy.contains("Antigravity"))
        #expect(copy.contains("all 7"))
        #expect(copy.contains("ordinary panes remain running"))
        #expect(copy.contains("working conversations wait"))
    }

    @Test func confirmationForRollingRelaunchUsesRelaunchCopy() {
        let preview = AgentUpdatePreview(
            requestedTools: [],
            request: nil,
            existingBatch: nil,
            totalConversations: 5,
            workingConversations: 1,
            attentionConversations: 0,
            relaunchTool: nil
        )
        let copy = AgentUpdatePresentation.confirmation(for: preview)
        #expect(copy.contains("All 5 Claude Code, Codex, and Antigravity conversations on this host will roll to restart on the current executables"))
        #expect(copy.contains("ordinary panes remain running"))
        #expect(copy.contains("1 working conversations wait"))
    }

    @Test func confirmationForSingleToolRelaunchNamesSpecificTool() {
        let preview = AgentUpdatePreview(
            requestedTools: [],
            request: nil,
            existingBatch: nil,
            totalConversations: 2,
            workingConversations: 0,
            attentionConversations: 0,
            relaunchTool: .claude
        )
        let copy = AgentUpdatePresentation.confirmation(for: preview)
        #expect(copy.contains("All 2 Claude Code conversations on this host will roll to restart on the current executable"))
        #expect(copy.contains("ordinary panes remain running"))
    }

    @Test func activeProgressIncludesEveryOperationalCount() {
        let status = AgentUpdateBatchStatus(
            id: UUID(), phase: .rolling, approvalTool: nil, total: 12, restored: 4, working: 2,
            attention: 1, retrying: 3, failed: 2, targets: []
        )
        let summary = AgentUpdatePresentation.batchSummary(status)
        for expected in ["4 restored", "2 working", "1 attention", "3 retrying", "2 failed"] {
            #expect(summary.contains(expected))
        }
    }

    @Test func gatekeeperApprovalPhaseIsNotReportedAsFailureOrCompletion() {
        let status = AgentUpdateBatchStatus(
            id: UUID(), phase: .approvalRequired, approvalTool: .codex,
            total: 3, restored: 0, working: 0,
            attention: 3, retrying: 0, failed: 0, targets: []
        )
        #expect(status.isActive)
        #expect(AgentUpdatePresentation.batchTitle(status).contains("Approval Required"))
    }

    private func version(
        _ installed: String?,
        _ latest: String?,
        _ method: AgentInstallMethod
    ) -> AgentToolVersion {
        .init(tool: .codex, installed: installed, latest: latest, channel: "latest",
              method: method, executablePath: installed == nil ? nil : "/bin/codex",
              error: latest == nil ? "latest unavailable" : nil)
    }
}
