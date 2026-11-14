import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite @MainActor struct HerdrPluginUpdateTests {
    private let oldCommit = String(repeating: "a", count: 40)
    private let newCommit = String(repeating: "b", count: 40)
    private let location = #"MSAM_SOFTWARE={"path":"/home/alice/software.py","present":true}"#
    private let setup = #"MSAM_SOFTWARE={"plugins":[]}"#

    private func inventory(commit: String, enabled: Bool = true) -> String {
        """
        {"result":{"plugins":[{"plugin_id":"viewer","name":"Viewer","version":"1","enabled":\(enabled),
        "source":{"kind":"github","owner":"owner","repo":"plugins","subdir":"viewer","resolved_commit":"\(commit)"}}]}}
        """
    }

    private func updates(ref: String? = nil) -> String {
        """
        MSAM_SOFTWARE={"updates":[{"pluginID":"viewer","source":"owner/plugins/viewer","installedCommit":"\(oldCommit)",
        "availableCommit":"\(newCommit)","trackingRef":\(ref.map { "\"\($0)\"" } ?? "null")}]}
        """.replacingOccurrences(of: "\n", with: "")
    }

    private func makeModel() async -> (HerdrPluginManagerModel, FakeSSHTransport) {
        let transport = FakeSSHTransport()
        let keys = KeyStore(backing: InMemoryKeychain())
        let keyID = try! keys.generateEd25519(label: "plugins")
        let connection = HostConnection(
            host: Host(name: "h", address: "10.0.0.1", username: "alice", keyID: keyID, defaultWorkdir: "/home/alice"),
            keyStore: keys,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: "msam.updates.\(UUID())")!), transport: transport
        )
        await connection.connect()
        return (HerdrPluginManagerModel(connection: connection), transport)
    }

    private func stub(_ transport: FakeSSHTransport, _ outputs: [String]) {
        transport.structuredCommandResults = outputs.map {
            .success(SSHCommandResult(exitStatus: 0, stdout: Data($0.utf8), stderr: Data()))
        }
    }

    private func refreshOutputs(update: String? = nil, enabled: Bool = true) -> [String] {
        [inventory(commit: oldCommit, enabled: enabled), location, setup, "{}", location, update ?? updates()]
    }

    @Test func openingTheManagerChecksForPluginUpdatesOnTheHost() async {
        let (model, transport) = await makeModel()
        stub(transport, refreshOutputs())
        await model.refresh()
        #expect(transport.commandsRun.contains { $0.contains("'plugin-updates'") })
        #expect(model.listState == .loaded)
        #expect(model.updateCheckError == nil)
        #expect(model.availableUpdate(for: model.installed[0])?.availableCommit == newCommit)
        #expect(!model.isCheckingUpdates)
        await model.connection.disconnect()
    }

    @Test func installedActionsAndDuplicateRefreshAreBlockedDuringTheCheck() async throws {
        let (model, transport) = await makeModel()
        stub(transport, refreshOutputs())
        let gate = PluginUpdateGate()
        transport.beforeCommand = { command in
            if command.contains("'plugin-updates'") { await gate.pause() }
        }
        let refresh = Task { await model.refresh() }
        await gate.waitUntilEntered()
        #expect(model.isCheckingUpdates)
        #expect(model.installedActionsBlocked)
        #expect(model.listState == .loaded)
        let plugin = try #require(model.installed.first)
        let count = transport.commandsRun.count
        await model.uninstall(plugin)
        await model.update(plugin)
        await model.configureFileTransfer(for: plugin)
        await model.installKeybinding(PluginAction(id: "keys", title: "Keys", description: "", contexts: []), for: plugin)
        await model.install(source: "owner/other", ref: nil)
        await model.updateHerdr()
        await model.refresh()
        #expect(transport.commandsRun.count == count)
        await gate.resume()
        await refresh.value
        #expect(!model.installedActionsBlocked)
        await model.connection.disconnect()
    }

    @Test(arguments: [#"MSAM_SOFTWARE={"error":"Network unavailable"}"#, #"MSAM_SOFTWARE={}"#])
    func failedChecksKeepTheInventoryAndUnlockActions(response: String) async {
        let (model, transport) = await makeModel()
        stub(transport, refreshOutputs(update: response))
        await model.refresh()
        #expect(model.listState == .loaded)
        #expect(model.installed.count == 1)
        #expect(model.updateCheckError != nil)
        #expect(!model.installedActionsBlocked)
        #expect(model.availableUpdate(for: model.installed[0]) == nil)
        // Reopening/refreshing must make a fresh request, not cache a failure.
        stub(transport, refreshOutputs())
        await model.refresh()
        #expect(model.updateCheckError == nil)
        #expect(model.availableUpdate(for: model.installed[0]) != nil)
        await model.connection.disconnect()
    }

    @Test func cancellationClearsTheLoaderWithoutPublishingStaleUpdates() async {
        let (model, transport) = await makeModel()
        stub(transport, refreshOutputs())
        let gate = PluginUpdateGate()
        transport.beforeCommand = { command in
            if command.contains("'plugin-updates'") { await gate.pause() }
        }
        let refresh = Task { await model.refresh() }
        await gate.waitUntilEntered()
        refresh.cancel()
        await gate.resume()
        await refresh.value
        #expect(!model.isCheckingUpdates)
        #expect(model.pluginUpdates.isEmpty)
        #expect(model.updateCheckError == nil)
        await model.connection.disconnect()
    }

    @Test(arguments: [true, false])
    func updatingVerifiesTheNewRevisionAndPreservesEnabledState(enabled: Bool) async throws {
        let (model, transport) = await makeModel()
        stub(transport, refreshOutputs(enabled: enabled))
        await model.refresh()
        let plugin = try #require(model.installed.first)
        let plan = "MSAM_SOFTWARE={\"source\":\"owner/plugins/viewer\",\"ref\":\"\(newCommit)\",\"pluginID\":\"viewer\",\"dependencies\":[]}"
        // Simulate Herdr enabling a disabled plugin on reinstall; the manager
        // must restore its previous state and verify the final inventory.
        var outputs = [location, plan, inventory(commit: oldCommit, enabled: enabled), "Installed", inventory(commit: newCommit)]
        if !enabled { outputs += ["Disabled", inventory(commit: newCommit, enabled: false)] }
        outputs += [location, setup]
        stub(transport, outputs)
        await model.update(plugin)
        #expect(model.installed.first?.resolvedCommit == newCommit)
        #expect(model.installed.first?.enabled == enabled)
        #expect(model.noticeMessage?.contains("Updated") == true)
        #expect(model.errorMessage == nil)
        #expect(model.availableUpdate(for: model.installed[0]) == nil)
        #expect(!model.isBusy)
        #expect(model.operation == nil)
        #expect(transport.commandsRun.contains { $0.contains("herdr plugin install owner/plugins/viewer --yes --ref \(newCommit)") })
        await model.connection.disconnect()
    }

    @Test func anUpdateRetainsItsNamedBranchForFutureChecks() async throws {
        let (model, transport) = await makeModel()
        stub(transport, refreshOutputs(update: updates(ref: "release/stable")))
        await model.refresh()
        let plugin = try #require(model.installed.first)
        stub(transport, [location,
            "MSAM_SOFTWARE={\"source\":\"owner/plugins/viewer\",\"ref\":\"\(newCommit)\",\"pluginID\":\"viewer\",\"dependencies\":[]}",
            inventory(commit: oldCommit), "Installed", inventory(commit: newCommit), location, setup])
        await model.update(plugin)
        #expect(transport.commandsRun.contains { $0.contains("herdr plugin install owner/plugins/viewer --yes --ref \(newCommit)") })
        #expect(transport.commandsRun.contains { $0.contains("'--tracking-ref'") && $0.contains("'release/stable'") })
        #expect(model.errorMessage == nil)
        #expect(model.installed.first?.resolvedCommit == newCommit)
        await model.connection.disconnect()
    }

    @Test(arguments: ["different-plugin", "viewer"])
    func mismatchedIdentityOrUnchangedRevisionCannotReportSuccess(pluginID: String) async throws {
        let (model, transport) = await makeModel()
        stub(transport, refreshOutputs())
        await model.refresh()
        let plugin = try #require(model.installed.first)
        let start = transport.commandsRun.count
        stub(transport, [location,
            "MSAM_SOFTWARE={\"source\":\"owner/plugins/viewer\",\"ref\":\"\(newCommit)\",\"pluginID\":\"\(pluginID)\",\"dependencies\":[]}",
            inventory(commit: oldCommit), "Installed", inventory(commit: oldCommit)])
        await model.update(plugin)
        #expect(model.errorMessage != nil)
        #expect(model.noticeMessage == nil)
        #expect(!model.isBusy)
        if pluginID != "viewer" {
            #expect(!transport.commandsRun.dropFirst(start).contains { $0.contains("herdr plugin install") })
        }
        await model.connection.disconnect()
    }
}

private actor PluginUpdateGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { release = $0 }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiter = $0 } }
    }
    func resume() { release?.resume(); release = nil }
}
