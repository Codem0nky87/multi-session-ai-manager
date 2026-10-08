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

        let software = app.buttons["host.ai-agents.manage"]
        reveal(software, in: app)
        XCTAssertTrue(software.isEnabled, "AI agent management must be reachable from the host editor")
        software.tap()
        XCTAssertTrue(app.navigationBars["AI Agents on \(hostName)"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(app.buttons["Retry"].waitForExistence(timeout: 15), app.debugDescription)
        XCTAssertFalse(app.buttons["host.software.install.codex"].exists, "An unavailable host cannot offer installation")
        app.navigationBars["AI Agents on \(hostName)"].buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Edit Host"].waitForExistence(timeout: 10))

        let manage = app.buttons["host.plugins.manage"]
        reveal(manage, in: app)
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

        app.navigationBars["Edit Host"].buttons["Cancel"].tap()
        app.navigationBars["Hosts"].buttons["Done"].tap()
        app.navigationBars["MSAM Settings"].buttons["Done"].tap()
        app.buttons["host.tab.add"].tap()
        app.buttons.containing(.staticText, identifier: hostName).firstMatch.tap()
        let functionKeys = app.buttons["msam.function-keys"]
        XCTAssertTrue(functionKeys.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(functionKeys.isEnabled, "function keys require a connected session")
        XCTAssertGreaterThan(functionKeys.frame.minX, app.buttons["msam.send.file"].frame.minX)
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@", "host.tab.", "host.tab.add"))
            .firstMatch.press(forDuration: 1)
        app.buttons["Close"].tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let editor = app.scrollViews["host.editor.form"]
        for _ in 0..<16 {
            let top = app.navigationBars["Edit Host"].frame.maxY + 12
            let bottom = app.buttons["Save host"].frame.minY - 12
            if element.isHittable && element.frame.minY >= top && element.frame.maxY <= bottom { return }
            // A row behind the translucent navigation bar can still report
            // isHittable. Scroll it back into the visible content before tapping.
            if element.frame.midY > (top + bottom) / 2 { editor.swipeUp(velocity: .slow) }
            else { editor.swipeDown(velocity: .slow) }
        }
        XCTFail("Host control is not visible: \(element)\n\(app.debugDescription)")
    }
}
