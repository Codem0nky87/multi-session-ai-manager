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

@Suite struct AgentToolVersionProbeTests {
    @Test func releaseEndpointsAreFixedVendorSources() {
        #expect(AgentToolReleaseSources.claudeNativeLatest
            == "https://downloads.claude.ai/claude-code-releases/latest")
        #expect(AgentToolReleaseSources.codexNativeLatest
            == "https://releases.openai.com/codex/channels/latest")
        #expect(AgentToolReleaseSources.antigravityManifestBase
            == "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests")
    }

    @Test func probeCommandsAreMarkerDelimitedAndNetworkBounded() {
        for tool in AgentToolID.allCases {
            let command = AgentToolVersionProbe.command(for: tool)
            let definition = AgentToolRegistry.definition(for: tool)

            #expect(command.contains("MSAM_TOOL_BEGIN:\(tool.rawValue)"))
            #expect(command.contains("MSAM_TOOL_END:\(tool.rawValue)"))
            #expect(command.contains("command -v \(definition.executable)"))
            #expect(command.contains("--connect-timeout 8"))
            #expect(command.contains("--max-time 20"))
        }
    }

    @Test func ownerSpecificLookupsDoNotSilentlySwitchChannels() {
        let codex = AgentToolVersionProbe.command(for: .codex)

        #expect(codex.contains("brew info --json=v2 codex"))
        #expect(codex.contains("npm view @openai/codex version"))
        #expect(codex.contains("pnpm view @openai/codex version"))
        #expect(codex.contains("bun pm view @openai/codex version"))
        #expect(codex.contains(AgentToolReleaseSources.codexNativeLatest))
    }

    @Test func markerParserIgnoresShellNoiseAndPreservesSpacesInPaths() throws {
        let output = """
        Last login: today
        shell plugin chatter
        MSAM_TOOL_BEGIN:claude
        installed=2.1.260
        latest=2.1.261
        method=native
        channel=latest
        path=/Users/Alice Smith/.local/bin/claude
        error=
        MSAM_TOOL_END:claude
        ignored trailing output
        """

        let version = try AgentToolVersionProbe.parse(output, tool: .claude)

        #expect(version == AgentToolVersion(
            tool: .claude,
            installed: "2.1.260",
            latest: "2.1.261",
            channel: "latest",
            method: .native,
            executablePath: "/Users/Alice Smith/.local/bin/claude",
            error: nil
        ))
        #expect(version.isUpdateAvailable)
    }

    @Test func absentExecutablesAndFailedLatestLookupsStayExplicit() throws {
        let missing = try AgentToolVersionProbe.parse("""
        MSAM_TOOL_BEGIN:codex
        installed=
        latest=
        method=unknown
        channel=
        path=
        error=not installed
        MSAM_TOOL_END:codex
        """, tool: .codex)
        #expect(missing.installed == nil)
        #expect(missing.latest == nil)
        #expect(missing.method == .unknown)
        #expect(missing.error == "not installed")
        #expect(!missing.isUpdateAvailable)

        let failedLatest = try AgentToolVersionProbe.parse("""
        MSAM_TOOL_BEGIN:antigravity
        installed=1.1.26
        latest=
        method=native
        channel=latest
        path=/Users/alice/.local/bin/agy
        error=latest lookup failed
        MSAM_TOOL_END:antigravity
        """, tool: .antigravity)
        #expect(failedLatest.installed == "1.1.26")
        #expect(failedLatest.latest == nil)
        #expect(failedLatest.error == "latest lookup failed")
        #expect(!failedLatest.isUpdateAvailable)
    }

    @Test func aDifferentToolsMarkersCannotBeSubstituted() {
        #expect(throws: AgentToolVersionProbeError.missingMarkers(.claude)) {
            try AgentToolVersionProbe.parse("""
            MSAM_TOOL_BEGIN:codex
            installed=1.0.0
            MSAM_TOOL_END:codex
            """, tool: .claude)
        }
    }

    @Test func fetchUsesTheBoundedSSHRunner() async throws {
        let transport = FakeSSHTransport()
        let service = SSHService(
            host: Host(name: "h", address: "192.0.2.9", username: "alice",
                       keyID: "key", defaultWorkdir: "/home/alice"),
            transport: transport,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: #function)!)
        )
        try await service.connect(key: SSHKeyMaterial(ed25519Seed: Data(repeating: 1, count: 32))) {
            _, _ in true
        }
        transport.structuredCommandResults = [.success(.init(
            exitStatus: 0,
            stdout: Data("""
            MSAM_TOOL_BEGIN:codex
            installed=0.153.1
            latest=0.153.2
            method=native
            channel=latest
            path=/home/alice/.local/bin/codex
            error=
            MSAM_TOOL_END:codex
            """.utf8),
            stderr: Data()
        ))]

        let result = try await AgentToolVersionProbe.fetch(.codex, using: service)

        #expect(result.installed == "0.153.1")
        let request = try #require(transport.structuredCommandsRun.first)
        #expect(request.timeout == AgentToolVersionProbe.timeout)
        #expect(request.outputLimit == AgentToolVersionProbe.outputLimit)
    }
}
