import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite @MainActor struct AppActionDispatcherTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "AppActionDispatcherTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    private func makeHost(name: String = "Foundry") -> Host {
        Host(
            name: name,
            address: "192.0.2.1",
            port: 22,
            username: "user",
            keyID: "key-1",
            defaultWorkdir: "/home/user"
        )
    }

    private func makeSession(
        transport: FakeSSHTransport,
        host: Host? = nil,
        sessionName: String? = nil,
        live: Bool = false
    ) async throws -> HerdrHostSession {
        let h = host ?? makeHost()
        let suite = "AppActionDispatcherTests.Session.\(UUID().uuidString)"
        let keyStore = KeyStore(backing: InMemoryKeychain())
        let keyID = try keyStore.generateEd25519(label: "test-key")
        var configuredHost = h
        configuredHost.keyID = keyID
        let connection = HostConnection(
            host: configuredHost,
            keyStore: keyStore,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: suite)!),
            transport: transport
        )
        let session = HerdrHostSession(
            connection: connection,
            sessionName: sessionName
        )
        if live {
            await session.start()
        }
        return session
    }

    // MARK: - HerdrWindowCommands Formats

    @Test func formatsHerdrSplitPaneCommand() {
        let downCmd = HerdrWindowCommands.makeSplitPaneCommand(direction: .down)
        #expect(downCmd.contains("PATH=\"$HOME/.local/bin:$PATH\"; export PATH"))
        #expect(downCmd.contains("herdr pane split"))
        #expect(downCmd.contains("--direction down"))
        #expect(downCmd.contains("--focus"))

        let rightCmd = HerdrWindowCommands.makeSplitPaneCommand(direction: .right)
        #expect(rightCmd.contains("--direction right"))
        #expect(rightCmd.contains("--focus"))
    }

    @Test func formatsHerdrCreateTabCommand() {
        let cmd = HerdrWindowCommands.makeCreateTabCommand(label: "tests")
        #expect(cmd.contains("PATH=\"$HOME/.local/bin:$PATH\"; export PATH"))
        #expect(cmd.contains("herdr tab create"))
        #expect(cmd.contains("--label 'tests'"))
        #expect(cmd.contains("--focus"))

        let complexCmd = HerdrWindowCommands.makeCreateTabCommand(label: "my 'quoted' tab")
        #expect(complexCmd.contains("--label 'my '\\''quoted'\\'' tab'"))
    }

    @Test func formatsCloseAndZoomCommands() {
        let closeCmd = HerdrWindowCommands.makeClosePaneCommand()
        #expect(closeCmd.contains("PATH=\"$HOME/.local/bin:$PATH\"; export PATH"))
        #expect(closeCmd.contains("herdr pane close"))

        let zoomCmd = HerdrWindowCommands.makeZoomPaneCommand()
        #expect(zoomCmd.contains("PATH=\"$HOME/.local/bin:$PATH\"; export PATH"))
        #expect(zoomCmd.contains("herdr pane zoom"))
    }

    // MARK: - App Navigation Dispatching

    @Test func dispatchesSwitchHostTabSuccessfully() async throws {
        let defaults = makeDefaults()
        let hostStore = HostStore(defaults: defaults)
        let tabStore = HostTabStore(defaults: defaults)

        let host1 = makeHost(name: "Forge")
        let host2 = makeHost(name: "Foundry")
        hostStore.add(host1)
        hostStore.add(host2)

        let tab1 = tabStore.open(hostID: host1.id, sessionName: nil)
        let tab2 = tabStore.open(hostID: host2.id, sessionName: "dev")

        tabStore.select(tab1.id)
        #expect(tabStore.selectedTabID == tab1.id)

        let dispatcher = AppActionDispatcher(
            tabStore: tabStore,
            hostStore: hostStore,
            getActiveSession: { nil },
            onOpenSheet: { _ in }
        )

        // Switch to host2 by host name
        try await dispatcher.dispatch(.switchHostTab(name: "Foundry"))
        #expect(tabStore.selectedTabID == tab2.id)

        // Switch back to host1
        try await dispatcher.dispatch(.switchHostTab(name: "Forge"))
        #expect(tabStore.selectedTabID == tab1.id)

        // Switch by session name
        try await dispatcher.dispatch(.switchHostTab(name: "dev"))
        #expect(tabStore.selectedTabID == tab2.id)
    }

    @Test func throwsWhenSwitchTabNotFound() async throws {
        let defaults = makeDefaults()
        let hostStore = HostStore(defaults: defaults)
        let tabStore = HostTabStore(defaults: defaults)

        let host1 = makeHost(name: "Forge")
        hostStore.add(host1)
        _ = tabStore.open(hostID: host1.id, sessionName: nil)

        let dispatcher = AppActionDispatcher(
            tabStore: tabStore,
            hostStore: hostStore,
            getActiveSession: { nil },
            onOpenSheet: { _ in }
        )

        await #expect(throws: AppActionDispatcher.ActionError.tabNotFound("Spark")) {
            try await dispatcher.dispatch(.switchHostTab(name: "Spark"))
        }
    }

    @Test func dispatchesOpenHostTabForExistingOrNew() async throws {
        let defaults = makeDefaults()
        let hostStore = HostStore(defaults: defaults)
        let tabStore = HostTabStore(defaults: defaults)

        let host1 = makeHost(name: "Forge")
        let host2 = makeHost(name: "Spark")
        hostStore.add(host1)
        hostStore.add(host2)

        let tab1 = tabStore.open(hostID: host1.id, sessionName: nil)
        #expect(tabStore.tabs.count == 1)

        let dispatcher = AppActionDispatcher(
            tabStore: tabStore,
            hostStore: hostStore,
            getActiveSession: { nil },
            onOpenSheet: { _ in }
        )

        // 1. Open existing tab (should select tab1 without creating new tab)
        try await dispatcher.dispatch(.openHostTab(hostName: "Forge"))
        #expect(tabStore.tabs.count == 1)
        #expect(tabStore.selectedTabID == tab1.id)

        // 2. Open new host tab from hostStore
        try await dispatcher.dispatch(.openHostTab(hostName: "Spark"))
        #expect(tabStore.tabs.count == 2)
        #expect(tabStore.selectedTabID != tab1.id)
        let newTab = tabStore.tabs.first { $0.hostID == host2.id }
        #expect(newTab != nil)
        #expect(tabStore.selectedTabID == newTab?.id)

        // 3. Open host that does not exist in hostStore
        await #expect(throws: AppActionDispatcher.ActionError.hostNotFound("UnknownHost")) {
            try await dispatcher.dispatch(.openHostTab(hostName: "UnknownHost"))
        }
    }

    @Test func dispatchesOpenAppSheet() async throws {
        let defaults = makeDefaults()
        let hostStore = HostStore(defaults: defaults)
        let tabStore = HostTabStore(defaults: defaults)

        var openedSheet: AppSheetType? = nil
        let dispatcher = AppActionDispatcher(
            tabStore: tabStore,
            hostStore: hostStore,
            getActiveSession: { nil },
            onOpenSheet: { openedSheet = $0 }
        )

        try await dispatcher.dispatch(.openAppSheet(sheet: .metrics))
        #expect(openedSheet == .metrics)

        try await dispatcher.dispatch(.openAppSheet(sheet: .pulse))
        #expect(openedSheet == .pulse)

        try await dispatcher.dispatch(.openAppSheet(sheet: .settings))
        #expect(openedSheet == .settings)
    }

    // MARK: - Herdr Remote Action Dispatching

    @Test func throwsWhenHostNotConnectedForSplit() async throws {
        let defaults = makeDefaults()
        let hostStore = HostStore(defaults: defaults)
        let tabStore = HostTabStore(defaults: defaults)

        // 1. Nil session
        let dispatcherNil = AppActionDispatcher(
            tabStore: tabStore,
            hostStore: hostStore,
            getActiveSession: { nil },
            onOpenSheet: { _ in }
        )

        await #expect(throws: AppActionDispatcher.ActionError.hostNotConnected) {
            try await dispatcherNil.dispatch(.splitPane(direction: .down, stagedCommand: nil))
        }

        // 2. Session exists but is idle / not live
        let transport = FakeSSHTransport()
        let session = try await makeSession(transport: transport, live: false)
        #expect(session.status != .live)

        let dispatcherIdle = AppActionDispatcher(
            tabStore: tabStore,
            hostStore: hostStore,
            getActiveSession: { session },
            onOpenSheet: { _ in }
        )

        await #expect(throws: AppActionDispatcher.ActionError.hostNotConnected) {
            try await dispatcherIdle.dispatch(.splitPane(direction: .down, stagedCommand: nil))
        }

        await #expect(throws: AppActionDispatcher.ActionError.hostNotConnected) {
            try await dispatcherIdle.dispatch(.createHerdrTab(label: "tests", stagedCommand: nil))
        }

        await #expect(throws: AppActionDispatcher.ActionError.hostNotConnected) {
            try await dispatcherIdle.dispatch(.closePane)
        }

        await #expect(throws: AppActionDispatcher.ActionError.hostNotConnected) {
            try await dispatcherIdle.dispatch(.zoomPane)
        }
    }

    @Test func dispatchesSplitPaneWithStagedCommandWhenLive() async throws {
        let defaults = makeDefaults()
        let hostStore = HostStore(defaults: defaults)
        let tabStore = HostTabStore(defaults: defaults)

        let transport = FakeSSHTransport()
        let session = try await makeSession(transport: transport, live: true)
        #expect(session.status == .live)

        let dispatcher = AppActionDispatcher(
            tabStore: tabStore,
            hostStore: hostStore,
            getActiveSession: { session },
            onOpenSheet: { _ in }
        )

        try await dispatcher.dispatch(.splitPane(direction: .down, stagedCommand: "pytest -v"))

        // Verify split command executed
        let splitCommandRun = transport.structuredCommandsRun.contains {
            $0.command.contains("herdr pane split --direction down --focus")
        }
        #expect(splitCommandRun)

        // Verify staged command fed to PTY without trailing newline
        let lastPTY = try #require(transport.openedPTYs.last)
        let fedInput = String(decoding: lastPTY.sent, as: UTF8.self)
        #expect(fedInput == "pytest -v")
        #expect(!fedInput.hasSuffix("\n"))
    }

    @Test func dispatchesCreateHerdrTabWithStagedCommandWhenLive() async throws {
        let defaults = makeDefaults()
        let hostStore = HostStore(defaults: defaults)
        let tabStore = HostTabStore(defaults: defaults)

        let transport = FakeSSHTransport()
        let session = try await makeSession(transport: transport, live: true)
        #expect(session.status == .live)

        let dispatcher = AppActionDispatcher(
            tabStore: tabStore,
            hostStore: hostStore,
            getActiveSession: { session },
            onOpenSheet: { _ in }
        )

        try await dispatcher.dispatch(.createHerdrTab(label: "logs", stagedCommand: "tail -f app.log"))

        // Verify create tab command executed
        let createTabRun = transport.structuredCommandsRun.contains {
            $0.command.contains("herdr tab create") &&
            $0.command.contains("--label") &&
            $0.command.contains("logs") &&
            $0.command.contains("--focus")
        }
        #expect(createTabRun)

        // Verify staged command fed to PTY without trailing newline
        let lastPTY = try #require(transport.openedPTYs.last)
        let fedInput = String(decoding: lastPTY.sent, as: UTF8.self)
        #expect(fedInput == "tail -f app.log")
        #expect(!fedInput.hasSuffix("\n"))
    }

    @Test func dispatchesCloseAndZoomCommandsWhenLive() async throws {
        let defaults = makeDefaults()
        let hostStore = HostStore(defaults: defaults)
        let tabStore = HostTabStore(defaults: defaults)

        let transport = FakeSSHTransport()
        let session = try await makeSession(transport: transport, live: true)
        #expect(session.status == .live)

        let dispatcher = AppActionDispatcher(
            tabStore: tabStore,
            hostStore: hostStore,
            getActiveSession: { session },
            onOpenSheet: { _ in }
        )

        try await dispatcher.dispatch(.closePane)
        let closeRun = transport.structuredCommandsRun.contains {
            $0.command.contains("herdr pane close")
        }
        #expect(closeRun)

        try await dispatcher.dispatch(.zoomPane)
        let zoomRun = transport.structuredCommandsRun.contains {
            $0.command.contains("herdr pane zoom")
        }
        #expect(zoomRun)
    }
}
