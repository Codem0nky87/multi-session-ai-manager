import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct AgentToolRegistryTests {
    @Test func registryHasOnlyTheThreeSupportedToolsInDisplayOrder() {
        let definitions = AgentToolRegistry.definitions

        #expect(definitions.map(\.id) == [.claude, .codex, .antigravity])
        #expect(definitions.map(\.displayName) == ["Claude Code", "Codex", "Antigravity"])
        #expect(Set(definitions.map(\.executable)) == ["claude", "codex", "agy"])
    }

    @Test func registryUsesDocumentedHerdrKindsAndCleanExitCommand() {
        let claude = AgentToolRegistry.definition(for: .claude)
        let codex = AgentToolRegistry.definition(for: .codex)
        let antigravity = AgentToolRegistry.definition(for: .antigravity)

        #expect(claude.herdrKinds == ["claude"])
        #expect(codex.herdrKinds == ["codex"])
        #expect(antigravity.herdrKinds == ["agy", "antigravity-cli"])
        #expect(AgentToolRegistry.definitions.allSatisfy { $0.exitCommand == "/exit" })
    }

    @Test func registryBuildsOnlyTheDocumentedResumeArguments() {
        #expect(AgentToolRegistry.definition(for: .claude).resumeArguments("conversation-1")
            == ["--resume", "conversation-1"])
        #expect(AgentToolRegistry.definition(for: .codex).resumeArguments("thread-2")
            == ["resume", "thread-2"])
        #expect(AgentToolRegistry.definition(for: .antigravity).resumeArguments("chat-3")
            == ["--conversation", "chat-3"])
    }
}

@Suite struct AgentVersionTests {
    @Test(arguments: [
        ("Claude Code v2.1.260 (native)", "2.1.260"),
        ("codex-cli 0.153.2", "0.153.2"),
        ("Antigravity CLI version 1.1.26-beta.3+arm64", "1.1.26-beta.3+arm64")
    ])
    func vendorVersionOutputIsParsed(_ output: String, _ expected: String) {
        #expect(AgentVersionParser.version(in: output) == expected)
    }

    @Test func numericComponentsAreComparedNumerically() {
        #expect(AgentVersionComparator.isNewer("2.1.10", than: "2.1.9"))
        #expect(!AgentVersionComparator.isNewer("2.1.9", than: "2.1.10"))
    }

    @Test func prereleaseOrderingIsDeterministic() {
        #expect(AgentVersionComparator.isNewer("2.1.0", than: "2.1.0-beta.10"))
        #expect(AgentVersionComparator.isNewer("2.1.0-beta.10", than: "2.1.0-beta.2"))
        #expect(!AgentVersionComparator.isNewer("2.1.0-beta.2", than: "2.1.0-beta.10"))
    }

    @Test func malformedOrUnknownVersionsNeverOfferAnUpdate() {
        #expect(AgentVersionParser.version(in: "Claude Code unknown") == nil)
        #expect(!AgentVersionComparator.isNewer("latest", than: "2.1.0"))
        #expect(!AgentVersionComparator.isNewer("2.1.1", than: "unknown"))

        let unknownLatest = AgentToolVersion(
            tool: .claude,
            installed: "2.1.0",
            latest: nil,
            channel: "latest",
            method: .native,
            executablePath: "/Users/alice/.local/bin/claude",
            error: "latest lookup failed"
        )
        #expect(!unknownLatest.isUpdateAvailable)
    }

    @Test(arguments: [
        ("homebrew", AgentInstallMethod.homebrew),
        ("npm", AgentInstallMethod.npm),
        ("pnpm", AgentInstallMethod.pnpm),
        ("bun", AgentInstallMethod.bun),
        ("native", AgentInstallMethod.native),
        ("ambiguous", AgentInstallMethod.ambiguous),
        ("something-new", AgentInstallMethod.unknown)
    ])
    func installationOwnerMarkersAreParsed(_ marker: String, _ expected: AgentInstallMethod) {
        #expect(AgentInstallMethod.parse(marker) == expected)
    }
}
