import Foundation
import Testing
@testable import MultiSessionAIManager

/// The pill beside a host's name: what the host service says is waiting there.
@Suite struct HostAttentionSummaryTests {
    private func line(blocked: [(String, String)] = [], done: [(String, String)] = [], rateLimited: [String] = [],
                      available: Bool = true, blockedCount: Int? = nil, doneCount: Int? = nil) -> String {
        func items(_ list: [(String, String)]) -> [[String: Any]] {
            list.enumerated().map { ["session": $1.0, "pane_id": "w:p\($0)", "name": $1.1, "agent": "claude"] }
        }
        let object: [String: Any] = [
            "available": available, "blocked": items(blocked), "done": items(done), "rate_limited": rateLimited,
            "blocked_count": blockedCount ?? blocked.count, "done_count": doneCount ?? done.count,
        ]
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return HostAttention.linePrefix + String(decoding: data, as: UTF8.self)
    }

    private func attention(_ line: String) throws -> HostAttention {
        try #require(HostAttention.parse(line: line))
    }

    @Test func theServicesLineIsRead() throws {
        let value = try attention(line(blocked: [("default", "needs an answer")], done: [("desktop", "finished")],
                                       rateLimited: ["codex"]))
        #expect(value.available)
        #expect(value.blocked.map(\.name) == ["needs an answer"])
        #expect(value.blocked.first?.session == "default")
        #expect(value.blocked.first?.paneID == "w:p0")
        #expect(value.done.map(\.session) == ["desktop"])
        #expect(value.rateLimited == ["codex"])
    }

    @Test func anythingElseTheHostPrintsIsNotASummary() {
        #expect(HostAttention.parse(line: "Welcome to forge") == nil)
        #expect(HostAttention.parse(line: "MSAM_ATTENTION=not json") == nil)
        #expect(HostAttention.parse(line: "") == nil)
    }

    @Test func aBlockedAgentIsAnErrorAndOutranksEverythingElse() throws {
        let value = try attention(line(blocked: [("default", "a"), ("default", "b")], done: [("default", "c")],
                                       rateLimited: ["codex"]))
        #expect(value.pill == HostAttentionPill(level: .error, count: 2))
    }

    @Test func aRateLimitedProviderIsAWarning() throws {
        let value = try attention(line(done: [("default", "c")], rateLimited: ["codex", "claude_code"]))
        #expect(value.pill == HostAttentionPill(level: .warning, count: 2))
    }

    @Test func aFinishedAgentIsInformation() throws {
        #expect(try attention(line(done: [("default", "c")])).pill == HostAttentionPill(level: .info, count: 1))
    }

    @Test func aQuietHostHasNoPill() throws {
        #expect(try attention(line()).pill == nil)
    }

    @Test func aLongListIsCountedInFullThoughOnlyPartOfItIsSent() throws {
        let twenty = (0..<20).map { ("default", "agent \($0)") }
        #expect(try attention(line(blocked: twenty, blockedCount: 60)).pill == HostAttentionPill(level: .error, count: 60))
    }

    @Test func withoutAnInventoryOnlyWhatIsStillKnownIsShown() throws {
        // The service could not read Herdr: it must not look like "nothing is blocked".
        #expect(try attention(line(available: false)).pill == nil)
        #expect(try attention(line(blocked: [("default", "stale")], done: [("default", "stale")], available: false)).pill == nil)
        #expect(try attention(line(blocked: [("default", "stale")], available: false)).spokenSummary == nil)
        #expect(try attention(line(rateLimited: ["codex"], available: false)).pill
                == HostAttentionPill(level: .warning, count: 1))
    }

    @Test func aTabOnOneHerdrSessionCountsOnlyThatSession() throws {
        let value = try attention(line(blocked: [("default", "a"), ("desktop", "b"), ("desktop", "c")],
                                       done: [("default", "d")], rateLimited: ["codex"]))
        let desktop = value.scoped(to: "desktop")
        #expect(desktop.pill == HostAttentionPill(level: .error, count: 2))
        #expect(desktop.done.isEmpty)
        #expect(desktop.rateLimited == ["codex"], "A rate limit belongs to the host, not to a session")
        #expect(value.scoped(to: nil) == value, "A tab on the host as a whole sees every session")
        #expect(value.scoped(to: "") == value)
        #expect(value.scoped(to: "elsewhere").pill == HostAttentionPill(level: .warning, count: 1))
    }

    @Test func theSummaryIsSpokenInFull() throws {
        #expect(try attention(line(blocked: [("default", "a")])).spokenSummary == "1 agent is waiting for you")
        #expect(try attention(line(blocked: [("default", "a"), ("default", "b")], done: [("default", "c")],
                                   rateLimited: ["codex"])).spokenSummary
                == "2 agents are waiting for you, 1 provider is rate limited, 1 agent has finished")
        #expect(try attention(line(done: [("default", "a"), ("default", "b")])).spokenSummary == "2 agents have finished")
        #expect(try attention(line()).spokenSummary == nil)
    }
}

