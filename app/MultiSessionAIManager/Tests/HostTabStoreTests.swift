import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite @MainActor struct HostTabStoreTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "HostTabStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func openingATabSelectsItAndAssignsAUniqueIdentity() {
        let store = HostTabStore(defaults: makeDefaults())
        let hostID = UUID()

        let first = store.open(hostID: hostID, sessionName: nil)
        let second = store.open(hostID: hostID, sessionName: "build")

        #expect(store.tabs.count == 2)
        #expect(first.id != second.id)
        #expect(store.selectedTabID == second.id)
        #expect(store.tabs[1].sessionName == "build")
    }

    @Test func tabsSurviveAcrossStoreInstancesInOrder() {
        let defaults = makeDefaults()
        let a = UUID(), b = UUID()
        let store = HostTabStore(defaults: defaults)
        store.open(hostID: a, sessionName: nil)
        store.open(hostID: b, sessionName: "two")

        let reloaded = HostTabStore(defaults: defaults)
        #expect(reloaded.tabs.map(\.hostID) == [a, b])
        #expect(reloaded.tabs.map(\.sessionName) == [nil, "two"])
    }

    @Test func closingTheSelectedTabSelectsItsNeighbour() {
        let store = HostTabStore(defaults: makeDefaults())
        let first = store.open(hostID: UUID(), sessionName: nil)
        let second = store.open(hostID: UUID(), sessionName: nil)

        store.close(second.id)

        #expect(store.tabs.map(\.id) == [first.id])
        #expect(store.selectedTabID == first.id)
    }

    /// The neighbour rule (`min(index, tabs.count - 1)`) was only ever exercised
    /// at index 1 of 2, where it degenerates to 0 and any off-by-one would pass.
    /// Closing index 0 of 2 is the case that actually distinguishes it.
    @Test func closingTheFirstOfTwoTabsSelectsTheTabThatTookItsPlace() {
        let store = HostTabStore(defaults: makeDefaults())
        let first = store.open(hostID: UUID(), sessionName: "a")
        let second = store.open(hostID: UUID(), sessionName: "b")
        store.select(first.id)

        store.close(first.id)

        #expect(store.tabs.map(\.id) == [second.id])
        #expect(store.selectedTabID == second.id)
    }

    /// The user-visible half of auto-reattach: a relaunch must land on the tab
    /// the user left selected, not merely on the first one. Selecting the SECOND
    /// tab is what separates a real restore from the `tabs.first` fallback.
    @Test func theSelectedTabIsRestoredWhenItStillExists() {
        let defaults = makeDefaults()
        let store = HostTabStore(defaults: defaults)
        store.open(hostID: UUID(), sessionName: "a")
        let second = store.open(hostID: UUID(), sessionName: "b")
        store.select(second.id)

        let reloaded = HostTabStore(defaults: defaults)

        #expect(reloaded.tabs.count == 2)
        #expect(reloaded.selectedTabID == second.id)
        #expect(reloaded.selectedTabID != reloaded.tabs.first?.id)
    }

    @Test func closingTheLastTabClearsSelection() {
        let store = HostTabStore(defaults: makeDefaults())
        let only = store.open(hostID: UUID(), sessionName: nil)
        store.close(only.id)
        #expect(store.tabs.isEmpty)
        #expect(store.selectedTabID == nil)
    }

    @Test func tabsForDeletedHostsArePrunedOnRestore() {
        let defaults = makeDefaults()
        let kept = UUID(), removed = UUID()
        let store = HostTabStore(defaults: defaults)
        store.open(hostID: kept, sessionName: nil)
        store.open(hostID: removed, sessionName: nil)

        let reloaded = HostTabStore(defaults: defaults)
        reloaded.prune(existingHostIDs: [kept])

        #expect(reloaded.tabs.map(\.hostID) == [kept])
        #expect(reloaded.selectedTabID == reloaded.tabs.first?.id)
    }

    @Test func tabThemeIDRoundTripsAndDefaultsToNil() {
        let defaults = makeDefaults()
        let store = HostTabStore(defaults: defaults)
        let tab = store.open(hostID: UUID(), sessionName: "dev")
        #expect(tab.themeID == nil)

        store.setTheme("dracula", for: tab.id)
        #expect(store.tabs.first?.themeID == "dracula")

        let reloaded = HostTabStore(defaults: defaults)
        #expect(reloaded.tabs.first?.themeID == "dracula")

        store.setTheme(nil, for: tab.id)
        #expect(store.tabs.first?.themeID == nil)
        let cleared = HostTabStore(defaults: defaults)
        #expect(cleared.tabs.first?.themeID == nil)
    }

    @Test func legacyTabsWithoutThemeIDDecodeSafely() throws {
        let hostID = UUID()
        let id = UUID()
        let json = """
        [{"id":"\(id.uuidString)","hostID":"\(hostID.uuidString)","sessionName":"legacy"}]
        """.data(using: .utf8)!

        let tabs = try JSONDecoder().decode([HostTab].self, from: json)
        #expect(tabs.count == 1)
        #expect(tabs[0].id == id)
        #expect(tabs[0].hostID == hostID)
        #expect(tabs[0].sessionName == "legacy")
        #expect(tabs[0].themeID == nil)
    }
}
