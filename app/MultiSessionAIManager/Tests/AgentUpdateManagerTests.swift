import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite @MainActor struct AgentUpdateManagerTests {
    @Test func refreshPublishesThreeOrderedRowsServiceHealthAndDurableStatus() async throws {
        let (connection, _) = try await makeConnection()
        let manager = AgentUpdateManager(connection: connection, dependencies: dependencies(
            versions: [
                version(.claude, "2.1.0", "2.1.1"),
                version(.codex, "0.9.0", "0.9.0"),
                AgentToolVersion(tool: .antigravity, installed: "1.0.0", latest: nil,
                                 channel: nil, method: .native, executablePath: "/bin/agy",
                                 error: "latest unavailable")
            ],
            batch: .idle
        ))

        await manager.refresh()

        #expect(manager.state == .ready)
        #expect(manager.tools.map(\.tool) == [.claude, .codex, .antigravity])
        #expect(manager.tools.map(\.isUpdateAvailable) == [true, false, false])
        #expect(manager.tools[2].error == "latest unavailable")
        #expect(manager.serviceStatus?.isReady == true)
        #expect(manager.batch == .idle)
        #expect(manager.lastChecked != nil)
    }

    @Test func preflightCapturesAllThreeAgentKindsForOneToolUpdate() async throws {
        let (connection, _) = try await makeConnection()
        let snapshots = [
            snapshot(.claude, pane: "w1:p1", conversation: "claude-1", lifecycle: .idle),
            snapshot(.codex, pane: "w1:p2", conversation: "codex-2", lifecycle: .working),
            snapshot(.antigravity, pane: "w1:p3", conversation: "agy-3", lifecycle: .blocked)
        ]
        let manager = AgentUpdateManager(connection: connection, dependencies: dependencies(
            versions: AgentToolID.allCases.map { version($0, "1.0.0", "2.0.0") },
            inventory: snapshots,
            batch: .idle
        ))
        await manager.refresh()

        let preview = try await manager.prepareUpdate([.codex])

        #expect(preview.request?.requestedTools == [.codex])
        #expect(preview.request?.targets.map(\.tool) == [.claude, .codex, .antigravity])
        #expect(preview.totalConversations == 3)
        #expect(preview.workingConversations == 1)
        #expect(preview.attentionConversations == 1)
    }

    @Test func preflightRefusesAnyMissingNativeReferenceOrIntegration() async throws {
        let (connection, _) = try await makeConnection()
        var bad = snapshot(.claude, pane: "w1:p1", conversation: "c1", lifecycle: .idle)
        bad = HerdrAgentSnapshot(
            herdrSession: bad.herdrSession, socketPath: bad.socketPath, paneID: bad.paneID,
            tool: bad.tool, lifecycle: bad.lifecycle, conversationID: nil,
            foregroundPID: bad.foregroundPID, integrationCurrent: true
        )
        let manager = AgentUpdateManager(connection: connection, dependencies: dependencies(
            versions: AgentToolID.allCases.map { version($0, "1.0.0", "2.0.0") },
            inventory: [bad],
            batch: .idle
        ))
        await manager.refresh()

        await #expect(throws: AgentUpdateManagerError.self) {
            try await manager.prepareUpdate([.claude])
        }
    }

    @Test func multipleSelectionsCoalesceAndSubmitThroughAbsoluteIncomingPath() async throws {
        let (connection, transport) = try await makeConnection()
        let manager = AgentUpdateManager(connection: connection, dependencies: dependencies(
            versions: AgentToolID.allCases.map { version($0, "1.0.0", "2.0.0") },
            inventory: [snapshot(.codex, pane: "w1:p2", conversation: "thread", lifecycle: .done)],
            batch: .idle
        ))
        await manager.refresh()
        let preview = try await manager.prepareUpdate([.claude, .codex])
        let request = try #require(preview.request)
        transport.defaultCommandResponse =
            "MSAM_AGENT_UPDATE_ACCEPTED\t1\t\(request.batchID.uuidString)\tqueued\n"

        await manager.submit(preview)

        let expectedPath = "/home/alice/.local/state/msam-agent-updater/incoming/\(request.batchID.uuidString).request"
        #expect(transport.writtenFiles[expectedPath] != nil)
        let expectedSubmit = SSHService.provisioningShellCommand(
            AgentUpdateManager.submitCommand(
                context: .init(home: "/home/alice", platform: .linux, uid: 1000),
                batchID: request.batchID
            )
        )
        #expect(transport.commandsRun.contains(expectedSubmit))
        #expect(!transport.commandsRun.contains { $0.contains("claude,codex") })
        #expect(manager.state == .ready)
    }

    @Test func activeBatchIsReturnedWithoutCreatingAnotherRequest() async throws {
        let (connection, transport) = try await makeConnection()
        let active = AgentUpdateBatchStatus(
            id: UUID(), phase: .rolling, approvalTool: nil, total: 3, restored: 1, working: 1,
            attention: 1, retrying: 0, failed: 0, targets: []
        )
        let manager = AgentUpdateManager(connection: connection, dependencies: dependencies(
            versions: AgentToolID.allCases.map { version($0, "1.0.0", "2.0.0") },
            inventory: [snapshot(.claude, pane: "w1:p1", conversation: "c1", lifecycle: .idle)],
            batch: active
        ))
        await manager.refresh()

        let preview = try await manager.prepareUpdate([.claude])
        await manager.submit(preview)

        #expect(preview.existingBatch == active)
        #expect(preview.request == nil)
        #expect(transport.writtenFiles.isEmpty)
        #expect(manager.batch == active)
    }

    @Test func unrelatedActiveBatchCannotConfirmAnIndeterminateSubmission() async throws {
        let (connection, transport) = try await makeConnection()
        let unrelated = AgentUpdateBatchStatus(
            id: UUID(), phase: .rolling, approvalTool: nil, total: 1, restored: 0, working: 1,
            attention: 0, retrying: 0, failed: 0, targets: []
        )
        let statuses = BatchStatusSequence([.idle, .idle, unrelated])
        let stable = dependencies(
            versions: AgentToolID.allCases.map { version($0, "1.0.0", "2.0.0") },
            inventory: [snapshot(.codex, pane: "w1:p2", conversation: "thread", lifecycle: .done)],
            batch: .idle
        )
        let manager = AgentUpdateManager(connection: connection, dependencies: .init(
            fetchVersion: stable.fetchVersion,
            fetchInventory: stable.fetchInventory,
            fetchContext: stable.fetchContext,
            fetchServiceStatus: stable.fetchServiceStatus,
            fetchBatchStatus: { _, _ in await statuses.next() }
        ))
        await manager.refresh()
        let preview = try await manager.prepareUpdate([.codex])
        transport.defaultCommandResponse = "not an acceptance"

        await manager.submit(preview)

        #expect(manager.state == .failed(
            "The host did not confirm the durable update request. Refresh before retrying."
        ))
        #expect(manager.batch != unrelated)
    }

    @Test func statusParserKeepsBlockedUnknownAsAttentionAndBoundsMessages() throws {
        let batchID = UUID()
        let long = String(repeating: "x", count: 2_000)
        let status = try AgentUpdateManager.parseStatus("""
        MSAM_AGENT_UPDATE_STATUS\t1
        BATCH\t\(batchID.uuidString)\trolling
        TARGET\t1\tpending\t0\tattention_blocked
        TARGET\t2\tpending\t0\t\(long)
        COUNTS\t2\t0\t0\t2\t0\t0
        END
        """)

        #expect(status.attention == 2)
        #expect(status.restored == 0)
        #expect(status.targets.count == 2)
        #expect(status.targets[1].message.count <= AgentUpdateManager.maximumMessageLength)
    }

    @Test func statusParserReportsTheExactToolAwaitingGatekeeperApproval() throws {
        let batchID = UUID()
        let status = try AgentUpdateManager.parseStatus("""
        MSAM_AGENT_UPDATE_STATUS\t1
        BATCH\t\(batchID.uuidString)\tapproval_required
        APPROVAL\tcodex
        COUNTS\t0\t0\t0\t0\t0\t0
        END
        """)

        #expect(status.approvalTool == .codex)
        #expect(status.phase == .approvalRequired)
    }

    @Test func overlappingRefreshesNeverPublishTheOlderGeneration() async throws {
        let (connection, _) = try await makeConnection()
        let race = RefreshVersionRace()
        let stable = dependencies(
            versions: AgentToolID.allCases.map { version($0, "1.0.0", "2.0.0") },
            batch: .idle
        )
        let manager = AgentUpdateManager(connection: connection, dependencies: .init(
            fetchVersion: { tool, _ in try await race.fetch(tool) },
            fetchInventory: stable.fetchInventory,
            fetchContext: stable.fetchContext,
            fetchServiceStatus: stable.fetchServiceStatus,
            fetchBatchStatus: stable.fetchBatchStatus
        ))

        let older = Task { await manager.refresh() }
        await race.waitUntilFirstFetchIsSuspended()
        await manager.refresh()
        await race.releaseFirstFetch()
        await older.value

        #expect(manager.tools.first?.installed == "2.0.0")
        #expect(manager.state == .ready)
    }

    private func dependencies(
        versions: [AgentToolVersion],
        inventory: [HerdrAgentSnapshot] = [],
        batch: AgentUpdateBatchStatus,
        submittedBatch: AgentUpdateBatchStatus? = nil
    ) -> AgentUpdateManager.Dependencies {
        let byTool = Dictionary(uniqueKeysWithValues: versions.map { ($0.tool, $0) })
        return .init(
            fetchVersion: { tool, _ in
                guard let value = byTool[tool] else { throw AgentUpdateManagerError.versionUnavailable(tool) }
                return value
            },
            fetchInventory: { _ in inventory },
            fetchContext: { _ in .init(home: "/home/alice", platform: .linux, uid: 1000) },
            fetchServiceStatus: { _, _ in
                .init(platform: .linux, helperProtocol: 1, serviceActive: true,
                      stateWritable: true, selfTestPassed: true, lingerEnabled: true)
            },
            fetchBatchStatus: { _, _ in submittedBatch ?? batch }
        )
    }

    @Test func prepareRelaunchCapturesAllAgentsWhenVersionsAreAlreadyCurrent() async throws {
        let (connection, transport) = try await makeConnection()
        let snapshots = [
            snapshot(.claude, pane: "w1:p1", conversation: "claude-1", lifecycle: .idle),
            snapshot(.codex, pane: "w1:p2", conversation: "codex-2", lifecycle: .working),
            snapshot(.antigravity, pane: "w1:p3", conversation: "agy-3", lifecycle: .blocked)
        ]
        let manager = AgentUpdateManager(connection: connection, dependencies: dependencies(
            versions: AgentToolID.allCases.map { version($0, "2.0.0", "2.0.0") },
            inventory: snapshots,
            batch: .idle
        ))
        await manager.refresh()

        let preview = try await manager.prepareRelaunch(for: nil)

        #expect(preview.request?.requestedTools.isEmpty == true)
        #expect(preview.request?.targets.map(\.tool) == [.claude, .codex, .antigravity])
        #expect(preview.totalConversations == 3)
        #expect(preview.workingConversations == 1)
        #expect(preview.attentionConversations == 1)
        #expect(preview.relaunchTool == nil)

        let request = try #require(preview.request)
        transport.defaultCommandResponse =
            "MSAM_AGENT_UPDATE_ACCEPTED\t1\t\(request.batchID.uuidString)\tqueued\n"

        await manager.submit(preview)

        let expectedPath = "/home/alice/.local/state/msam-agent-updater/incoming/\(request.batchID.uuidString).request"
        let written = try #require(transport.writtenFiles[expectedPath])
        let writtenContent = String(decoding: written, as: UTF8.self)
        let lines = writtenContent.split(whereSeparator: \.isNewline).map(String.init)
        #expect(!lines.contains { $0.hasPrefix("UPDATE\t") })
        #expect(lines.contains { $0.hasPrefix("TARGET\t") })
        #expect(manager.state == .ready)
    }

    @Test func prepareRelaunchFiltersToSingleToolWhenSpecified() async throws {
        let (connection, _) = try await makeConnection()
        let snapshots = [
            snapshot(.claude, pane: "w1:p1", conversation: "claude-1", lifecycle: .idle),
            snapshot(.codex, pane: "w1:p2", conversation: "codex-2", lifecycle: .working),
            snapshot(.antigravity, pane: "w1:p3", conversation: "agy-3", lifecycle: .blocked)
        ]
        let manager = AgentUpdateManager(connection: connection, dependencies: dependencies(
            versions: AgentToolID.allCases.map { version($0, "2.0.0", "2.0.0") },
            inventory: snapshots,
            batch: .idle
        ))
        await manager.refresh()

        let preview = try await manager.prepareRelaunch(for: .claude)

        #expect(preview.request?.requestedTools.isEmpty == true)
        #expect(preview.request?.targets.map(\.tool) == [.claude])
        #expect(preview.totalConversations == 1)
        #expect(preview.relaunchTool == .claude)
    }

    @Test func prepareRelaunchThrowsWhenNoActiveConversationsExist() async throws {
        let (connection, _) = try await makeConnection()
        let manager = AgentUpdateManager(connection: connection, dependencies: dependencies(
            versions: AgentToolID.allCases.map { version($0, "2.0.0", "2.0.0") },
            inventory: [],
            batch: .idle
        ))
        await manager.refresh()

        await #expect(throws: AgentUpdateManagerError.self) {
            try await manager.prepareRelaunch(for: nil)
        }
    }

    private func version(
        _ tool: AgentToolID,
        _ installed: String,
        _ latest: String
    ) -> AgentToolVersion {
        .init(tool: tool, installed: installed, latest: latest, channel: "latest",
              method: .native, executablePath: "/bin/\(tool.rawValue)", error: nil)
    }

    private func snapshot(
        _ tool: AgentToolID,
        pane: String,
        conversation: String,
        lifecycle: HerdrAgentLifecycle
    ) -> HerdrAgentSnapshot {
        .init(herdrSession: "default", socketPath: "/tmp/herdr.sock", paneID: pane,
              tool: tool, lifecycle: lifecycle, conversationID: conversation,
              foregroundPID: 100, integrationCurrent: true)
    }

    private func makeConnection() async throws -> (HostConnection, FakeSSHTransport) {
        let keyStore = KeyStore(backing: InMemoryKeychain())
        let keyID = try keyStore.generateEd25519(label: "manager")
        let transport = FakeSSHTransport()
        let connection = HostConnection(
            host: Host(name: "h", address: "192.0.2.61", username: "alice",
                       keyID: keyID, defaultWorkdir: "/home/alice"),
            keyStore: keyStore,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: "manager.\(UUID())")!),
            transport: transport
        )
        await connection.connect()
        return (connection, transport)
    }
}

