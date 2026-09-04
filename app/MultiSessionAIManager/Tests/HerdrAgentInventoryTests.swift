import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct HerdrAgentInventoryTests {
    @Test func parsesRunningDefaultAndNamedSessionsAfterShellNoise() throws {
        let sessions = try HerdrAgentInventory.parseSessions("""
        login banner
        {"sessions":[
          {"name":"default","default":true,"running":true,"socket_path":"/tmp/herdr.sock","session_dir":"/tmp/default"},
          {"name":"work","default":false,"running":true,"socket_path":"/tmp/herdr-work.sock","session_dir":"/tmp/work"},
          {"name":"stopped","default":false,"running":false,"socket_path":"/tmp/stopped.sock","session_dir":"/tmp/stopped"}
        ]}
        """)

        #expect(sessions == [
            .init(name: "default", socketPath: "/tmp/herdr.sock"),
            .init(name: "work", socketPath: "/tmp/herdr-work.sock")
        ])
    }

    @Test func parsesSupportedAgentsAllLifecycleStatesAndIgnoresUnrelatedAgents() throws {
        let session = HerdrSessionEndpoint(name: "default", socketPath: "/tmp/herdr.sock")
        let agents = try HerdrAgentInventory.parseAgents("""
        prompt noise
        {"result":{"agents":[
          {"pane_id":"w1:p1","agent":"claude","agent_status":"idle","agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"claude-1"}},
          {"pane_id":"w1:p2","agent":"codex","agent_status":"done","agent_session":{"source":"herdr:codex","agent":"codex","kind":"id","value":"codex-2"}},
          {"pane_id":"w1:p3","agent":"agy","agent_status":"working","agent_session":{"source":"herdr:agy","agent":"agy","kind":"id","value":"agy-3"}},
          {"pane_id":"w1:p4","agent":"claude","agent_status":"blocked","agent_session":{"source":"herdr:claude","agent":"claude","kind":"id","value":"claude-4"}},
          {"pane_id":"w1:p5","agent":"codex","agent_status":"unknown"},
          {"pane_id":"w1:p6","agent":"agy","agent_status":"error","agent_session":{"source":"herdr:agy","agent":"agy","kind":"id","value":"agy-6"}},
          {"pane_id":"w1:p7","agent":"gemini","agent_status":"idle"}
        ]}}
        """, session: session)

        #expect(agents.map(\.tool) == [.claude, .codex, .antigravity, .claude, .codex, .antigravity])
        #expect(agents.map(\.lifecycle) == [.idle, .done, .working, .blocked, .unknown, .error])
        #expect(agents[0].conversationID == "claude-1")
        #expect(agents[4].conversationID == nil)
        #expect(agents.allSatisfy { $0.socketPath == "/tmp/herdr.sock" })
    }

    @Test func agentGetAndProcessInfoMustStillMatchTheCapturedIdentity() throws {
        var snapshot = try #require(HerdrAgentInventory.applyIntegrationStatuses(
            ["codex": .current(version: "v7")],
            to: try HerdrAgentInventory.parseAgents("""
        {"result":{"agents":[
          {"pane_id":"w2:p3","agent":"codex","agent_status":"idle","agent_session":{"source":"herdr:codex","agent":"codex","kind":"id","value":"thread-7"}}
        ]}}
        """, session: .init(name: "work", socketPath: "/tmp/work.sock"))
        ).first)

        snapshot = try HerdrAgentInventory.applyLiveDetails(
            to: snapshot,
            agentOutput: """
            {"result":{"agent":{"pane_id":"w2:p3","agent":"codex","agent_status":"idle","agent_session":{"source":"herdr:codex","agent":"codex","kind":"id","value":"thread-7"}}}}
            """,
            processOutput: """
            {"result":{"process_info":{"pane_id":"w2:p3","shell_pid":90,"foreground_process_group_id":117,"foreground_processes":[{"pid":118,"name":"codex"}]}}}
            """
        )

        #expect(snapshot.foregroundPID == 118)
        #expect(snapshot.isRestorable)

        #expect(throws: HerdrAgentInventoryError.self) {
            try HerdrAgentInventory.applyLiveDetails(
                to: snapshot,
                agentOutput: """
                {"result":{"agent":{"pane_id":"w2:p3","agent":"codex","agent_status":"idle","agent_session":{"source":"herdr:codex","agent":"codex","kind":"id","value":"different"}}}}
                """,
                processOutput: #"{"result":{"process_info":{"pane_id":"w2:p3"}}}"#
            )
        }
    }

    @Test func malformedOrDuplicateDataIsInventoryUnavailableNotEmpty() {
        #expect(throws: HerdrAgentInventoryError.self) {
            try HerdrAgentInventory.parseSessions("not JSON")
        }
        #expect(throws: HerdrAgentInventoryError.self) {
            try HerdrAgentInventory.parseAgents("""
            {"result":{"agents":[
              {"pane_id":"w1:p1","agent":"claude","agent_status":"idle","agent_session":{"source":"a","agent":"claude","kind":"id","value":"same"}},
              {"pane_id":"w1:p1","agent":"claude","agent_status":"idle","agent_session":{"source":"a","agent":"claude","kind":"id","value":"same"}}
            ]}}
            """, session: .init(name: "default", socketPath: "/tmp/herdr.sock"))
        }
    }

    @Test func integrationMustBeCurrentBeforeEveryTargetIsEligible() throws {
        let snapshots = try HerdrAgentInventory.parseAgents("""
        {"result":{"agents":[
          {"pane_id":"w1:p1","agent":"claude","agent_status":"idle","agent_session":{"source":"a","agent":"claude","kind":"id","value":"c1"}},
          {"pane_id":"w1:p2","agent":"codex","agent_status":"idle","agent_session":{"source":"a","agent":"codex","kind":"id","value":"c2"}},
          {"pane_id":"w1:p3","agent":"agy","agent_status":"idle","agent_session":{"source":"a","agent":"agy","kind":"id","value":"c3"}}
        ]}}
        """, session: .init(name: "default", socketPath: "/tmp/herdr.sock"))
        let statuses: [String: HerdrIntegrationStatus] = [
            "claude": .current(version: "v7"),
            "codex": .outdated(versions: "v6 < v7"),
            "antigravity-cli": .current(version: "v3")
        ]

        let classified = HerdrAgentInventory.applyIntegrationStatuses(statuses, to: snapshots)
        #expect(classified.map(\.integrationCurrent) == [true, false, true])
        #expect(classified.map(\.isRestorable) == [true, false, true])
    }

    @Test @MainActor func fetchUsesBoundedCommandsAndFailsClosedOnNamedSessionError() async throws {
        let (service, transport) = try await makeService()
        transport.structuredCommandResults = [
            result("""
            {"sessions":[{"name":"default","default":true,"running":true,"socket_path":"/tmp/herdr.sock","session_dir":"/tmp/default"}]}
            """),
            result("claude: current (v7)\ncodex: current (v7)\nantigravity-cli: current (v3)"),
            .success(.init(exitStatus: 1, stdout: Data(), stderr: Data("server unavailable".utf8)))
        ]

        await #expect(throws: HerdrAgentInventoryError.self) {
            try await HerdrAgentInventory.fetch(using: service)
        }
        #expect(transport.structuredCommandsRun.count == 3)
        #expect(transport.structuredCommandsRun.allSatisfy {
            $0.timeout > .zero && $0.outputLimit == HerdrAgentInventory.outputLimit
        })
    }

    private func result(_ output: String) -> Result<SSHCommandResult, SSHCommandExecutionError> {
        .success(.init(exitStatus: 0, stdout: Data(output.utf8), stderr: Data()))
    }

    @MainActor
    private func makeService() async throws -> (SSHService, FakeSSHTransport) {
        let keyStore = KeyStore(backing: InMemoryKeychain())
        let keyID = try keyStore.generateEd25519(label: "inventory")
        let transport = FakeSSHTransport()
        let host = Host(name: "h", address: "192.0.2.60", username: "alice",
                        keyID: keyID, defaultWorkdir: "/home/alice")
        let connection = HostConnection(
            host: host,
            keyStore: keyStore,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: "inventory.\(UUID())")!),
            transport: transport
        )
        await connection.connect()
        return (try #require(connection.provisioningCommandRunner), transport)
    }
}
