import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite @MainActor struct BrowserSpaceModelTests {
    private let host = UUID()

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "browser-space-model-\(UUID().uuidString)")!
    }

    private func region(_ id: String = "7f3a2c", column: Int = 26, columns: Int = 113) -> BrowserSpaceRegion {
        BrowserSpaceRegion(id: id, column: column, row: 1, columns: columns, rows: 39)
    }

    /// Whether `condition` came true within two seconds. Never hangs.
    private func soon(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func aPaneThatAppearsIsShownAtOnce() {
        let model = BrowserSpaceModel(hostID: host, defaults: defaults())
        model.show([region()])
        #expect(model.regions == [region()])
    }

    @Test func aPaneThatMovesIsFollowedAtOnce() {
        let model = BrowserSpaceModel(hostID: host, defaults: defaults())
        model.show([region()])
        model.show([region(column: 0, columns: 139)])
        #expect(model.regions == [region(column: 0, columns: 139)])
    }

    @Test func aPaneThatDisappearsIsDroppedAfterAMomentNotAtOnce() async {
        let model = BrowserSpaceModel(hostID: host, defaults: defaults(), grace: .milliseconds(60))
        model.show([region()])
        model.show([])
        #expect(model.regions == [region()], "A repaint must not flicker the page")
        #expect(await soon { model.regions.isEmpty })
    }

    @Test func aPaneGoneForLessThanTheMomentIsNeverDropped() async throws {
        // A Herdr repaint: the placeholder is not there for a frame or two.
        let model = BrowserSpaceModel(hostID: host, defaults: defaults(), grace: .milliseconds(400))
        model.show([region()])
        model.show([])
        try await Task.sleep(for: .milliseconds(60))
        #expect(model.regions == [region()], "Still drawn while the moment lasts")
        model.show([region()])
        try await Task.sleep(for: .milliseconds(600))
        #expect(model.regions == [region()], "And not dropped later for having been gone")
    }

    // MARK: The terminal changes size

    @Test func aPaneStaysWhileTheHostRedrawsATerminalThatChangedSize() async throws {
        // The keyboard came up: the terminal is shorter, and until the host has
        // drawn the pane at its new size the placeholder on screen is cut off.
        let model = BrowserSpaceModel(hostID: host, defaults: defaults(), grace: .milliseconds(40), resizeHold: .seconds(5))
        model.show([region()])
        model.terminalResized(whileItHasTheKeyboard: false)
        model.show([])
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.regions == [region()], "Dropping it here takes the keyboard away from the page that raised it")
        model.show([region(columns: 100)])
        #expect(model.regions == [region(columns: 100)])
    }

    @Test func aPaneAlreadyMissingWhenTheTerminalChangesSizeStaysToo() async throws {
        // The two reports arrive in either order.
        let model = BrowserSpaceModel(hostID: host, defaults: defaults(), grace: .milliseconds(40), resizeHold: .seconds(5))
        model.show([region()])
        model.show([])
        model.terminalResized(whileItHasTheKeyboard: false)
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.regions == [region()])
    }

    @Test func aPaneThatDoesNotComeBackAfterAChangeOfSizeIsDropped() async {
        let model = BrowserSpaceModel(hostID: host, defaults: defaults(), grace: .milliseconds(20), resizeHold: .milliseconds(150))
        model.show([region()])
        model.terminalResized(whileItHasTheKeyboard: false)
        model.show([])
        #expect(await soon { model.regions.isEmpty })
    }

    @Test func aPaneIsNotKeptForAChangeOfSizeTheTerminalsOwnKeyboardMade() async {
        // A tap on Herdr gave the terminal the keyboard: the user is changing
        // what Herdr shows, and the browser must be out of the way at once.
        let model = BrowserSpaceModel(hostID: host, defaults: defaults(), grace: .milliseconds(30), resizeHold: .seconds(30))
        model.show([region()])
        model.terminalResized(whileItHasTheKeyboard: true)
        model.show([])
        #expect(await soon { model.regions.isEmpty })
    }

    @Test func onceThePaneIsBackTheWaitForItIsOver() async {
        let model = BrowserSpaceModel(hostID: host, defaults: defaults(), grace: .milliseconds(30), resizeHold: .seconds(30))
        model.show([region()])
        model.terminalResized(whileItHasTheKeyboard: false)
        model.show([])
        model.show([region()])          // the host has drawn it at its new size
        model.show([])                  // and now a Herdr menu covers it
        #expect(await soon { model.regions.isEmpty }, "A menu must not wait for a change of size that is over")
    }

    @Test func onlyThePaneThatLeftIsDropped() async {
        let model = BrowserSpaceModel(hostID: host, defaults: defaults(), grace: .milliseconds(30))
        model.show([region("aaaaaa"), region("bbbbbb", column: 80, columns: 59)])
        model.show([region("bbbbbb", column: 80, columns: 59)])
        #expect(await soon { model.regions.map(\.id) == ["bbbbbb"] })
    }

    @Test func aSpacesPageIsTheSameOneWhenItComesBack() async {
        let model = BrowserSpaceModel(hostID: host, defaults: defaults(), grace: .milliseconds(10))
        let page = model.page(for: "7f3a2c")
        model.show([region()])
        model.show([])
        _ = await soon { model.regions.isEmpty }
        model.show([region()])
        #expect(model.page(for: "7f3a2c") === page)
        #expect(model.page(for: "bbbbbb") !== page)
    }

    @Test func aSpacesTabsOutliveTheApp() {
        let store = defaults()
        let tabs = BrowserSpaceModel.SavedTabs(addresses: ["http://grafana.internal:3000/d/1", "http://wiki.internal/"], selected: 1)
        BrowserSpaceModel(hostID: host, defaults: store).remember(tabs, for: "7f3a2c")

        let relaunched = BrowserSpaceModel(hostID: host, defaults: store)
        #expect(relaunched.savedTabs(for: "7f3a2c") == tabs)
        #expect(relaunched.savedTabs(for: "bbbbbb") == nil)
        #expect(BrowserSpaceModel(hostID: UUID(), defaults: store).savedTabs(for: "7f3a2c") == nil,
                "Another host's spaces are its own")

        let restored = relaunched.tabs(for: "7f3a2c")
        #expect(restored.tabs.map(\.address) == tabs.addresses)
        #expect(restored.selected === restored.tabs[1])
    }

    @Test func aSpaceRememberedBeforeThereWereTabsOpensAsOneTab() {
        // What the build before tabs wrote: the space and its one address.
        let store = defaults()
        store.set([["7f3a2c", "http://grafana.internal:3000/"]], forKey: "msam.browser-spaces.\(host.uuidString.lowercased())")
        let model = BrowserSpaceModel(hostID: host, defaults: store)
        #expect(model.savedTabs(for: "7f3a2c") == .init(addresses: ["http://grafana.internal:3000/"], selected: 0))
        #expect(model.tabs(for: "7f3a2c").tabs.map(\.address) == ["http://grafana.internal:3000/"])
    }

    @Test func aChangeOfTabsIsRememberedWithoutBeingAskedFor() throws {
        let store = defaults()
        let model = BrowserSpaceModel(hostID: host, defaults: store)
        model.remember(.init(addresses: ["http://a/", "http://b/"], selected: 0), for: "7f3a2c")
        let tabs = model.tabs(for: "7f3a2c")
        tabs.select(tabs.tabs[1].id)
        #expect(BrowserSpaceModel(hostID: host, defaults: store).savedTabs(for: "7f3a2c")?.selected == 1)
        tabs.close(tabs.tabs[0].id)
        #expect(BrowserSpaceModel(hostID: host, defaults: store).savedTabs(for: "7f3a2c")
                == .init(addresses: ["http://b/"], selected: 0))
    }

    @Test func aSpaceWithNothingOpenIsNotRemembered() {
        let store = defaults()
        let model = BrowserSpaceModel(hostID: host, defaults: store)
        model.remember(.init(addresses: ["http://a/"], selected: 0), for: "7f3a2c")
        model.remember(.init(addresses: ["", ""], selected: 1), for: "7f3a2c")
        #expect(BrowserSpaceModel(hostID: host, defaults: store).savedTabs(for: "7f3a2c") == nil)
    }

    @Test func aSpacesTabsAreTheSameOnesEveryTime() {
        let model = BrowserSpaceModel(hostID: host, defaults: defaults())
        #expect(model.tabs(for: "7f3a2c") === model.tabs(for: "7f3a2c"))
        #expect(model.tabs(for: "7f3a2c") !== model.tabs(for: "bbbbbb"))
        #expect(model.page(for: "7f3a2c") === model.tabs(for: "7f3a2c").selected.page)
    }

    @Test func onlyTheNewestSpacesAreKept() {
        let store = defaults()
        let model = BrowserSpaceModel(hostID: host, defaults: store)
        for index in 0..<(BrowserSpaceModel.savedLimit + 3) {
            model.remember(.init(addresses: ["http://site\(index)/"], selected: 0), for: String(format: "%06x", index))
        }
        model.remember(.init(addresses: ["http://site3/again"], selected: 0), for: "000003")   // used again: newest

        let relaunched = BrowserSpaceModel(hostID: host, defaults: store)
        #expect(relaunched.savedTabs(for: "000000") == nil)
        #expect(relaunched.savedTabs(for: "000002") == nil)
        #expect(relaunched.savedTabs(for: "000003")?.addresses == ["http://site3/again"])
        #expect(relaunched.savedTabs(for: "000004") != nil)
        #expect(relaunched.savedTabs(for: "00000e")?.addresses == ["http://site14/"])
    }
}