/// The background connection that keeps those pills current for every open host tab.
@Suite(.serialized) @MainActor struct HostAttentionWatchTests {
    private let blockedLine = #"MSAM_ATTENTION={"available":true,"blocked":[{"session":"default","pane_id":"w:p1","name":"a","agent":"claude"}],"done":[],"rate_limited":[],"blocked_count":1,"done_count":0}"# + "\n"
    private let quietLine = #"MSAM_ATTENTION={"available":true,"blocked":[],"done":[],"rate_limited":[],"blocked_count":0,"done_count":0}"# + "\n"

    @MainActor private final class Rig {
        let keys = KeyStore(backing: InMemoryKeychain())
        let knownHosts = KnownHostsStore(defaults: UserDefaults(suiteName: "msam.attention.\(UUID())")!)
        var transports: [FakeSSHTransport] = []
        lazy var center = HostAttentionCenter(
            keyStore: keys, knownHosts: knownHosts,
            makeTransport: { [unowned self] in
                let transport = FakeSSHTransport()
                self.transports.append(transport)
                return transport
            },
            timing: .init(retryDelays: [.milliseconds(30)], unsupportedRetry: .seconds(120),
                          unknownHostRecheck: .milliseconds(20),
                          silenceLimit: .seconds(60), checkInterval: .milliseconds(10)))

        func host(_ name: String, known: Bool = true) throws -> Host {
            let host = Host(name: name, address: "10.0.0.\(transports.count + 1 + Int.random(in: 10...200))",
                            username: "alice", keyID: try keys.generateEd25519(label: name), defaultWorkdir: "/home/alice")
            if known {
                knownHosts.pin(host: host.knownHostsKey, fingerprint: FakeSSHTransport().hostKeyToPresent)
            }
            return host
        }

        /// The notification streams one transport has opened, oldest first.
        func streams(_ index: Int = 0) -> [FakePTYChannel] {
            guard transports.indices.contains(index) else { return [] }
            return transports[index].openedPTYs.filter { $0.command.contains("attention") }
        }
    }

    private func eventually(_ what: String = "condition", timeout: Duration = .seconds(3),
                            _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(condition(), "timed out waiting for: \(what)")
    }

    private func never(for duration: Duration = .milliseconds(250), _ what: String,
                       _ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            if condition() { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!condition(), "must not happen: \(what)")
    }

    @Test func watchingAHostOpensOnlyItsNotificationStreamAndShowsWhatItSays() async throws {
        let rig = Rig()
        let host = try rig.host("Forge")
        let tab = HostTab(hostID: host.id, sessionName: nil)
        #expect(rig.center.pill(for: tab) == nil)

        rig.center.watch([host])
        await eventually("the stream opens") { rig.streams().count == 1 }
        let stream = rig.streams()[0]
        #expect(stream.command.contains("msam-host-agent"))
        #expect(stream.command.contains("attention --loop"))
        #expect(rig.transports[0].openedPTYs.count == 1, "No terminal, no metrics: notifications only")

        stream.emit(Data(blockedLine.utf8))
        await eventually("the pill appears") { rig.center.pill(for: tab) == HostAttentionPill(level: .error, count: 1) }
        stream.emit(Data(quietLine.utf8))
        await eventually("the pill clears") { rig.center.pill(for: tab) == nil }
        await rig.center.stopAll()
    }

    @Test func aSummarySplitAcrossTwoPacketsIsStillRead() async throws {
        let rig = Rig()
        let host = try rig.host("Forge")
        rig.center.watch([host])
        await eventually("the stream opens") { rig.streams().count == 1 }
        let bytes = Array(blockedLine.utf8)
        rig.streams()[0].emit(Data(bytes[..<40]))
        rig.streams()[0].emit(Data(bytes[40...]))
        await eventually("the pill appears") { rig.center.pill(for: HostTab(hostID: host.id, sessionName: nil)) != nil }
        await rig.center.stopAll()
    }

    @Test func aHostThatWasNeverConnectedToIsNotContactedInTheBackground() async throws {
        // Trusting a host key for the first time is something the user does by
        // opening the host, not something a background watch does for them.
        let rig = Rig()
        let host = try rig.host("New", known: false)
        rig.center.watch([host])
        await never("a connection attempt") { rig.transports.contains { $0.connectAttemptCount > 0 } }
        await rig.center.stopAll()
    }

    @Test func aChangedHostKeyIsNeitherTrustedNorRetriedInALoop() async throws {
        let rig = Rig()
        let host = try rig.host("Forge")
        rig.knownHosts.pin(host: host.knownHostsKey, fingerprint: "SOME-OTHER-KEY")
        rig.center.watch([host])
        await eventually("one attempt") { rig.transports.first?.connectAttemptCount == 1 }
        await never("a stream or a second attempt") {
            !rig.streams().isEmpty || (rig.transports.first?.connectAttemptCount ?? 0) > 1
        }
        #expect(rig.knownHosts.verify(host: host.knownHostsKey, fingerprint: "SOME-OTHER-KEY") == .match)
        await rig.center.stopAll()
    }

