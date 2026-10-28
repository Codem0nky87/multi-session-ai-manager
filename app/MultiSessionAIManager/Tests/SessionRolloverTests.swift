import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite @MainActor struct SessionRolloverTests {
    @Test func adjacentTabInsertionPlacesNewTabDirectlyAfterTarget() throws {
        let store = HostTabStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let host1 = UUID()
        let host2 = UUID()

        let tab1 = store.open(hostID: host1, sessionName: "tab1")
        let tab2 = store.open(hostID: host1, sessionName: "tab2")
        let tab3 = store.open(hostID: host2, sessionName: "tab3")

        #expect(store.tabs.map(\.id) == [tab1.id, tab2.id, tab3.id])

        // Insert new tab directly after tab1
        let rolled = store.open(hostID: host1, sessionName: "rolled-over", insertAfter: tab1.id)
        #expect(store.tabs.map(\.id) == [tab1.id, rolled.id, tab2.id, tab3.id])
        #expect(store.selectedTabID == rolled.id)

        // Close old tab1
        store.close(tab1.id)
        #expect(store.tabs.map(\.id) == [rolled.id, tab2.id, tab3.id])
    }
}
