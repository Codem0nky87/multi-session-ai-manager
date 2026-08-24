import XCTest

/// Exercises the host-tabbed Herdr shell itself: the tab strip, the settings
/// cog, and the host picker behind `+`. A clean install has no configured
/// hosts and no tabs, so these tests only assert on chrome that is present in
/// the empty state -- they do not attempt to reach a live terminal session
/// (that needs a configured host and is out of scope for a simulator run).
@MainActor
final class HostTabsUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() async throws {
        await MainActor.run {
            continueAfterFailure = false
            app = XCUIApplication()
        }
    }

    func testLaunchesIntoTheHostShellWithNoLegacyChrome() {
        app.launch()

        // HostTabStrip is a SwiftUI ScrollView, so it surfaces as a `scrollView`
        // in the accessibility tree, not `otherElement` -- confirmed by capturing
        // the live hierarchy rather than assuming the element type.
        XCTAssertTrue(
            app.scrollViews["host.tabstrip"].waitForExistence(timeout: 8),
            "host tab strip did not appear at launch\n\(app.debugDescription)"
        )
        XCTAssertTrue(app.buttons["host.tab.add"].exists, "the add-tab button is missing from the strip")
        XCTAssertTrue(app.buttons["msam.settings"].exists, "the MSAM settings cog is missing")
        // Type-agnostic: the deleted shell's identifier must not reappear on any
        // element kind, not just the one its old container happened to use.
        XCTAssertFalse(
            app.descendants(matching: .any)["herdr.tabstrip"].exists,
            "legacy Herdr shell tab strip must be gone"
        )
    }

    func testAddOpensTheHostPicker() {
        app.launch()

        let addButton = app.buttons["host.tab.add"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 8), "add-tab button never appeared")
        addButton.tap()

        XCTAssertTrue(
            app.navigationBars["Open Host"].waitForExistence(timeout: 5),
            "tapping + did not present the Open Host picker\n\(app.debugDescription)"
        )
        XCTAssertTrue(
            app.textFields["host.picker.session"].exists,
            "picker's session-name field is missing"
        )
    }
}
