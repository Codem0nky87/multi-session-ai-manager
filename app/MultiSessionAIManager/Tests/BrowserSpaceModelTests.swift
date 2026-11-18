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

    @Test func aSpacesAddressOutlivesTheApp() {
        let store = defaults()
        BrowserSpaceModel(hostID: host, defaults: store).remember(address: "http://grafana.internal:3000/d/1", for: "7f3a2c")

        let relaunched = BrowserSpaceModel(hostID: host, defaults: store)
        #expect(relaunched.savedAddress(for: "7f3a2c") == "http://grafana.internal:3000/d/1")
        #expect(relaunched.savedAddress(for: "bbbbbb") == nil)
        #expect(BrowserSpaceModel(hostID: UUID(), defaults: store).savedAddress(for: "7f3a2c") == nil,
                "Another host's spaces are its own")
    }

    @Test func onlyTheNewestAddressesAreKept() {
        let store = defaults()
        let model = BrowserSpaceModel(hostID: host, defaults: store)
        for index in 0..<(BrowserSpaceModel.savedLimit + 3) {
            model.remember(address: "http://site\(index)/", for: String(format: "%06x", index))
        }
        model.remember(address: "http://site3/again", for: "000003")   // used again: newest

        let relaunched = BrowserSpaceModel(hostID: host, defaults: store)
        #expect(relaunched.savedAddress(for: "000000") == nil)
        #expect(relaunched.savedAddress(for: "000002") == nil)
        #expect(relaunched.savedAddress(for: "000003") == "http://site3/again")
        #expect(relaunched.savedAddress(for: "000004") != nil)
        #expect(relaunched.savedAddress(for: "00000e") == "http://site14/")
    }
}
