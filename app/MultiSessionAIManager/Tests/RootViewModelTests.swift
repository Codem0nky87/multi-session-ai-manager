import Foundation
import Testing
@testable import MultiSessionAIManager

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

    /// `HostListView`, `HostEditView`, `InstallKeySheet` and `WorkdirPickerSheet`
    /// each read `@Environment(ToastCenter.self)` non-optionally, which traps at
    /// runtime when it is missing. `RootView` is the app's only injection site, and
    /// the settings sheet is the only route to those four views.
    @Test func rootViewInjectsTheToastCenterIntoTheSettingsSheet() throws {
        let source = try sourceFile("UI/RootView.swift")
        #expect(source.contains(".environment(toastCenter)"))
        #expect(source.contains(".toastHost(toastCenter)"))
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
