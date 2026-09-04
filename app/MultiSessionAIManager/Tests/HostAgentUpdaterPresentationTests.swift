import Testing
@testable import MultiSessionAIManager

@Suite struct HostAgentUpdaterPresentationTests {
    @Test func readyHasNoWarningAndEveryDegradedChoiceExplainsTheImpact() {
        #expect(HostAgentUpdaterPresentation.warning(for: .ready) == nil)
        for setup in [HostAgentUpdaterSetup.unchecked, .skipped, .failed] {
            let warning = HostAgentUpdaterPresentation.warning(for: setup) ?? ""
            #expect(warning.contains("background version checks"))
            #expect(warning.contains("durable update queue"))
            #expect(warning.contains("disconnected rolling restores"))
        }
    }

    @Test func manualGatekeeperIsDefaultAndVerifiedCopyDoesNotPromiseBypass() {
        let host = Host(name: "h", address: "host", username: "alice", keyID: "k",
                        defaultWorkdir: "/tmp")
        #expect(host.gatekeeperPolicy == .manualApproval)
        let manual = HostAgentUpdaterPresentation.gatekeeperDetail(for: .manualApproval)
        let verified = HostAgentUpdaterPresentation.gatekeeperDetail(for: .verifiedVendorArtifacts)
        #expect(manual.contains("Open"))
        #expect(verified.contains("exact installed artifact"))
        #expect(verified.contains("signature"))
        #expect(verified.contains("notarization"))
        #expect(verified.contains("publisher identity"))
        #expect(!verified.lowercased().contains("bypass"))
        #expect(!verified.lowercased().contains("anywhere"))
    }

    @Test func approvalKindsHaveDistinctActionableCopy() {
        let mac = HostAgentUpdaterPresentation.approval(
            .macOSLoginDomain(["Sign in to the Mac desktop", "Tap Test Again"])
        )
        let linux = HostAgentUpdaterPresentation.approval(
            .linuxLingerDisabled(["loginctl enable-linger alice", "Tap Test Again"])
        )
        let admin = HostAgentUpdaterPresentation.approval(
            .administratorAction(["Ask an administrator"])
        )
        let unsupported = HostAgentUpdaterPresentation.approval(
            .unsupportedPlatform("FreeBSD is unsupported")
        )

        #expect(Set([mac.title, linux.title, admin.title, unsupported.title]).count == 4)
        #expect(mac.instructions.joined().contains("Mac"))
        #expect(linux.instructions.joined().contains("loginctl"))
        #expect(admin.instructions.joined().contains("administrator"))
        #expect(unsupported.instructions.joined().contains("unsupported"))
    }

    @Test func skipAndVerificationOutcomesPersistWithoutChangingConnectionFields() {
        let host = Host(name: "h", address: "host", username: "alice", keyID: "k",
                        defaultWorkdir: "/tmp")
        let skipped = HostAgentUpdaterPresentation.applying(
            setup: .skipped,
            policy: .manualApproval,
            to: host
        )
        let ready = HostAgentUpdaterPresentation.applying(
            setup: .ready,
            policy: .verifiedVendorArtifacts,
            to: skipped
        )
        let failed = HostAgentUpdaterPresentation.applying(
            setup: .failed,
            policy: .manualApproval,
            to: ready
        )

        #expect(skipped.agentUpdaterSetup == .skipped)
        #expect(ready.agentUpdaterSetup == .ready)
        #expect(ready.gatekeeperPolicy == .verifiedVendorArtifacts)
        #expect(failed.agentUpdaterSetup == .failed)
        #expect(failed.address == host.address)
        #expect(failed.keyID == host.keyID)
    }
}
