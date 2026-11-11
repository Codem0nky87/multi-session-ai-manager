import Foundation
import Testing
@testable import MultiSessionAIManager

/// The guided upgrade never re-launched a session: every batch the app had ever
/// queued on a host was a tool update with no targets. These replay what the host
/// reports at each moment of the flow.
@Suite @MainActor struct AgentUpgradeFlowTests {

    @Test func aBatchIsOnlyFollowedOnceTheHostReportsThatVeryBatch() {
        let mine = UUID()
        #expect(AgentBatchWatch.progress(of: nil, in: batch(mine, .complete)) == .waiting)
        #expect(AgentBatchWatch.progress(of: mine, in: nil) == .waiting)
        #expect(AgentBatchWatch.progress(of: mine, in: .idle) == .waiting)
        // The host still describes the batch it finished before this one was queued.
        #expect(AgentBatchWatch.progress(of: mine, in: batch(UUID(), .complete)) == .waiting)
        #expect(AgentBatchWatch.progress(of: mine, in: batch(UUID(), .rolling)) == .waiting)
        #expect(AgentBatchWatch.progress(of: mine, in: batch(mine, .updating)) == .running(batch(mine, .updating)))
        #expect(AgentBatchWatch.progress(of: mine, in: batch(mine, .complete)) == .finished(batch(mine, .complete)))
        #expect(AgentBatchWatch.progress(of: mine, in: batch(mine, .failedUpdate)) == .finished(batch(mine, .failedUpdate)))
    }

    /// Exactly what happened on the host on 11 November: the popup said "Upgrade
    /// complete" while Codex was still being updated, and "Re-launch Sessions"
    /// then watched that update instead of queueing a re-launch.
    @Test func upgradeThenReLaunchQueuesTwoBatchesAndFollowsEachToItsOwnEnd() async throws {
        let host = FakeUpdaterHost(reporting: batch(UUID(), .complete))
        let (flow, transport) = try await makeFlow(host: host, inventory: [
            session(.codex, pane: "w1:p2", conversation: "codex-thread"),
            session(.claude, pane: "w1:p1", conversation: "claude-thread")
        ])

        await flow.startUpgrade()
        let upgrade = try #require(queuedBatches(transport).first)
        #expect(request(upgrade, transport).contains("\nUPDATE\tcodex\n"))
        #expect(!request(upgrade, transport).contains("TARGET"))

        // Queued, not picked up: the host still reports the batch before it.
        await flow.poll()
        #expect(flow.stage == .upgrading)
        #expect(flow.statusLine == "Queued on host")

        await host.report(batch(upgrade, .updating))
        await flow.poll()
        #expect(flow.stage == .upgrading)
        #expect(flow.statusLine == "Updating tools")

        await host.report(batch(upgrade, .complete))
        await flow.poll()
        #expect(flow.stage == .sessions)
        #expect(flow.sessions.map(\.paneID) == ["w1:p2"], "only the upgraded tool's sessions")

        await flow.startRoll()
        let roll = try #require(queuedBatches(transport).subtracting([upgrade]).first)
        #expect(request(roll, transport).contains("TARGET\tdefault\t/tmp/herdr.sock\tw1:p2\t100\tcodex\tcodex-thread\n"))
        #expect(!request(roll, transport).contains("\nUPDATE\t"), "a re-launch updates no tool")
        #expect(!request(roll, transport).contains("claude"))

        // The finished upgrade is still what the host reports: not this roll's end.
        await flow.poll()
        #expect(flow.stage == .rolling)
        #expect(flow.progress == nil)

        await host.report(batch(roll, .rolling, total: 1))
        await flow.poll()
        #expect(flow.stage == .rolling)
        #expect(flow.progress?.total == 1)

        await host.report(batch(roll, .complete, total: 1, restored: 1))
        await flow.poll()
        #expect(flow.stage == .done)
        #expect(flow.rollResult?.restored == 1)
    }

