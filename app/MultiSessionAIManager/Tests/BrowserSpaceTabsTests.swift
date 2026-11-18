import Foundation
import Testing
@testable import MultiSessionAIManager

/// The pages of one browser space: "+" opens another, one of them is shown.
@Suite @MainActor struct BrowserSpaceTabsTests {
    @Test func aBrowserStartsWithOneEmptyTab() {
        let tabs = BrowserSpaceTabs()
        #expect(tabs.tabs.count == 1)
        #expect(tabs.selected.address.isEmpty)
        #expect(tabs.canAdd)
    }

    @Test func plusOpensAnotherPageAndShowsIt() throws {
        let tabs = BrowserSpaceTabs()
        let first = tabs.selected
        let second = try #require(tabs.add())
        #expect(tabs.tabs.map(\.id) == [first.id, second.id], "A new tab goes at the end")
        #expect(tabs.selected === second)
        #expect(second.page !== first.page, "Each tab is a browser of its own")
        #expect(second.address.isEmpty)
    }

    @Test func goingBackToATabShowsThePageItHad() throws {
        let tabs = BrowserSpaceTabs()
        let first = tabs.selected
        let firstPage = first.page
        _ = try #require(tabs.add())
        tabs.select(first.id)
        #expect(tabs.selected === first)
        #expect(tabs.selected.page === firstPage)
    }

    @Test func closingTheTabShownShowsTheOneThatTakesItsPlace() throws {
        let tabs = BrowserSpaceTabs()
        let first = tabs.selected
        let second = try #require(tabs.add())
        let third = try #require(tabs.add())
        tabs.select(second.id)
        tabs.close(second.id)
        #expect(tabs.tabs.map(\.id) == [first.id, third.id])
        #expect(tabs.selected === third)
        tabs.close(third.id)
        #expect(tabs.selected === first, "With nothing after it, the one before")
    }

    @Test func closingAnotherTabKeepsTheOneShown() throws {
        let tabs = BrowserSpaceTabs()
        let first = tabs.selected
        let second = try #require(tabs.add())
        tabs.close(first.id)
        #expect(tabs.tabs.map(\.id) == [second.id])
        #expect(tabs.selected === second)
    }

    @Test func closingTheOnlyTabLeavesAnEmptyOne() {
        let tabs = BrowserSpaceTabs(addresses: ["http://grafana.internal:3000/"])
        let only = tabs.selected
        tabs.close(only.id)
        #expect(tabs.tabs.count == 1, "A browser always has a page")
        #expect(tabs.selected !== only)
        #expect(tabs.selected.address.isEmpty)
    }

    @Test func thereIsALimitToTheTabsOfOneSpace() {
        let tabs = BrowserSpaceTabs()
        for _ in 1..<BrowserSpaceTabs.limit { #expect(tabs.add() != nil) }
        #expect(tabs.tabs.count == BrowserSpaceTabs.limit)
        #expect(!tabs.canAdd)
        #expect(tabs.add() == nil)
        #expect(tabs.tabs.count == BrowserSpaceTabs.limit)
    }

    @Test func tabsComeBackWithTheAddressesTheyHad() {
        let tabs = BrowserSpaceTabs(addresses: ["http://grafana.internal:3000/", "", "http://wiki.internal/"], selected: 2)
        #expect(tabs.tabs.map(\.address) == ["http://grafana.internal:3000/", "", "http://wiki.internal/"])
        #expect(tabs.selected === tabs.tabs[2])
    }

    @Test func aSelectionThatIsNotThereFallsBackToTheFirstTab() {
        let tabs = BrowserSpaceTabs(addresses: ["http://a/", "http://b/"], selected: 9)
        #expect(tabs.selected === tabs.tabs[0])
        #expect(BrowserSpaceTabs(addresses: Array(repeating: "http://a/", count: 40)).tabs.count == BrowserSpaceTabs.limit)
    }

    @Test func everyChangeIsReportedSoItCanBeRemembered() throws {
        let tabs = BrowserSpaceTabs()
        var changes = 0
        tabs.onChange = { changes += 1 }
        let first = tabs.selected
        let second = try #require(tabs.add())
        #expect(changes == 1)
        tabs.select(first.id)
        #expect(changes == 2)
        tabs.select(first.id)
        #expect(changes == 2, "Nothing changed")
        tabs.close(second.id)
        #expect(changes == 3)
    }

    @Test func aTabIsNamedAfterItsPage() {
        #expect(BrowserSpaceTab.label(title: "Grafana", address: "http://grafana.internal:3000/d/1") == "Grafana")
        #expect(BrowserSpaceTab.label(title: "  ", address: "http://wiki.internal:8080/start") == "wiki.internal")
        #expect(BrowserSpaceTab.label(title: "", address: "") == "New Tab")
        #expect(BrowserSpaceTab.label(title: "", address: "not an address") == "New Tab")
    }
}
