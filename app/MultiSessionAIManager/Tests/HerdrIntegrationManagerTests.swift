import Foundation
import Testing
@testable import MultiSessionAIManager

private actor FirstIntegrationInstallGate {
    private var blocked = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pauseFirstInstall(_ command: String) async throws {
        guard command.contains("herdr integration install"), !blocked else {
            try Task.checkCancellation()
            return
        }
        blocked = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        try Task.checkCancellation()
    }

    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@Suite @MainActor
struct HerdrIntegrationManagerTests {
    @Test func registryCoversEverySupportedHerdrAgentAndAlias() {
        let aliases = Dictionary(
            uniqueKeysWithValues: HerdrIntegrationManager.targets.map {
                ($0.herdrTarget, $0.executableAliases)
            })

        #expect(
            aliases == [
                "pi": ["pi"],
                "omp": ["omp"],
                "claude": ["claude"],
                "codex": ["codex"],
                "copilot": ["copilot"],
                "devin": ["devin"],
                "droid": ["droid"],
                "kimi": ["kimi"],
                "opencode": ["opencode"],
                "kilo": ["kilo", "kilo-code"],
                "hermes": ["hermes"],
                "qodercli": ["qodercli"],
                "qwen": ["qwen"],
                "cursor": ["cursor-agent"],
                "mastracode": ["mastracode"],
                "antigravity-cli": ["agy"],
                "grok": ["grok"],
            ])
        #expect(HerdrIntegrationManager.targets.allSatisfy { !$0.displayName.isEmpty })
        #expect(Set(HerdrIntegrationManager.targets.map(\.herdrTarget)).count == 17)
    }

    @Test func detectionCommandUsesOnlyQuotedRegistryValuesAndStableMarkers() {
        let command = HerdrIntegrationManager.detectionCommand

        for target in HerdrIntegrationManager.targets {
            for alias in target.executableAliases {
                #expect(command.contains("command -v \(POSIXShell.quote(alias))"))
            }
            #expect(command.components(separatedBy: "MSAM_AGENT:\(target.herdrTarget)").count == 2)
        }
        #expect(command.contains("command -v 'kilo-code'"))
        #expect(command.contains("command -v 'cursor-agent'"))
        #expect(command.contains("command -v 'agy'"))
        #expect(!command.contains("$("))
        #expect(!command.contains("`"))
    }

    @Test func parserRecognisesHerdrStatesWithoutDependingOnHostPaths() {
        let statuses = HerdrIntegrationManager.parseStatuses(
            """
            claude: current (v4) (/Users/alice/.config/herdr/integrations/claude)
            codex: not installed (/home/bob/.config/herdr/integrations/codex)
            kilo: outdated (v2 < v3) (/opt/herdr/integrations/kilo)
            cursor: needs repair (v7) (/tmp/a path/with spaces)
            future-agent: current (v99) (/somewhere)
            malformed line without a colon
            """)

        #expect(statuses["claude"] == .current(version: "v4"))
        #expect(statuses["codex"] == .notInstalled)
        #expect(statuses["kilo"] == .outdated(versions: "v2 < v3"))
        #expect(statuses["cursor"] == .needsRepair(version: "v7"))
        #expect(statuses["future-agent"] == nil)
        #expect(statuses.count == 4)
    }

    @Test func classificationPublishesOnlyDetectedAgentsInRegistryOrder() {
        let agents = HerdrIntegrationManager.classify(
            detectionOutput: """
                login banner
                MSAM_AGENT:codex
                MSAM_AGENT:claude
                MSAM_AGENT:not-a-target
                MSAM_AGENT:codex
                """,
            statusOutput: """
                pi: current (v1) (/ignored)
                claude: current (v4) (/ignored)
                codex: outdated (v2 < v3) (/ignored)
                """
        )

        #expect(agents.map(\.target.herdrTarget) == ["claude", "codex"])
        #expect(
            agents.map(\.status) == [
                .current(version: "v4"),
                .outdated(versions: "v2 < v3"),
            ])
    }

    @Test func detectedAgentWithMissingOrMalformedStatusIsUnknown() {
        let agents = HerdrIntegrationManager.classify(
            detectionOutput: "MSAM_AGENT:qwen\nMSAM_AGENT:grok\n",
            statusOutput: "qwen: surprising future state (v1) (/ignored)\n"
        )

        #expect(agents.map(\.target.herdrTarget) == ["qwen", "grok"])
        #expect(agents.map(\.status) == [.unknown, .unknown])
    }
    private func makeManager(
        transport: FakeSSHTransport,
        function: String = #function
    ) throws -> HerdrIntegrationManager {
        let keyStore = KeyStore(backing: InMemoryKeychain())
        let keyID = try keyStore.generateEd25519(label: "integration-manager")
        let suite = "msam.integration-manager.\(function).\(UUID())"
        let connection = HostConnection(
            host: Host(
                name: "host",
                address: "192.0.2.42",
                username: "alice",
                keyID: keyID,
                defaultWorkdir: "/home/alice"
            ),
            keyStore: keyStore,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: suite)!),
            transport: transport
        )
        return HerdrIntegrationManager(connection: connection)
    }

    private func result(_ stdout: String, stderr: String = "", exit: Int32 = 0)
        -> Result<SSHCommandResult, SSHCommandExecutionError>
    {
        .success(
            SSHCommandResult(
                exitStatus: exit,
                stdout: Data(stdout.utf8),
                stderr: Data(stderr.utf8)
            ))
    }

    @Test func probeDetectsThenPublishesOnlyInstalledAgents() async throws {
        let transport = FakeSSHTransport()
        let manager = try makeManager(transport: transport)
        await manager.connection.connect()
        transport.structuredCommandResults = [
            result("MSAM_AGENT:claude\nMSAM_AGENT:kilo\n"),
            result(
                """
                claude: current (v4) (/home/alice/.config/herdr/integrations/claude)
                codex: current (v8) (/ignored/because/not/detected)
                kilo: not installed (/home/alice/.config/herdr/integrations/kilo)
                """),
        ]

        await manager.probe()

        #expect(manager.state == .ready)
        #expect(manager.agents.map(\.target.herdrTarget) == ["claude", "kilo"])
        #expect(
            manager.agents.map(\.status) == [
                .current(version: "v4"),
                .notInstalled,
            ])
        #expect(manager.failures.isEmpty)

        let requests = transport.structuredCommandsRun
        #expect(requests.count == 2)
        #expect(requests[0].command.contains("MSAM_AGENT:claude"))
        #expect(requests[1].command.contains("herdr integration status"))
        #expect(requests.allSatisfy { $0.timeout > .zero && $0.outputLimit > 0 })
    }

    @Test func probeWithoutAnAuthenticatedConnectionFailsDeterministically() async throws {
        let manager = try makeManager(transport: FakeSSHTransport())

        await manager.probe()

        #expect(manager.agents.isEmpty)
        #expect(manager.failures.isEmpty)
        #expect(manager.state == .failed("Connect and authenticate SSH to this host first."))
    }

    @Test func aNonzeroStatusCommandIsAProbeFailureNotReadiness() async throws {
        let transport = FakeSSHTransport()
        let manager = try makeManager(transport: transport)
        await manager.connection.connect()
        transport.structuredCommandResults = [
            result("MSAM_AGENT:codex\n"),
            result("", stderr: "herdr: status unavailable", exit: 1),
        ]

        await manager.probe()

        #expect(manager.agents.isEmpty)
        guard case .failed(let message) = manager.state else {
            Issue.record("Expected a failed probe, got \(manager.state)")
            return
        }
        #expect(message.contains("status unavailable"))
    }
    private func installCommands(in transport: FakeSSHTransport) -> [SSHCommandRequest] {
        transport.structuredCommandsRun.filter {
            $0.command.contains("herdr integration install")
        }
    }

    @Test func safeInstallCommandsExistOnlyForRegistryTargets() {
        #expect(
            HerdrIntegrationManager.installCommand(forHerdrTarget: "codex")
                == "herdr integration install codex")
        #expect(
            HerdrIntegrationManager.installCommand(forHerdrTarget: "antigravity-cli")
                == "herdr integration install antigravity-cli")
        #expect(HerdrIntegrationManager.installCommand(forHerdrTarget: "codex; reboot") == nil)
        #expect(HerdrIntegrationManager.installCommand(forHerdrTarget: "unknown") == nil)
    }

    @Test func uiFailureMessagesAreBoundedWithoutChangingShortMessages() {
        #expect(HerdrIntegrationManager.boundedFailureMessage("short reason") == "short reason")

        let largeRemoteOutput = String(repeating: "remote diagnostic ", count: 1_000)
        let message = HerdrIntegrationManager.boundedFailureMessage(largeRemoteOutput)
        #expect(message.count <= HerdrIntegrationManager.maximumFailureMessageLength)
        #expect(message.hasSuffix("…"))
    }

    @Test func pureSummarySeparatesUnavailableStatusFromActionableWork() throws {
        let claude = try #require(
            HerdrIntegrationManager.targets.first { $0.herdrTarget == "claude" })
        let codex = try #require(
            HerdrIntegrationManager.targets.first { $0.herdrTarget == "codex" })
        let qwen = try #require(
            HerdrIntegrationManager.targets.first { $0.herdrTarget == "qwen" })

        let unknownOnly = HerdrIntegrationManager.summary(
            state: .ready,
            agents: [.init(target: qwen, status: .unknown)],
            failures: []
        )
        let currentAndUnknown = HerdrIntegrationManager.summary(
            state: .ready,
            agents: [
                .init(target: claude, status: .current(version: "v4")),
                .init(target: qwen, status: .unknown),
            ],
            failures: []
        )
        let actionableAndUnknown = HerdrIntegrationManager.summary(
            state: .ready,
            agents: [
                .init(target: claude, status: .current(version: "v4")),
                .init(target: codex, status: .notInstalled),
                .init(target: qwen, status: .unknown),
            ],
            failures: []
        )

        #expect(unknownOnly == .statusUnavailable(count: 1))
        #expect(currentAndUnknown == .statusUnavailable(count: 1))
        #expect(actionableAndUnknown == .workNeeded(count: 1))
    }

    @Test func pureSummaryCoversEveryHostSetupPresentationState() throws {
        let claude = try #require(
            HerdrIntegrationManager.targets.first { $0.herdrTarget == "claude" })
        let codex = try #require(
            HerdrIntegrationManager.targets.first { $0.herdrTarget == "codex" })
        let current = HerdrAgentIntegration(
            target: claude,
            status: .current(version: "v4")
        )
        let actionable = HerdrAgentIntegration(target: codex, status: .notInstalled)
        let failure = HerdrIntegrationFailure(
            herdrTarget: "codex",
            displayName: "Codex",
            message: "Codex: Integration is still not ready."
        )

        #expect(
            HerdrIntegrationManager.summary(state: .idle, agents: [], failures: []) == .idle)
        #expect(
            HerdrIntegrationManager.summary(state: .probing, agents: [], failures: [])
                == .probing)
        #expect(
            HerdrIntegrationManager.summary(state: .ready, agents: [], failures: [])
                == .noAgents)
        #expect(
            HerdrIntegrationManager.summary(state: .ready, agents: [current], failures: [])
                == .allCurrent)
        #expect(
            HerdrIntegrationManager.summary(
                state: .ready,
                agents: [current, actionable],
                failures: []
            ) == .workNeeded(count: 1))
        #expect(
            HerdrIntegrationManager.summary(
                state: .installing,
                agents: [actionable],
                failures: []
            ) == .installing)
        #expect(
            HerdrIntegrationManager.summary(
                state: .ready,
                agents: [current, actionable],
                failures: [failure]
            ) == .partialFailure(messages: [failure.message]))
        #expect(
            HerdrIntegrationManager.summary(
                state: .failed("Host unavailable"),
                agents: [],
                failures: []
            ) == .probeFailure("Host unavailable"))
    }

    @Test func integrationStatusesHaveHumanFriendlyLabels() {
        #expect(HerdrIntegrationStatus.current(version: "v4").displayText == "Ready (v4)")
        #expect(HerdrIntegrationStatus.current(version: nil).displayText == "Ready")
        #expect(HerdrIntegrationStatus.notInstalled.displayText == "Not enabled")
        #expect(
            HerdrIntegrationStatus.outdated(versions: "v2 < v3").displayText
                == "Update needed (v2 < v3)")
        #expect(
            HerdrIntegrationStatus.needsRepair(version: "v7").displayText
                == "Repair needed (v7)")
        #expect(HerdrIntegrationStatus.unknown.displayText == "Status unavailable")
    }

    @Test func installAllRunsEachActionableIntegrationSequentiallyThenReprobes() async throws {
        let transport = FakeSSHTransport()
        let manager = try makeManager(transport: transport)
        await manager.connection.connect()
        let detected = """
            MSAM_AGENT:claude
            MSAM_AGENT:codex
            MSAM_AGENT:kilo
            MSAM_AGENT:cursor
            """
        transport.structuredCommandResults = [
            result(detected),
            result(
                """
                claude: current (v4) (/ignored)
                codex: not installed (/ignored)
                kilo: outdated (v2 < v3) (/ignored)
                cursor: needs repair (v7) (/ignored)
                """),
        ]
        await manager.probe()
        transport.structuredCommandResults = [
            result("installed codex"),
            result("updated kilo"),
            result("repaired cursor"),
            result(detected),
            result(
                """
                claude: current (v4) (/another/path)
                codex: current (v3) (/another/path)
                kilo: current (v3) (/another/path)
                cursor: current (v8) (/another/path)
                """),
        ]

        await manager.installOrRepairAll()

        let commands = installCommands(in: transport)
        #expect(commands.count == 3)
        #expect(commands[0].command.contains("herdr integration install codex"))
        #expect(commands[1].command.contains("herdr integration install kilo"))
        #expect(commands[2].command.contains("herdr integration install cursor"))
        #expect(!commands.contains { $0.command.contains("herdr integration install claude") })
        #expect(commands.allSatisfy { $0.timeout > .zero && $0.outputLimit > 0 })
        #expect(manager.state == .ready)
        #expect(manager.agents.allSatisfy { $0.status.isCurrent })
        #expect(manager.failures.isEmpty)
        #expect(manager.summary == .allCurrent)
    }

    @Test func oneInstallFailureDoesNotPreventLaterAgentsOrVerification() async throws {
        let transport = FakeSSHTransport()
        let manager = try makeManager(transport: transport)
        await manager.connection.connect()
        let detected = "MSAM_AGENT:codex\nMSAM_AGENT:kilo\n"
        transport.structuredCommandResults = [
            result(detected),
            result("codex: not installed (/ignored)\nkilo: outdated (v2 < v3) (/ignored)\n"),
        ]
        await manager.probe()
        transport.structuredCommandResults = [
            .failure(.timedOut),
            result("updated kilo"),
            result(detected),
            result("codex: not installed (/new/path)\nkilo: current (v3) (/new/path)\n"),
        ]

        await manager.installOrRepairAll()

        let commands = installCommands(in: transport)
        #expect(commands.count == 2)
        #expect(commands[0].command.contains("herdr integration install codex"))
        #expect(commands[1].command.contains("herdr integration install kilo"))
        #expect(manager.state == .ready)
        #expect(manager.agents.first { $0.target.herdrTarget == "kilo" }?.status.isCurrent == true)
        #expect(
            manager.failures.contains {
                $0.herdrTarget == "codex"
                    && $0.message.localizedCaseInsensitiveContains("timed out")
            })
        #expect(
            manager.failures.contains {
                $0.herdrTarget == "codex" && $0.message.contains("still not ready")
            })
        guard case .partialFailure(let messages) = manager.summary else {
            Issue.record("Expected a partial failure summary, got \(manager.summary)")
            return
        }
        #expect(messages.count >= 2)
    }

    @Test func successfulCommandStillFailsWhenVerificationIsNotCurrent() async throws {
        let transport = FakeSSHTransport()
        let manager = try makeManager(transport: transport)
        await manager.connection.connect()
        let detected = "MSAM_AGENT:claude\n"
        transport.structuredCommandResults = [
            result(detected),
            result("claude: needs repair (v4) (/old/path)\n"),
        ]
        await manager.probe()
        transport.structuredCommandResults = [
            result("repair reported success"),
            result(detected),
            result("claude: needs repair (v4) (/different/path)\n"),
        ]

        await manager.installOrRepairAll()

        #expect(manager.state == .ready)
        #expect(manager.failures.count == 1)
        #expect(manager.failures.first?.herdrTarget == "claude")
        #expect(manager.failures.first?.message.contains("still not ready") == true)
        #expect(manager.failures.first?.message.contains("Repair needed") == true)
    }

    @Test func concurrentInstallRequestDoesNotStartADuplicateHostMutation() async throws {
        let transport = FakeSSHTransport()
        let manager = try makeManager(transport: transport)
        await manager.connection.connect()
        transport.structuredCommandResults = [
            result("MSAM_AGENT:codex\n"),
            result("codex: not installed (/ignored)\n"),
        ]
        await manager.probe()

        let gate = FirstIntegrationInstallGate()
        transport.beforeCommand = { command in
            try await gate.pauseFirstInstall(command)
        }
        transport.structuredCommandResults = [
            result("installed codex"),
            result("MSAM_AGENT:codex\n"),
            result("codex: current (v3) (/verified)\n"),
        ]

        let first = Task { @MainActor in await manager.installOrRepairAll() }
        await gate.waitUntilBlocked()
        let duplicate = Task { @MainActor in await manager.installOrRepairAll() }
        await duplicate.value
        await gate.release()
        await first.value

        #expect(installCommands(in: transport).count == 1)
        #expect(manager.summary == .allCurrent)
    }

    @Test func probeDuringInstallDoesNotSupersedeTheHostMutation() async throws {
        let transport = FakeSSHTransport()
        let manager = try makeManager(transport: transport)
        await manager.connection.connect()
        transport.structuredCommandResults = [
            result("MSAM_AGENT:codex\n"),
            result("codex: not installed (/ignored)\n"),
        ]
        await manager.probe()

        let gate = FirstIntegrationInstallGate()
        transport.beforeCommand = { command in
            try await gate.pauseFirstInstall(command)
        }
        transport.structuredCommandResults = [
            result("installed codex"),
            result("MSAM_AGENT:codex\n"),
            result("codex: current (v3) (/verified)\n"),
        ]
        let install = Task { @MainActor in await manager.installOrRepairAll() }
        await gate.waitUntilBlocked()
        let commandCountDuringInstall = transport.structuredCommandsRun.count

        await manager.probe()

        #expect(transport.structuredCommandsRun.count == commandCountDuringInstall)
        #expect(manager.state == .installing)
        await gate.release()
        await install.value
        #expect(manager.summary == .allCurrent)
    }

    @Test func ambiguousInstallIsSuccessWhenAuthoritativeReprobeIsCurrent() async throws {
        let transport = FakeSSHTransport()
        let manager = try makeManager(transport: transport)
        await manager.connection.connect()
        let detected = "MSAM_AGENT:codex\n"
        transport.structuredCommandResults = [
            result(detected),
            result("codex: not installed (/old/path)\n"),
        ]
        await manager.probe()
        transport.structuredCommandResults = [
            .failure(.ambiguousDisconnect),
            result(detected),
            result("codex: current (v3) (/new/path)\n"),
        ]

        await manager.installOrRepairAll()

        #expect(manager.agents.first?.status == .current(version: "v3"))
        #expect(manager.failures.isEmpty)
        #expect(manager.summary == .allCurrent)
    }

    @Test func unknownStatusNeverMutatesTheHost() async throws {
        let transport = FakeSSHTransport()
        let manager = try makeManager(transport: transport)
        await manager.connection.connect()
        let detected = "MSAM_AGENT:claude\nMSAM_AGENT:qwen\n"
        let unknownStatus = "claude: current (v4) (/ignored)\nqwen: future state (v10) (/ignored)\n"
        transport.structuredCommandResults = [
            result(detected),
            result(unknownStatus),
        ]
        await manager.probe()
        #expect(manager.agents.first { $0.target.herdrTarget == "qwen" }?.status == .unknown)
        #expect(!manager.canInstallOrRepair)
        #expect(manager.summary == .statusUnavailable(count: 1))

        transport.commandResponses[
            SSHService.provisioningShellCommand(HerdrIntegrationManager.detectionCommand)
        ] = detected
        transport.commandResponses[
            SSHService.provisioningShellCommand(HerdrIntegrationManager.statusCommand)
        ] = unknownStatus

        await manager.installOrRepairAll()

        #expect(installCommands(in: transport).isEmpty)
        #expect(manager.agents.first { $0.target.herdrTarget == "qwen" }?.status == .unknown)
        #expect(manager.failures.isEmpty)
    }

    @Test func cancellingDuringFirstInstallStopsAllLaterHostCommands() async throws {
        let transport = FakeSSHTransport()
        let manager = try makeManager(transport: transport)
        await manager.connection.connect()
        transport.structuredCommandResults = [
            result("MSAM_AGENT:codex\nMSAM_AGENT:kilo\n"),
            result("codex: not installed (/ignored)\nkilo: outdated (v2 < v3) (/ignored)\n"),
        ]
        await manager.probe()
        let commandsBeforeInstall = transport.structuredCommandsRun.count
        let gate = FirstIntegrationInstallGate()
        transport.beforeCommand = { command in
            try await gate.pauseFirstInstall(command)
        }

        let installTask = Task { @MainActor in
            await manager.installOrRepairAll()
        }
        await gate.waitUntilBlocked()
        installTask.cancel()
        await gate.release()
        await installTask.value

        let commandsAfterCancellation = Array(
            transport.structuredCommandsRun.dropFirst(commandsBeforeInstall))
        #expect(commandsAfterCancellation.count == 1)
        #expect(
            commandsAfterCancellation.first?.command.contains(
                "herdr integration install codex"
            ) == true)
        #expect(manager.state == .ready)
        #expect(manager.failures.isEmpty)
        #expect(
            manager.agents.map(\.status) == [
                .notInstalled,
                .outdated(versions: "v2 < v3"),
            ])
    }
}