private actor BatchStatusSequence {
    private var values: [AgentUpdateBatchStatus]

    init(_ values: [AgentUpdateBatchStatus]) {
        self.values = values
    }

    func next() -> AgentUpdateBatchStatus {
        values.isEmpty ? .idle : values.removeFirst()
    }
}

private actor RefreshVersionRace {
    private var claudeFetches = 0
    private var firstIsSuspended = false
    private var suspensionObserver: CheckedContinuation<Void, Never>?
    private var firstRelease: CheckedContinuation<Void, Never>?

    func fetch(_ tool: AgentToolID) async throws -> AgentToolVersion {
        if tool == .claude {
            claudeFetches += 1
            if claudeFetches == 1 {
                firstIsSuspended = true
                suspensionObserver?.resume()
                suspensionObserver = nil
                await withCheckedContinuation { firstRelease = $0 }
                return value(tool, installed: "1.0.0")
            }
        }
        return value(tool, installed: "2.0.0")
    }

    func waitUntilFirstFetchIsSuspended() async {
        guard !firstIsSuspended else { return }
        await withCheckedContinuation { suspensionObserver = $0 }
    }

    func releaseFirstFetch() {
        firstRelease?.resume()
        firstRelease = nil
    }

    private func value(_ tool: AgentToolID, installed: String) -> AgentToolVersion {
        .init(tool: tool, installed: installed, latest: "3.0.0", channel: "latest",
              method: .native, executablePath: "/bin/\(tool.rawValue)", error: nil)
    }
}
