import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct HerdrUpdateStatusParsingTests {

    /// The real shape of `herdr status --json` on 0.8.2, trimmed to the keys
    /// that matter here.
    private let current = """
    {"client":{"version":"0.8.2","channel":"stable","protocol":20},\
    "server":{"status":"running","running":true,"version":"0.8.2","restart_needed":false},\
    "update":{"restart_needed":false}}
    """

    @Test func versionsAndReadinessAreReadOutOfTheStatusJSON() throws {
        let status = try HerdrUpdate.parseStatus(current)
        #expect(status.clientVersion == "0.8.2")
        #expect(status.serverVersion == "0.8.2")
        #expect(status.serverRunning)
        #expect(!status.updateReady)
    }

    @Test func aPendingRestartMeansAnUpdateIsReady() throws {
        // Herdr's session menu shows "update ready" when a newer binary is
        // installed than the server is running; status reports it here.
        let ready = current.replacingOccurrences(
            of: "\"update\":{\"restart_needed\":false}",
            with: "\"update\":{\"restart_needed\":true}")
        #expect(try HerdrUpdate.parseStatus(ready).updateReady)
    }

    @Test func shellNoiseBeforeTheJSONIsTolerated() throws {
        // The command runs through a shell that may print anything first.
        #expect(try HerdrUpdate.parseStatus("Welcome to Ubuntu\n" + current).clientVersion == "0.8.2")
    }

    @Test func aStoppedServerReportsNoVersionRatherThanLying() throws {
        let stopped = """
        {"client":{"version":"0.8.2"},"server":{"status":"stopped","running":false},\
        "update":{"restart_needed":false}}
        """
        let status = try HerdrUpdate.parseStatus(stopped)
        #expect(status.serverVersion == nil)
        #expect(!status.serverRunning)
    }

    @Test func unreadableOutputThrowsRatherThanReportingAStatus() {
        // "No update pending" is a different statement from "I could not read
        // the answer", and the UI acts on it.
        #expect(throws: HerdrUpdate.Failure.self) {
            _ = try HerdrUpdate.parseStatus("herdr: command not found")
        }
    }

    @Test func theUpdateCommandTriesLiveHandoff() {
        // --handoff lets a running server pick the new binary up without
        // killing the session; without a server it is a plain install.
        #expect(HerdrUpdate.updateCommand == "herdr update --handoff")
        #expect(HerdrUpdate.statusCommand == "herdr status --json")
    }
}

@Suite @MainActor struct HerdrUpdateOperationTests {

    private func stub(_ transport: FakeSSHTransport, _ outputs: [String]) {
        transport.structuredCommandResults = outputs.map { output in
            .success(SSHCommandResult(exitStatus: 0, stdout: Data(output.utf8), stderr: Data()))
        }
    }

    private func statusJSON(version: String, ready: Bool) -> String {
        """
        {"client":{"version":"\(version)"},\
        "server":{"status":"running","running":true,"version":"\(version)","restart_needed":false},\
        "update":{"restart_needed":\(ready)}}
        """
    }

    private func makeService() async throws -> (SSHService, FakeSSHTransport) {
        let host = Host(name: "h", address: "10.0.0.1", port: 22,
                        username: "alice", keyID: "k", defaultWorkdir: "/home/alice")
        let transport = FakeSSHTransport()
        let knownHosts = KnownHostsStore(defaults: UserDefaults(suiteName: "msam.hu.\(UUID())")!)
        let service = SSHService(host: host, transport: transport, knownHosts: knownHosts)
        try await service.connect(key: SSHKeyMaterial(ed25519Seed: Data(repeating: 4, count: 32))) { _, _ in true }
        return (service, transport)
    }

    @Test func probeAsksTheHostAndParsesItsAnswer() async throws {
        let (service, transport) = try await makeService()
        stub(transport, [statusJSON(version: "0.8.2", ready: true)])
        let status = try await HerdrUpdate.probe(using: service)
        #expect(status.updateReady)
        #expect(transport.commandsRun.contains { $0.contains("herdr status --json") })
    }

    @Test func updateRunsThenReprobesSoTheAnswerIsTheNewState() async throws {
        let (service, transport) = try await makeService()
        stub(transport, ["downloaded 0.8.3\nhandoff complete\n",
                         statusJSON(version: "0.8.3", ready: false)])
        let result = try await HerdrUpdate.update(using: service)
        #expect(result.output.contains("handoff complete"))
        #expect(result.refreshed?.serverVersion == "0.8.3")
        #expect(transport.commandsRun.contains { $0.contains("herdr update --handoff") })
    }

    @Test func aFailedReprobeAfterUpdateStillReturnsTheUpdatesOutput() async throws {
        // Mid-handoff the server may be briefly unreachable; the update's own
        // output is still the useful part and must not be discarded.
        let (service, transport) = try await makeService()
        transport.structuredCommandResults = [
            .success(SSHCommandResult(exitStatus: 0,
                                      stdout: Data("handoff complete\n".utf8), stderr: Data())),
            .failure(SSHCommandExecutionError.ambiguousDisconnect),
        ]
        let result = try await HerdrUpdate.update(using: service)
        #expect(result.output.contains("handoff complete"))
        #expect(result.refreshed == nil)
    }
}
