import XCTest

/// Explicit opt-in: drives the REAL app against the REAL test host and
/// attaches full-screen screenshots for the App Store listing. Run once on
/// the iPad simulator and once on the iPhone simulator; extract the
/// attachments from the .xcresult with
/// `xcrun xcresulttool export attachments --path <xcresult> --output-path <dir>`.
@MainActor
final class AppStoreScreenshotsLiveUITests: XCTestCase {
    private var app = XCUIApplication()
    private let hostName = "Forge"

    struct Fixture: Decodable {
        let address: String
        let username: String
        let passwordFile: String
    }

    private var fixture: Fixture? {
        guard ProcessInfo.processInfo.environment["MSAM_SHOTS"] == "1",
              let path = ProcessInfo.processInfo.environment["MSAM_SHOT_FIXTURE"] else { return nil }
        return try? JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    func testCaptureAppStoreScreenshots() throws {
        guard let fixture else {
            throw XCTSkip("Requires an explicitly authorized test host")
        }
        continueAfterFailure = false
        let password = try String(contentsOfFile: fixture.passwordFile, encoding: .utf8)
            .trimmingCharacters(in: .newlines)

        app.launch()
        dismissSystemAlerts()

        // Ensure the host exists (add + install key if this device is fresh).
        openHosts()
        if !app.staticTexts[hostName].waitForExistence(timeout: 5) {
            app.buttons["Add Host"].tap()
            for (id, value) in [("host.name", hostName),
                                ("host.address", fixture.address),
                                ("host.username", fixture.username)] {
                let field = app.textFields[id]
                XCTAssertTrue(field.waitForExistence(timeout: 10), app.debugDescription)
                field.tap(); field.typeText(value + "\n")
            }
            let install = app.buttons["Install key on host…"]
            XCTAssertTrue(install.waitForExistence(timeout: 10), app.debugDescription)
            install.tap()
            let pw = app.secureTextFields["install.password"]
            XCTAssertTrue(pw.waitForExistence(timeout: 10), app.debugDescription)
            pw.tap(); pw.typeText(password)
            hideKeyboardIfNeeded()
            app.buttons["Install key"].firstMatch.tap()
            allowLocalNetwork()
            let done = app.scrollViews["install.form"].buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 120), app.debugDescription)
            done.tap()
            // Walk the wizard to the end: services + restore steps.
            for _ in 0..<3 {
                let next = app.buttons["Next"]
                XCTAssertTrue(next.waitForExistence(timeout: 20), app.debugDescription)
                if !next.isEnabled {
                    for label in ["Install or Check Services",
                                  "Enable or Repair Session Restore"] {
                        let step = app.buttons[label]
                        if step.waitForExistence(timeout: 5) { step.tap() }
                    }
                    let ready = XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "enabled == true"), object: next)
                    _ = XCTWaiter.wait(for: [ready], timeout: 300)
                }
                next.tap()
            }
            let finish = app.buttons["Done"]
            if finish.waitForExistence(timeout: 10) { finish.tap() }
        }

        // 1 · Hosts list
        screenshot("shot-hosts")

        // 2 · Host editor (shows metrics-adjacent controls + port forwarding)
        app.staticTexts[hostName].firstMatch.tap()
        let editor = app.scrollViews["host.editor.form"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)
        screenshot("shot-editor")

        // 3 · Port forwarding sheet
        let pf = app.buttons["host.port-forwarding.manage"]
        if pf.waitForExistence(timeout: 5) {
            pf.tap()
            let status = app.descendants(matching: .any)
                .matching(identifier: "tunnel.status").firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: 20), app.debugDescription)
            screenshot("shot-tunnels")
            app.navigationBars.buttons.firstMatch.tap()  // close sheet
        }

        // 4 · The terminal itself: back out to the session, let it connect.
        app.navigationBars.buttons.firstMatch.tap()   // leave editor
        dismissSystemAlerts()
        let picker = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'host.picker.host.'")).firstMatch
        if picker.waitForExistence(timeout: 8) { picker.tap() }
        let session = app.descendants(matching: .any)
            .matching(identifier: "host.session.status").firstMatch
        _ = session.waitForExistence(timeout: 30)
        // Give metrics a beat to populate (collector round-trip).
        let metrics = app.descendants(matching: .any)
            .matching(identifier: "metrics.disk").firstMatch
        _ = metrics.waitForExistence(timeout: 45)
        hideKeyboardIfNeeded()
        screenshot("shot-terminal")
    }

    // MARK: - Helpers (mirroring MacHostLiveUITests)

    private func openHosts() {
        if app.navigationBars["Hosts"].exists { return }
        let settings = app.buttons["msam.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20), app.debugDescription)
        settings.tap()
        let manage = app.buttons["settings.hosts.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10), app.debugDescription)
        manage.tap()
    }

    private func hideKeyboardIfNeeded() {
        let hide = app.keyboards.buttons["Hide keyboard"]
        if hide.exists { hide.tap() }
    }

    private func allowLocalNetwork() {
        dismissSystemAlerts()
    }

    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Save Password", "Don't Save", "OK"] {
            let button = springboard.alerts.buttons[label]
            if button.waitForExistence(timeout: 2) { button.tap() }
        }
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
