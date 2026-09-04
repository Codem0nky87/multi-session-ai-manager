import Foundation

enum AgentUpdateRowState: Equatable, Sendable {
    case current
    case updateAvailable
    case latestUnknown
    case notInstalled
    case ambiguousInstall
}

enum AgentUpdateRowAction: Equatable, Sendable {
    case none
    case update
    case refresh
    case administratorAction
}

struct AgentUpdateRowPresentation: Equatable, Sendable {
    let state: AgentUpdateRowState
    let action: AgentUpdateRowAction
    let status: String
    let detail: String?
}

enum AgentUpdateServiceAction: Equatable, Sendable {
    case none
    case completeSetup
    case repairService
    case approvalRequired
    case administratorAction
}

enum AgentUpdatePresentation {
    static func row(for version: AgentToolVersion) -> AgentUpdateRowPresentation {
        guard let installed = version.installed else {
            return .init(
                state: .notInstalled,
                action: .none,
                status: "Not installed",
                detail: version.error
            )
        }
        if version.method == .ambiguous || version.method == .unknown {
            return .init(
                state: .ambiguousInstall,
                action: .administratorAction,
                status: "Installation owner needs attention",
                detail: "Installed \(installed). Resolve duplicate or unsupported installation ownership on the host before updating."
            )
        }
        guard let latest = version.latest else {
            return .init(
                state: .latestUnknown,
                action: .refresh,
                status: "Installed \(installed) · latest unavailable",
                detail: version.error
            )
        }
        if version.isUpdateAvailable {
            return .init(
                state: .updateAvailable,
                action: .update,
                status: "\(installed) → \(latest)",
                detail: version.channel.map { "Channel: \($0) · \(version.method.displayName)" }
            )
        }
        return .init(
            state: .current,
            action: .none,
            status: "Current · \(installed)",
            detail: version.channel.map { "Channel: \($0) · \(version.method.displayName)" }
        )
    }

    static func serviceAction(
        setup: HostAgentUpdaterSetup,
        installer: AgentUpdaterInstaller.State
    ) -> AgentUpdateServiceAction {
        switch installer {
        case .ready:
            return .none
        case .approvalRequired(.administratorAction),
             .approvalRequired(.linuxLingerDisabled):
            return .administratorAction
        case .approvalRequired:
            return .approvalRequired
        case .failed, .absent:
            return .repairService
        case .idle, .probing, .installing:
            return setup == .ready ? .repairService : .completeSetup
        }
    }

    static func confirmation(for preview: AgentUpdatePreview) -> String {
        let count = preview.totalConversations
        var detail: String
        if preview.requestedTools.isEmpty {
            if let tool = preview.relaunchTool {
                let name = AgentToolRegistry.definition(for: tool).displayName
                detail = "All \(count) \(name) conversations on this host will roll to restart on the current executable; ordinary panes remain running."
            } else {
                detail = "All \(count) Claude Code, Codex, and Antigravity conversations on this host will roll to restart on the current executables; ordinary panes remain running."
            }
        } else {
            detail = "The selected tools will update first, then all \(count) Claude Code, Codex, and Antigravity conversations on this host will roll onto the new executables; ordinary panes remain running."
        }
        if preview.workingConversations > 0 {
            detail += " \(preview.workingConversations) working conversations wait until their current work finishes."
        }
        if preview.attentionConversations > 0 {
            detail += " \(preview.attentionConversations) blocked or unknown conversations remain untouched and need attention."
        }
        return detail
    }

    static func batchTitle(_ status: AgentUpdateBatchStatus) -> String {
        switch status.phase {
        case .idle: "No update queued"
        case .queued: "Queued on host"
        case .updating: "Updating tools"
        case .rolling: "Rolling conversations"
        case .approvalRequired: "Approval Required"
        case .complete: "Update complete"
        case .completedWithFailures: "Completed with failures"
        case .failedUpdate: "Tool update failed"
        case .unknown: "Host status needs attention"
        }
    }

    static func batchSummary(_ status: AgentUpdateBatchStatus) -> String {
        "\(status.restored) restored · \(status.working) working · \(status.attention) attention · \(status.retrying) retrying · \(status.failed) failed"
    }
}
