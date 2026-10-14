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
                // Phone keyboards can swallow the first tap; verify the text
                // landed and retry once.
                for _ in 0..<3 {
                    field.tap()
                    field.typeText(value + "\n")
                    if (field.value as? String) == value { break }
                    field.tap()
                    field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 32) + value + "\n")
                    if (field.value as? String) == value { break }
                }
            }
            let install = app.buttons["Install key on host…"]
            XCTAssertTrue(install.waitForExistence(timeout: 10), app.debugDescription)
            // The docked keyboard swallows taps on lower rows on phone width.
            hideKeyboardIfNeeded()
            let form = app.scrollViews["host.editor.form"]
            for _ in 0..<10 {
                // isHittable is true for partially-visible rows; require the
                // whole button on-screen or the synthesized tap lands in void.
                if install.exists && install.isHittable && install.frame.maxY < app.frame.maxY - 10 { break }
                if form.exists { form.swipeUp() } else { app.swipeUp() }
            }
            install.tap()
            let pw = app.secureTextFields["install.password"]
            if !pw.waitForExistence(timeout: 10) {
                install.tap()   // first tap can land mid-animation
            }
            XCTAssertTrue(pw.waitForExistence(timeout: 10), app.debugDescription)
            pw.tap(); pw.typeText(password)
            hideKeyboardIfNeeded()
            let installKey = app.buttons["Install key"].firstMatch
            let installForm = app.scrollViews["install.form"]
            for _ in 0..<10 {
                if installKey.exists && installKey.isHittable && installKey.frame.maxY < app.frame.maxY - 10 { break }
                if installForm.exists { installForm.swipeUp() } else { app.swipeUp() }
            }
            installKey.tap()
            allowLocalNetwork()
            let done = app.scrollViews["install.form"].buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 120), app.debugDescription)
            done.tap()
            // Walk the wizard as a state machine: taps can be swallowed
            // mid-animation on phone width, so re-check the step each pass
            // until the save step appears.
            let next = app.buttons["Next"]
            let saveHost = app.buttons["Save Host"]
            XCTAssertTrue(next.waitForExistence(timeout: 20), app.debugDescription)
            let services = app.buttons["Install or Check Services"]
            for _ in 0..<8 {
                if saveHost.waitForExistence(timeout: 3) && saveHost.isHittable { break }
                dismissSystemAlerts()
                let notNow = app.descendants(matching: .button)["Not Now"]
                if notNow.exists && notNow.isHittable { notNow.tap(); continue }
                if services.exists && services.isHittable && services.isEnabled {
                    services.tap()
                    let ready = XCTNSPredicateExpectation(
                        predicate: NSPredicate(format: "enabled == true"), object: next)
                    _ = XCTWaiter.wait(for: [ready], timeout: 300)
                }
                let restore = app.buttons["Enable or Repair Session Restore"]
                if restore.exists && restore.isHittable && restore.isEnabled {
                    restore.tap()
                    waitEnabled(next, timeout: 120)
                }
                let nextReady = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"),
                    object: next)
                if XCTWaiter.wait(for: [nextReady], timeout: 30) == .completed {
                    next.tap()
                }
            }
            XCTAssertTrue(saveHost.waitForExistence(timeout: 10), app.debugDescription)
            saveHost.tap()
            if app.buttons["host.setup.close"].waitForExistence(timeout: 4) {
                app.buttons["host.setup.close"].tap()
            }
        }

        // 1 · Hosts list
        screenshot("shot-hosts")

        // 2 · Host editor (shows metrics-adjacent controls + port forwarding)
        let hostRow = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'host.picker.host.'")).firstMatch
        if hostRow.waitForExistence(timeout: 10) {
            hostRow.tap()
        } else {
            app.staticTexts[hostName].firstMatch.tap()
        }
        let editor = app.scrollViews["host.editor.form"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)
        screenshot("shot-editor")

        // 3 · Port forwarding sheet
        let pf = app.buttons["host.port-forwarding.manage"]
        for _ in 0..<8 {
            if pf.exists && pf.isHittable { break }
            editor.swipeUp()
        }
        if pf.waitForExistence(timeout: 5) && pf.isHittable {
            pf.tap()
            let status = app.descendants(matching: .any)
                .matching(identifier: "tunnel.status").firstMatch
            XCTAssertTrue(status.waitForExistence(timeout: 20), app.debugDescription)
            screenshot("shot-tunnels")
            app.navigationBars["SSH Web Tunnels"].buttons["Done"].tap()
        }

        // 4 · The terminal: close the editor and the hosts sheet, then open a
        //    session through the tab strip's add button.
        app.navigationBars["Edit Host"].buttons["Cancel"].tap()
        let hostsDone = app.navigationBars["Hosts"].buttons["Done"]
        if hostsDone.waitForExistence(timeout: 5) { hostsDone.tap() }
        dismissSystemAlerts()
        // With no open tabs the strip may be absent; the empty state's
        // "Open a host" opens the same picker.
        let addTab = app.buttons["host.tab.add"]
        let openFirst = app.buttons["Open a host"]
        let picker = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'host.picker.host.'")).firstMatch
        if addTab.waitForExistence(timeout: 5) {
            addTab.tap()
        }
        if !picker.waitForExistence(timeout: 8), openFirst.waitForExistence(timeout: 3) {
            // The strip tap can be swallowed mid-animation; the empty state
            // opens the same picker.
            openFirst.tap()
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 15), app.debugDescription)
        picker.tap()
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

    private func waitEnabled(_ element: XCUIElement, timeout: TimeInterval) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), app.debugDescription)
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, app.debugDescription)
    }

    private func hideKeyboardIfNeeded() {
        guard app.keyboards.firstMatch.exists else { return }
        let hide = app.keyboards.buttons["Hide keyboard"]
        if hide.exists && hide.isHittable {
            hide.tap()
        } else {
            // iPhone keyboards keep the chrome button off-screen; tapping
            // outside the text field resigns focus and drops the keyboard.
            app.navigationBars.firstMatch.tap()
        }
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
    }

    private func allowLocalNetwork() {
        dismissSystemAlerts()
    }

    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Save Password", "Don't Save", "OK", "Not Now", "Save"] {
            let button = springboard.alerts.buttons[label]
            if button.waitForExistence(timeout: 2) { button.tap() }
        }
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
