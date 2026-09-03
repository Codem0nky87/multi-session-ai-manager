import Foundation
import Testing
@testable import MultiSessionAIManager

@MainActor
private final class RestoreOperationEvents {
    private(set) var values: [String] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record(_ value: String) {
        values.append(value)
        let ready = waiters.filter { values.count >= $0.count }
        waiters.removeAll { values.count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    func waitForCount(_ count: Int) async {
        if values.count >= count { return }
        await withCheckedContinuation { continuation in
            waiters.append((count, continuation))
        }
    }
}

private actor RestoreOperationStartGate {
    private var isWaiting = false
    private var waitingContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func wait() async {
        isWaiting = true
        waitingContinuation?.resume()
        waitingContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
    }

    func waitUntilBlocked() async {
        if isWaiting { return }
        await withCheckedContinuation { continuation in
            waitingContinuation = continuation
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

@Suite @MainActor struct RootViewModelTests {
    /// `sharedTransport` lets a test inspect the PTY a session actually opened.
    /// Left nil, every session gets its own fake, so sessions stay independent.
    private func makeModel(
        sharedTransport: FakeSSHTransport? = nil
    ) throws -> (HostTabsModel, HostStore, HostTabStore, Host) {
        let suite = "RootViewModelTests.\(UUID().uuidString)"
        let hosts = HostStore(defaults: UserDefaults(suiteName: suite)!)
        let tabStore = HostTabStore(defaults: UserDefaults(suiteName: suite)!)
        let keyStore = KeyStore(backing: InMemoryKeychain())
        let host = Host(
            name: "mac",
            address: "192.0.2.10",
            username: "alice",
            keyID: try keyStore.generateEd25519(label: "thin-herdr"),
            defaultWorkdir: "/Users/alice"
        )
        hosts.add(host)
        let model = HostTabsModel(
            hostStore: hosts,
            tabStore: tabStore,
            keyStore: keyStore,
            knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: suite)!),
            makeTransport: { sharedTransport ?? FakeSSHTransport() }
        )
        return (model, hosts, tabStore, host)
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                Issue.record("Timed out waiting for condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func aSessionIsCreatedOncePerTabAndReused() throws {
        let (model, _, _, host) = try makeModel()
        let tab = HostTab(hostID: host.id, sessionName: nil)

        let first = model.session(for: tab)
        let second = model.session(for: tab)

        #expect(first === second)
    }

    @Test func twoTabsOnTheSameHostGetIndependentSessions() throws {
        let (model, _, _, host) = try makeModel()
        let a = HostTab(hostID: host.id, sessionName: nil)
        let b = HostTab(hostID: host.id, sessionName: "second")

        #expect(model.session(for: a) !== model.session(for: b))
    }

    @Test func onlyTheSelectedSessionRecoversWhileForeground() throws {
        let (model, _, _, host) = try makeModel()
        let selected = HostTab(hostID: host.id, sessionName: nil)
        let unselected = HostTab(hostID: host.id, sessionName: "second")
        let selectedSession = model.session(for: selected)
        let unselectedSession = model.session(for: unselected)

        model.setRecoveryContext(selectedTabID: selected.id, isForeground: true)

        #expect(selectedSession.automaticRecoveryEnabled)
        #expect(!unselectedSession.automaticRecoveryEnabled)
    }

    @Test func switchingSelectionTransfersAutomaticRecovery() throws {
        let (model, _, _, host) = try makeModel()
        let first = HostTab(hostID: host.id, sessionName: nil)
        let second = HostTab(hostID: host.id, sessionName: "second")
        let firstSession = model.session(for: first)
        let secondSession = model.session(for: second)
        model.setRecoveryContext(selectedTabID: first.id, isForeground: true)

        model.setRecoveryContext(selectedTabID: second.id, isForeground: true)

        #expect(!firstSession.automaticRecoveryEnabled)
        #expect(secondSession.automaticRecoveryEnabled)
    }

    @Test func reselectingADormantSessionRecoversItsLostPTY() async throws {
        let transport = FakeSSHTransport()
        let (model, _, _, host) = try makeModel(sharedTransport: transport)
        let first = HostTab(hostID: host.id, sessionName: nil)
        let second = HostTab(hostID: host.id, sessionName: "second")
        let session = model.session(for: first)
        model.setRecoveryContext(selectedTabID: first.id, isForeground: true)
        await session.start()
        let herdrCommand = HerdrLaunchCommand.launch(sessionName: nil)
        func herdrAttachCount() -> Int {
            transport.openedPTYs.filter { $0.command == herdrCommand }.count
        }
        let attachesBeforeLoss = herdrAttachCount()

        model.setRecoveryContext(selectedTabID: second.id, isForeground: true)
        transport.openedPTYs.last?.close()
        try await waitUntil { session.status != .live }
        #expect(session.status == .idle)
        try await Task.sleep(for: .milliseconds(80))

        #expect(herdrAttachCount() == attachesBeforeLoss)

        model.setRecoveryContext(selectedTabID: first.id, isForeground: true)
        await session.ensureLive()

        #expect(session.status == .live)
        #expect(herdrAttachCount() == attachesBeforeLoss + 1)
    }

    @Test func inactiveSceneDisablesRecoveryForEveryExistingSession() throws {
        let (model, _, _, host) = try makeModel()
        let selected = HostTab(hostID: host.id, sessionName: nil)
        let other = HostTab(hostID: host.id, sessionName: "second")
        let selectedSession = model.session(for: selected)
        let otherSession = model.session(for: other)
        model.setRecoveryContext(selectedTabID: selected.id, isForeground: true)
        #expect(selectedSession.automaticRecoveryEnabled)

        model.setRecoveryContext(selectedTabID: selected.id, isForeground: false)

        #expect(!selectedSession.automaticRecoveryEnabled)
        #expect(!otherSession.automaticRecoveryEnabled)
    }

    @Test func lazilyCreatedSelectedSessionInheritsRecoveryContext() throws {
        let (model, _, _, host) = try makeModel()
        let selected = HostTab(hostID: host.id, sessionName: nil)
        model.setRecoveryContext(selectedTabID: selected.id, isForeground: true)

        let session = model.session(for: selected)

        #expect(session.automaticRecoveryEnabled)
    }

    @Test func changingRecoveryContextDoesNotCreateStoredTabSessions() throws {
        let (model, _, tabStore, host) = try makeModel()
        let selected = tabStore.open(hostID: host.id, sessionName: nil)
        _ = tabStore.open(hostID: host.id, sessionName: "second")

        model.setRecoveryContext(selectedTabID: selected.id, isForeground: true)

        #expect(model.sessions.isEmpty)
    }

    @Test func closingATabTearsDownItsSession() async throws {
        let (model, _, _, host) = try makeModel()
        let tab = HostTab(hostID: host.id, sessionName: nil)
        _ = model.session(for: tab)

        await model.closeSession(tabID: tab.id)

        #expect(model.sessions[tab.id] == nil)
    }

    @Test func aTabWhoseHostWasDeletedFailsInsteadOfCrashing() async throws {
        let (model, hosts, _, host) = try makeModel()
        let tab = HostTab(hostID: host.id, sessionName: nil)
        hosts.remove(host)

        let session = model.session(for: tab)
        await session.start()

        guard case .failed = session.status else {
            Issue.record("Expected .failed for a deleted host, got \(session.status)")
            return
        }
    }

    @Test func retiringDropsOnlySessionsWhoseTabIsGone() async throws {
        let (model, _, tabStore, host) = try makeModel()
        let a = tabStore.open(hostID: host.id, sessionName: nil)
        let b = tabStore.open(hostID: host.id, sessionName: "second")
        _ = model.session(for: a)
        let survivor = model.session(for: b)

        tabStore.close(a.id)
        await model.retireSessions()

        #expect(model.sessions[a.id] == nil)
        #expect(model.sessions[b.id] === survivor)
    }

    /// Dropping the dictionary entry is not enough on its own: the SSH channel and
    /// the emulator behind it have to be torn down too, or a closed tab leaks a
    /// live PTY and a display link for the life of the process.
    @Test func retiringClosesTheRemotePTYAndUnbindsTheTerminal() async throws {
        let transport = FakeSSHTransport()
        let (model, _, tabStore, host) = try makeModel(sharedTransport: transport)
        let tab = tabStore.open(hostID: host.id, sessionName: nil)
        let session = model.session(for: tab)
        await session.start()
        #expect(session.status == .live)
        #expect(transport.openedPTYs.last?.closed == false)

        tabStore.close(tab.id)
        await model.retireSessions()

        #expect(model.sessions[tab.id] == nil)
        #expect(transport.openedPTYs.last?.closed == true)
        #expect(session.terminal.pty == nil)
        #expect(session.status == .idle)
    }

    /// Nothing else guards the wiring: `HostTabStore.close()` has no path back into
    /// `HostTabsModel`, so if `RootView` stops observing the tab set the retirement
    /// simply never runs and the leak returns silently.
    @Test func rootViewRetiresSessionsWhenTheOpenTabSetChanges() throws {
        let source = try sourceFile("UI/RootView.swift")
        #expect(source.contains(".onChange(of: tabStore.tabs.map(\\.id))"))
        #expect(source.contains("await tabs.retireSessions()"))
    }

    @Test func rootViewUpdatesRecoveryContextForInitialSelectionAndSceneChanges() throws {
        let source = try sourceFile("UI/RootView.swift")

        #expect(source.contains("private func updateRecoveryContext()"))
        #expect(source.components(separatedBy: "updateRecoveryContext()").count - 1 == 4)
        #expect(source.contains("selectedTabID: tabStore.selectedTabID"))
        #expect(source.contains("isForeground: scenePhase == .active"))
        #expect(source.contains("Task { await tabs.session(for: tab).ensureLive() }"))
    }

    @Test func retryButtonUsesExplicitRetryInsteadOfLifecycleReconciliation() throws {
        let source = try sourceFile("UI/RootView.swift")
        #expect(source.contains("onRetry: { Task { await session.retry() } }"))
        #expect(!source.contains("onRetry: { Task { await session.ensureLive() } }"))
    }

    /// `HostListView`, `HostEditView`, `InstallKeySheet` and `WorkdirPickerSheet`
    /// each read `@Environment(ToastCenter.self)` non-optionally, which traps at
    /// runtime when it is missing. `RootView` is the app's only injection site, and
    /// the settings sheet is the only route to those four views.
    @Test func rootViewInjectsTheToastCenterIntoTheSettingsSheet() throws {
        let source = try sourceFile("UI/RootView.swift")
        #expect(source.contains(".environment(toastCenter)"))
        #expect(source.contains(".toastHost(toastCenter)"))
    }

    @Test func hostSetupWiresSessionRestoreToTheSharedConnection() throws {
        let source = try sourceFile("UI/Hosts/HostSetupHelpSheet.swift")

        #expect(source.components(separatedBy: "HostConnection(").count - 1 == 1)
        #expect(source.contains("_integrationManager = State("))
        #expect(source.contains("HerdrIntegrationManager(connection: connection)"))
        #expect(source.contains("if let integrationManager, isHerdrPresent"))
        #expect(source.contains("setupSectionLabel(\"4 · Session restore\")"))
        #expect(source.contains("await manager.probe()"))
        #expect(source.contains("await manager.installOrRepairAll()"))
        #expect(source.contains("let hasActionableAgents = manager.agents.contains"))
        #expect(source.contains("enabled: !isInstalling"))
        #expect(
            source.contains(
                "@State private var restoreOperations = HostSetupRestoreOperationCoordinator()"))
        #expect(source.components(separatedBy: "restoreOperations.start").count - 1 == 3)
        #expect(!source.contains("Task { await manager.installOrRepairAll() }"))
        #expect(source.components(separatedBy: "sessionRestoreProbeButton(").count - 1 == 2)

        let cancellation = try #require(
            source.range(of: "await restoreOperations.cancelAndWait()"))
        let connectionClose = try #require(source.range(of: "await lifecycle.close()"))
        #expect(cancellation.lowerBound < connectionClose.lowerBound)

        #expect(source.contains("host-setup-session-restore-card"))
        #expect(source.contains("host-setup-session-restore-probe"))
        #expect(source.contains("host-setup-session-restore-install"))
        #expect(source.contains("host-setup-session-restore-agent-"))

        #expect(source.contains("restores saved layouts after a host restart"))
        #expect(source.contains("cannot restore arbitrary processes"))
        #expect(source.contains("agent conversations can resume"))
        #expect(source.contains("Pane history is not automatically captured or retained"))
    }

    @Test func restoreOperationCoordinatorRejectsConcurrentManualWork() async {
        let coordinator = HostSetupRestoreOperationCoordinator()
        let events = RestoreOperationEvents()

        let acceptedProbe = coordinator.start {
            events.record("probe-started")
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {}
            events.record("probe-finished")
        }
        await events.waitForCount(1)
        let acceptedInstall = coordinator.start {
            events.record("install-started")
        }

        #expect(acceptedProbe)
        #expect(!acceptedInstall)
        await coordinator.cancelAndWait()
        #expect(events.values == ["probe-started", "probe-finished"])
        #expect(!coordinator.hasActiveOperation)
    }

    @Test func cancellingRestoreWorkDrainsBeforeTeardownAndAllowsRestart() async {
        let coordinator = HostSetupRestoreOperationCoordinator()
        let events = RestoreOperationEvents()
        #expect(
            coordinator.start {
                events.record("operation-started")
                do {
                    try await Task.sleep(for: .seconds(60))
                } catch {}
                events.record("operation-finished")
            })
        await events.waitForCount(1)

        await coordinator.cancelAndWait()
        events.record("connection-closed")

        #expect(
            coordinator.start {
                events.record("new-probe-started")
            })
        await events.waitForCount(4)
        await coordinator.cancelAndWait()

        #expect(
            events.values == [
                "operation-started",
                "operation-finished",
                "connection-closed",
                "new-probe-started",
            ])
        #expect(!coordinator.hasActiveOperation)
    }

    @Test func cancelledCallerCannotStartRestoreWorkAfterTeardown() async {
        let coordinator = HostSetupRestoreOperationCoordinator()
        let events = RestoreOperationEvents()
        let gate = RestoreOperationStartGate()
        let lateStart = Task { @MainActor in
            await gate.wait()
            return coordinator.start {
                events.record("late-probe-started")
            }
        }
        await gate.waitUntilBlocked()

        lateStart.cancel()
        await gate.release()
        let accepted = await lateStart.value
        await Task.yield()

        #expect(!accepted)
        #expect(events.values.isEmpty)
        #expect(!coordinator.hasActiveOperation)
    }

    /// Replaces a test that handed the SAME object references to two `RootView`
    /// values and then asserted they were identical -- true by Swift reference
    /// semantics, so it could not fail. The real risk lives in the composition
    /// root: if it built a second `HostStore`/`HostTabStore` for the tabs model,
    /// `RootView` and `HostTabsModel` would read different host lists and a tab
    /// would resolve to `Host.placeholder` forever.
    @Test func theCompositionRootBuildsOneStoreAndSharesItWithTheTabsModel() throws {
        let source = try sourceFile("App/MultiSessionAIManagerApp.swift")

        // Exactly one of each store is ever constructed.
        #expect(source.components(separatedBy: "HostStore()").count - 1 == 1)
        #expect(source.components(separatedBy: "HostTabStore()").count - 1 == 1)

        // ...and those instances -- not fresh ones -- back both the @State
        // properties and the tabs model.
        #expect(source.contains("_hostStore = State(initialValue: hosts)"))
        #expect(source.contains("_tabStore = State(initialValue: openTabs)"))
        #expect(source.contains("hostStore: hosts"))
        #expect(source.contains("tabStore: openTabs"))

        // ...which are then what RootView is handed.
        #expect(source.contains("hostStore: hostStore"))
        #expect(source.contains("tabStore: tabStore"))
        #expect(source.contains("tabs: tabs"))
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return try String(
            contentsOf: packageRoot.appendingPathComponent(relativePath),
            encoding: .utf8
        )
    }
}