    @Test func reLaunchWhileAnotherBatchRunsQueuesNothingSaysSoAndReturnsToTheSessions() async throws {
        let host = FakeUpdaterHost(reporting: .idle)
        let (flow, transport) = try await makeFlow(host: host, inventory: [
            session(.codex, pane: "w1:p2", conversation: "codex-thread")
        ])
        let upgrade = try await upgrade(flow, host: host, transport: transport)

        await host.report(batch(UUID(), .updating))
        await flow.startRoll()

        #expect(queuedBatches(transport) == [upgrade], "no second request")
        #expect(flow.stage == .failed(
            "Another agent update is still running on this host. Wait for it to finish, then re-launch the sessions."))
        flow.retry()
        #expect(flow.stage == .sessions, "not back to upgrading a tool that is already upgraded")
    }

    @Test func aFailedToolUpdateIsReportedAndRetriesFromTheStart() async throws {
        let host = FakeUpdaterHost(reporting: .idle)
        let (flow, transport) = try await makeFlow(host: host)

        await flow.startUpgrade()
        let upgrade = try #require(queuedBatches(transport).first)
        await host.report(batch(upgrade, .failedUpdate))
        await flow.poll()

        #expect(flow.stage == .failed("The host could not update Codex. Check the updater service and retry."))
        flow.retry()
        #expect(flow.stage == .confirming)
    }

    @Test func anApprovalTheHostIsWaitingForCanBeRetriedOntoTheSameBatch() async throws {
        let host = FakeUpdaterHost(reporting: .idle)
        let (flow, transport) = try await makeFlow(host: host)

        await flow.startUpgrade()
        let upgrade = try #require(queuedBatches(transport).first)
        await host.report(batch(upgrade, .approvalRequired))
        await flow.poll()
        #expect(flow.stage == .failed("Open Codex once on the host to approve the new build, then retry."))

        // Approved on the host: the retry picks its own batch back up.
        flow.retry()
        await host.report(batch(upgrade, .updating))
        await flow.startUpgrade()
        #expect(flow.stage == .upgrading)
        #expect(queuedBatches(transport) == [upgrade])
        await host.report(batch(upgrade, .complete))
        await flow.poll()
        #expect(flow.stage == .sessions)
    }

    @Test func aRequestAnIdleHostNeverStartsStopsWaitingButOneQueuedBehindABatchDoesNot() async throws {
        let clock = TestClock()
        let host = FakeUpdaterHost(reporting: .idle)
        let (flow, _) = try await makeFlow(host: host, now: { clock.now })

        await flow.startUpgrade()
        clock.advance(30)
        await flow.poll()
        #expect(flow.stage == .upgrading)

        // Another batch is running: this one is queued behind it, however long that takes.
        await host.report(batch(UUID(), .rolling))
        clock.advance(600)
        await flow.poll()
        #expect(flow.stage == .upgrading)

        await host.report(.idle)
        clock.advance(AgentBatchWatch.pickupPatience + 1)
        await flow.poll()
        guard case .failed(let message) = flow.stage else {
            Issue.record("expected the flow to stop waiting, got \(flow.stage)")
            return
        }
        #expect(message.hasPrefix("The host service has not started this request."))
    }

    @Test func sessionsThatCannotBeListedAreReportedNotCalledAbsent() async throws {
        let host = FakeUpdaterHost(reporting: .idle)
        let (flow, transport) = try await makeFlow(host: host, inventoryFails: true)

        _ = try await upgrade(flow, host: host, transport: transport)

        #expect(flow.stage == .sessions)
        #expect(flow.sessions.isEmpty)
        #expect(flow.sessionsError != nil)
    }

    // MARK: Fixtures

    /// Drive the flow through a completed tool upgrade; returns that batch.
    private func upgrade(_ flow: AgentUpgradeFlow, host: FakeUpdaterHost,
                         transport: FakeSSHTransport) async throws -> UUID {
        await flow.startUpgrade()
        let upgrade = try #require(queuedBatches(transport).first)
        await host.report(batch(upgrade, .complete))
        await flow.poll()
        return upgrade
    }

    private func makeFlow(
        host: FakeUpdaterHost,
        inventory: [HerdrAgentSnapshot] = [],
        inventoryFails: Bool = false,
        now: @escaping () -> Date = Date.init
    ) async throws -> (AgentUpgradeFlow, FakeSSHTransport) {
        let keyStore = KeyStore(backing: InMemoryKeychain())
        let keyID = try keyStore.generateEd25519(label: "flow")
        let transport = FakeSSHTransport()
        // The host helper confirms whichever batch it is asked to queue.
        transport.beforeCommand = { [weak transport] command in
            guard command.contains("submit"),
                  let range = command.range(of: uuidPattern, options: .regularExpression) else { return }
            transport?.defaultCommandResponse = "MSAM_AGENT_UPDATE_ACCEPTED\t1\t\(command[range])\tqueued\n"
        }
        let connection = HostConnection(
            host: Host(name: "h", address: "192.0.2.62", username: "alice",
                       keyID: keyID, defaultWorkdir: "/home/alice"),
            keyStore: keyStore,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: "flow.\(UUID())")!),
            transport: transport
        )
        await connection.connect()
        let manager = AgentUpdateManager(connection: connection, dependencies: .init(
            fetchVersion: { tool, _ in
                .init(tool: tool, installed: "1.0.0", latest: "2.0.0", channel: "latest",
                      method: .native, executablePath: "/bin/\(tool.rawValue)", error: nil)
            },
            fetchInventory: { _ in
                if inventoryFails { throw HerdrAgentInventoryError.commandFailed(1) }
                return inventory
            },
            fetchContext: { _ in .init(home: "/home/alice", platform: .linux, uid: 1000) },
            fetchServiceStatus: { _, _ in
                .init(platform: .linux, helperProtocol: 1, serviceActive: true,
                      stateWritable: true, selfTestPassed: true, lingerEnabled: true)
            },
            fetchBatchStatus: { _, _ in await host.status() }
        ))
        await manager.refresh()
        return (AgentUpgradeFlow(tool: .codex, manager: manager, now: now), transport)
    }

    private func queuedBatches(_ transport: FakeSSHTransport) -> Set<UUID> {
        Set(transport.writtenFiles.keys.compactMap { path -> UUID? in
            guard path.contains("/msam-agent-updater/incoming/"), path.hasSuffix(".request") else { return nil }
            return UUID(uuidString: String(path.dropLast(".request".count).suffix(36)))
        })
    }

    private func request(_ batch: UUID, _ transport: FakeSSHTransport) -> String {
        let path = "/home/alice/.local/state/msam-agent-updater/incoming/\(batch.uuidString).request"
        return String(decoding: transport.writtenFiles[path] ?? Data(), as: UTF8.self)
    }

    private func batch(_ id: UUID, _ phase: AgentUpdateBatchPhase,
                       total: Int = 0, restored: Int = 0) -> AgentUpdateBatchStatus {
        .init(id: id, phase: phase, approvalTool: nil, total: total, restored: restored,
              working: 0, attention: 0, retrying: 0, failed: 0, targets: [])
    }

    private func session(_ tool: AgentToolID, pane: String, conversation: String) -> HerdrAgentSnapshot {
        .init(herdrSession: "default", socketPath: "/tmp/herdr.sock", paneID: pane,
              tool: tool, lifecycle: .idle, conversationID: conversation,
              foregroundPID: 100, integrationCurrent: true)
    }
}

/// The host updater's durable status: the batch it is on, or the last it finished.
private actor FakeUpdaterHost {
    private var reported: AgentUpdateBatchStatus

    init(reporting status: AgentUpdateBatchStatus) {
        reported = status
    }

    func report(_ status: AgentUpdateBatchStatus) {
        reported = status
    }

    func status() -> AgentUpdateBatchStatus {
        reported
    }
}

private let uuidPattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"

/// Only ever touched from the main actor, by the test and by the flow it drives.
private final class TestClock: @unchecked Sendable {
    private(set) var now = Date(timeIntervalSince1970: 1_800_000_000)

    func advance(_ seconds: TimeInterval) {
        now += seconds
    }
}
