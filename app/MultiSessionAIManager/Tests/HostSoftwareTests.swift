import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct HostSoftwareTests {
    @Test func aHostErrorCannotBecomeAnEmptySuccessfulCheck() {
        #expect(throws: HostSoftwareProvisioning.Failure.self) {
            let _: PluginDependencyPlan = try HostSoftwareProvisioning.decode(PluginDependencyPlan.self,
                from: #"MSAM_SOFTWARE={"error":"cargo failed verification"}"#)
        }
    }

    @Test func dependencyPlanKeepsTheVerifiedRevision() throws {
        let plan = try HostSoftwareProvisioning.decode(PluginDependencyPlan.self,
            from: "Downloading…\n" + #"MSAM_SOFTWARE={"source":"owner/plugin","ref":"abc123","pluginID":"plugin","dependencies":[{"tool":"cargo","status":"installed"}]}"#)
        #expect(plan.ref == "abc123")
        #expect(plan.dependencies.first?.status == "installed")
    }

    @Test(arguments: ["ready", "conflict", "unverified", "disabled"])
    func onlyMissingSetupIsActionable(state: String) {
        #expect(!PluginSetupActionStatus(id: "setup", state: state, detail: "").canInstall)
        #expect(PluginSetupActionStatus(id: "setup", state: "missing", detail: "").canInstall)
    }

    @Test func functionKeysUseTerminalSequencesRatherThanLiteralLabels() throws {
        let expected = ["\u{1b}OP", "\u{1b}OQ", "\u{1b}OR", "\u{1b}OS", "\u{1b}[15~", "\u{1b}[17~",
                        "\u{1b}[18~", "\u{1b}[19~", "\u{1b}[20~", "\u{1b}[21~", "\u{1b}[23~", "\u{1b}[24~"]
        for number in 1...12 {
            #expect(TerminalFunctionKey.bytes(for: number) == Array(expected[number - 1].utf8))
        }
        #expect(TerminalFunctionKey.bytes(for: 0) == nil)
        #expect(TerminalFunctionKey.bytes(for: 13) == nil)
    }
}