    @Test func whenTheStreamEndsThePillGoesAndTheWatchComesBack() async throws {
        let rig = Rig()
        let host = try rig.host("Forge")
        let tab = HostTab(hostID: host.id, sessionName: nil)
        rig.center.watch([host])
        await eventually("the stream opens") { rig.streams().count == 1 }
        rig.streams()[0].emit(Data(blockedLine.utf8))
        await eventually("the pill appears") { rig.center.pill(for: tab) != nil }

        rig.streams()[0].close()
        await eventually("the pill goes: nothing is known without a stream") { rig.center.pill(for: tab) == nil }
        await eventually("a new stream opens") { rig.streams().count == 2 }
        rig.streams()[1].emit(Data(blockedLine.utf8))
        await eventually("the pill returns") { rig.center.pill(for: tab) != nil }
        await rig.center.stopAll()
    }

    @Test func aStreamThatGoesSilentIsTreatedAsDead() async throws {
        let rig = Rig()
        rig.center = HostAttentionCenter(
            keyStore: rig.keys, knownHosts: rig.knownHosts,
            makeTransport: { let transport = FakeSSHTransport(); rig.transports.append(transport); return transport },
            timing: .init(retryDelays: [.milliseconds(30)], unsupportedRetry: .seconds(120),
                          unknownHostRecheck: .milliseconds(20),
                          silenceLimit: .milliseconds(150), checkInterval: .milliseconds(10)))
        let host = try rig.host("Forge")
        let tab = HostTab(hostID: host.id, sessionName: nil)
        rig.center.watch([host])
        await eventually("the stream opens") { rig.streams().count == 1 }
        rig.streams()[0].emit(Data(blockedLine.utf8))
        await eventually("the pill appears") { rig.center.pill(for: tab) != nil }
        // The host sends a heartbeat; none arriving means the stream is not to be believed.
        await eventually("the pill goes") { rig.center.pill(for: tab) == nil }
        await eventually("the stale stream is closed and replaced") { rig.streams().count == 2 && rig.streams()[0].closed }
        await rig.center.stopAll()
    }

    @Test func aHostWhoseServiceHasNoNotificationStreamIsNotHammered() async throws {
        // An older host service rejects the command, so the stream ends at once
        // without a line. Asking again every few seconds would be pointless.
        let rig = Rig()
        let host = try rig.host("Old")
        rig.center.watch([host])
        await eventually("the stream opens") { rig.streams().count == 1 }
        rig.streams()[0].close()
        await never(for: .milliseconds(300), "a second attempt so soon") { rig.streams().count > 1 }
        #expect(rig.transports[0].disconnectCount == 0, "The connection is kept for the later retry")
        await rig.center.stopAll()
    }

    @Test func leavingTheAppStopsEveryWatchAndClearsThePills() async throws {
        let rig = Rig()
        let forge = try rig.host("Forge"), spark = try rig.host("Spark")
        rig.center.watch([forge, spark])
        await eventually("both streams open") { rig.streams(0).count == 1 && rig.streams(1).count == 1 }
        rig.streams(0)[0].emit(Data(blockedLine.utf8))
        await eventually("the pill appears") { rig.center.pill(for: HostTab(hostID: forge.id, sessionName: nil)) != nil }

        await rig.center.stopAll()

        #expect(rig.center.pill(for: HostTab(hostID: forge.id, sessionName: nil)) == nil)
        #expect(rig.streams(0)[0].closed && rig.streams(1)[0].closed)
        #expect(rig.transports.allSatisfy { $0.disconnectCount >= 1 })
        await never("a reconnect after stopping") { rig.streams(0).count > 1 || rig.streams(1).count > 1 }
    }

    @Test func closingAHostsLastTabStopsItsWatchAndLeavesTheOthersAlone() async throws {
        let rig = Rig()
        let forge = try rig.host("Forge"), spark = try rig.host("Spark")
        rig.center.watch([forge, spark])
        await eventually("both streams open") { rig.streams(0).count == 1 && rig.streams(1).count == 1 }

        rig.center.watch([forge])

        await eventually("Spark's stream closes") { rig.streams(1)[0].closed }
        #expect(!rig.streams(0)[0].closed)
        rig.center.watch([forge, forge])
        await never("a second watch on the same host") { rig.transports.count > 2 || rig.streams(0).count > 1 }
        await rig.center.stopAll()
    }

    @Test func aTabBoundToOneSessionShowsOnlyThatSessionsAgents() async throws {
        let rig = Rig()
        let host = try rig.host("Forge")
        rig.center.watch([host])
        await eventually("the stream opens") { rig.streams().count == 1 }
        rig.streams()[0].emit(Data(blockedLine.utf8))     // blocked in "default"
        await eventually("the host tab shows it") { rig.center.pill(for: HostTab(hostID: host.id, sessionName: nil)) != nil }
        #expect(rig.center.pill(for: HostTab(hostID: host.id, sessionName: "desktop")) == nil)
        #expect(rig.center.pill(for: HostTab(hostID: host.id, sessionName: "default")) == HostAttentionPill(level: .error, count: 1))
        #expect(rig.center.pill(for: HostTab(hostID: UUID(), sessionName: nil)) == nil)
        await rig.center.stopAll()
    }
}
