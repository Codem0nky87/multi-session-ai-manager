import Foundation

struct HostAgentUpdaterApprovalPresentation: Equatable, Sendable {
    let title: String
    let instructions: [String]
}

enum HostAgentUpdaterPresentation {
    static func warning(for setup: HostAgentUpdaterSetup) -> String? {
        switch setup {
        case .ready:
            nil
        case .unchecked:
            degradedWarning(prefix: "Background agent updates have not been set up.")
        case .skipped:
            degradedWarning(prefix: "Background agent updates were skipped.")
        case .failed:
            degradedWarning(prefix: "Background agent update setup needs attention.")
        }
    }

    static func gatekeeperDetail(for policy: HostGatekeeperPolicy) -> String {
        switch policy {
        case .manualApproval:
            "Recommended. If macOS shows a downloaded-app warning, sign in to the host and click Open yourself. The app never controls macOS dialogs."
        case .verifiedVendorArtifacts:
            "On macOS only, clear quarantine for the exact installed artifact after its strict code signature, notarization assessment, and fixed publisher identity all pass. Unsupported or unverifiable artifacts still require manual approval."
        }
    }

    static func approval(
        _ approval: AgentUpdaterApproval
    ) -> HostAgentUpdaterApprovalPresentation {
        switch approval {
        case .macOSLoginDomain(let instructions):
            .init(title: "Mac login required", instructions: instructions)
        case .linuxLingerDisabled(let instructions):
            .init(title: "Linux background permission required", instructions: instructions)
        case .administratorAction(let instructions):
            .init(title: "Administrator action required", instructions: instructions)
        case .unsupportedPlatform(let detail):
            .init(title: "Platform not supported", instructions: [detail])
        }
    }

    static func applying(
        setup: HostAgentUpdaterSetup,
        policy: HostGatekeeperPolicy,
        to host: Host
    ) -> Host {
        var updated = host
        updated.agentUpdaterSetup = setup
        updated.gatekeeperPolicy = policy
        return updated
    }

    private static func degradedWarning(prefix: String) -> String {
        "\(prefix) Until setup succeeds, background version checks, the durable update queue, and disconnected rolling restores are unavailable."
    }
}
