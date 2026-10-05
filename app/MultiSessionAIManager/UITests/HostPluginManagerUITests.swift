import XCTest

@MainActor
final class HostPluginManagerUITests: XCTestCase {
    /// Run with a simulator-only saved host named by MSAM_PLUGIN_TEST_HOST.
    /// Use loopback port 1 and a missing test key to exercise connection failure
    /// without contacting or changing a real host.
    func testHostEditorOffersPluginsAndConnectionFailureCanBeDismissed() throws {
        guard let hostName = ProcessInfo.processInfo.environment["MSAM_PLUGIN_TEST_HOST"] else {
            throw XCTSkip("Requires a saved simulator plugin-manager test host")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        if !app.navigationBars["Hosts"].exists {
            let settings = app.buttons["msam.settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 15))
            settings.tap()
            app.buttons["settings.hosts.manage"].tap()
        }
        let host = app.staticTexts[hostName]
        XCTAssertTrue(host.waitForExistence(timeout: 10))
        host.tap()
        XCTAssertTrue(app.navigationBars["Edit Host"].waitForExistence(timeout: 10))

        let manage = app.buttons["host.plugins.manage"]
        let editor = app.scrollViews["host.editor.form"]
        for _ in 0..<8 {
            if manage.isHittable && !app.buttons["Save host"].frame.intersects(manage.frame) { break }
            editor.swipeUp()
        }
        XCTAssertTrue(manage.exists, "Plugin management must be reachable from the host editor")
        XCTAssertTrue(manage.isEnabled)
        for _ in 0..<2 {
            manage.tap()
            XCTAssertTrue(app.navigationBars["Plugins on \(hostName)"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.staticTexts["SSH connection failed"].waitForExistence(timeout: 15))
            XCTAssertTrue(app.buttons["host.plugins.retry"].exists)
            app.buttons["host.plugins.close"].tap()
            XCTAssertTrue(app.navigationBars["Edit Host"].waitForExistence(timeout: 10))
        }
    }
}
