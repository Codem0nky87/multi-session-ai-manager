import XCTest

/// Explicit opt-in: provisions and exercises only the supplied Windows test host.
@MainActor
final class WindowsHostLiveUITests: XCTestCase {
    private var app = XCUIApplication()
    private let hostName = "Windows Service Test"

    func testWindowsRollingAgentUpdate() throws {
        guard ProcessInfo.processInfo.environment["MSAM_WINDOWS_UPDATE_IT"] == "1" else {
            throw XCTSkip("Requires an explicitly authorized live agent update")
        }
        continueAfterFailure = false
        app.launch()
        openHosts()
        app.staticTexts[hostName].tap()
        let manage = app.buttons["host.service.manage"]
        reveal(manage); manage.tap()
        waitLabel("host.service.status", contains: "Running", timeout: 30)
        app.buttons["Manage Agents and Updates"].tap()
        XCTAssertTrue(app.staticTexts["Codex"].waitForExistence(timeout: 60), app.debugDescription)
        let available = app.buttons["host.agent-updates.update.codex"]
        let update = available.exists ? available : app.buttons["host.agent-updates.relaunch.codex"]
        XCTAssertTrue(update.exists, app.debugDescription)
        update.tap()
        let confirm = app.buttons["host.agent-updates.confirm"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 60), app.debugDescription)
        screenshot("07-windows-rolling-update-preview")
        confirm.tap()
        // Leave the app to prove the host owns the durable queue.
        XCUIDevice.shared.press(.home)
        sleep(10)
        app.activate()
        for _ in 0..<30 {
            let refresh = app.buttons["host.agent-updates.refresh"]
            waitEnabled(refresh, timeout: 60)
            refresh.tap()
            waitEnabled(refresh, timeout: 60)
            if app.staticTexts["Update complete"].exists { break }
            if app.staticTexts["Completed with failures"].exists { break }
            sleep(2)
        }
        XCTAssertTrue(app.staticTexts["Update complete"].exists, app.debugDescription)
        XCTAssertTrue(app.buttons["host.agent-updates.relaunch.codex"].exists, app.debugDescription)
        screenshot("08-windows-rolling-update-complete")
    }

    func testWindowsHostThroughRealSimulatorUI() throws {
        guard ProcessInfo.processInfo.environment["MSAM_WINDOWS_IT"] == "1",
              let path = ProcessInfo.processInfo.environment["MSAM_WINDOWS_FIXTURE"] else {
            throw XCTSkip("Requires an explicitly authorized Windows test host")
        }
        struct Fixture: Decodable { let address: String; let username: String; let passwordFile: String }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        continueAfterFailure = false
        app.launch()
        openHosts()
        if !app.staticTexts[hostName].exists {
            app.buttons["Add Host"].tap()
            for (id, value) in [("host.name", hostName), ("host.address", fixture.address), ("host.username", fixture.username)] {
                let field = app.textFields[id]
                reveal(field)
                field.tap(); field.typeText(value + "\n")
                XCTAssertEqual(field.value as? String, value, "Host field did not accept input: \(id)")
            }
            let install = app.buttons["Install key on host…"]
            reveal(install)
            XCTAssertTrue(install.isEnabled, app.debugDescription)
            install.tap()
            screenshot("00-key-install-sheet")
            let password = app.secureTextFields["install.password"]
            XCTAssertTrue(password.waitForExistence(timeout: 10), app.debugDescription)
            password.tap()
            password.typeText(try String(contentsOfFile: fixture.passwordFile, encoding: .utf8).trimmingCharacters(in: .newlines))
            let hide = app.keyboards.buttons["Hide keyboard"]
            if hide.exists { hide.tap() }
            app.buttons["Install key"].firstMatch.tap()
            allowLocalNetwork()
            let done = app.scrollViews["install.form"].buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 45), app.debugDescription)
            for _ in 0..<5 {
                if done.isHittable && app.scrollViews["install.form"].frame.contains(done.frame) { break }
                app.scrollViews["install.form"].swipeUp()
            }
            done.tap()
            XCTAssertTrue(app.buttons["Next"].waitForExistence(timeout: 10))
            app.buttons["Next"].tap()
            let services = app.buttons["Install or Check Services"]
            XCTAssertTrue(services.waitForExistence(timeout: 45), app.debugDescription)
            services.tap()
            waitEnabled(app.buttons["Next"], timeout: 180)
            screenshot("01-windows-onboarding-service-ready")
            app.buttons["Next"].tap()
            waitEnabled(app.buttons["Next"], timeout: 45)
            let restore = app.buttons["Enable or Repair Session Restore"]
            if restore.exists && restore.isEnabled {
                restore.tap(); waitEnabled(app.buttons["Next"], timeout: 90)
            }
            app.buttons["Next"].tap()
            app.buttons["Save Host"].tap()
            if app.buttons["host.setup.close"].waitForExistence(timeout: 4) {
                app.buttons["host.setup.close"].tap()
            }
        }
        XCTAssertTrue(app.staticTexts[hostName].waitForExistence(timeout: 10), app.debugDescription)
        app.staticTexts[hostName].tap()
        let manage = app.buttons["host.service.manage"]
        reveal(manage); manage.tap()
        waitLabel("host.service.status", contains: "Running", timeout: 30)
        waitLabel("host.service.metrics", contains: "Collecting", timeout: 10)
        screenshot("02-windows-service-running")
        app.buttons["host.service.stop"].tap()
        XCTAssertTrue(app.buttons["Start Service"].waitForExistence(timeout: 60), app.debugDescription)
        app.buttons["Start Service"].tap()
        XCTAssertTrue(app.buttons["Stop Service"].waitForExistence(timeout: 60), app.debugDescription)
        app.buttons["host.service.install"].tap()
        XCTAssertTrue(app.staticTexts["Host service updated. The old updater service and metrics collectors were removed."].waitForExistence(timeout: 180), app.debugDescription)
        waitLabel("host.service.status", contains: "Running", timeout: 30)
        screenshot("03-windows-service-updated")
        app.buttons["Manage Agents and Updates"].tap()
        XCTAssertTrue(app.staticTexts["Codex"].waitForExistence(timeout: 60), app.debugDescription)
        screenshot("04-windows-agent-updates")
        app.navigationBars["AI Agent Updates"].buttons["Done"].tap()
        app.navigationBars["Host Service"].buttons["Done"].tap()
        app.navigationBars["Edit Host"].buttons["Cancel"].tap()
        app.navigationBars["Hosts"].buttons["Done"].tap()
        if app.navigationBars["MSAM Settings"].exists { app.navigationBars["MSAM Settings"].buttons["Done"].tap() }
    }

    func testWindowsLiveMetrics() throws {
        guard ProcessInfo.processInfo.environment["MSAM_WINDOWS_IT"] == "1" else {
            throw XCTSkip("Requires an explicitly authorized Windows test host")
        }
        continueAfterFailure = false
        app.launch()
        let existing = app.buttons.matching(NSPredicate(format: "label == %@", hostName + ":msam-windows-test")).firstMatch
        if existing.exists {
            existing.tap()
        } else {
            let add = app.buttons["host.tab.add"]
            XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription)
            add.tap()
            XCTAssertTrue(app.navigationBars["Open Host"].waitForExistence(timeout: 10), app.debugDescription)
            app.textFields["host.picker.session"].tap()
            app.textFields["host.picker.session"].typeText("msam-windows-test\n")
            app.buttons.containing(.staticText, identifier: hostName).firstMatch.tap()
        }
        let disk = app.buttons["metrics.disk"]
        XCTAssertTrue(disk.waitForExistence(timeout: 60), app.debugDescription)
        waitEnabled(disk, timeout: 60)
        let gpu = app.buttons["metrics.gpu"]
        waitEnabled(gpu, timeout: 30)
        screenshot("05-windows-herdr-and-live-metrics")
        gpu.tap()
        XCTAssertTrue(app.staticTexts["NVIDIA GeForce GTX 1060 3GB"].waitForExistence(timeout: 10), app.debugDescription)
        screenshot("06-windows-gpu-details")
    }

    private func openHosts() {
        if app.navigationBars["Hosts"].exists { return }
        XCTAssertTrue(app.buttons["msam.settings"].waitForExistence(timeout: 20))
        app.buttons["msam.settings"].tap()
        XCTAssertTrue(app.buttons["settings.hosts.manage"].waitForExistence(timeout: 10))
        app.buttons["settings.hosts.manage"].tap()
    }

    func testWindowsTerminalInput() throws {
        guard ProcessInfo.processInfo.environment["MSAM_WINDOWS_IT"] == "1" else {
            throw XCTSkip("Requires an explicitly authorized Windows test host")
        }
        continueAfterFailure = false
        app.launch()
        let terminal = app.scrollViews["terminal.scroll"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 20), app.debugDescription)
        terminal.tap()
        app.typeText(XCUIKeyboardKey.escape.rawValue)
        app.typeText(XCUIKeyboardKey.escape.rawValue)
        app.typeText("Write-Output ('MSAM_'+'TERMINAL_OK')\n")
        sleep(2)
        screenshot("09-windows-terminal-input")
        let tabs = app.buttons.matching(NSPredicate(format: "label == %@", hostName + ":msam-windows-test"))
        if tabs.count > 1 {
            tabs.element(boundBy: 0).press(forDuration: 1)
            app.buttons["Close"].firstMatch.tap()
        }
    }

    private func reveal(_ element: XCUIElement) {
        let scroll = app.scrollViews["host.editor.form"]
        for _ in 0..<12 {
            if element.exists && element.isHittable && scroll.frame.insetBy(dx: -4, dy: -4).contains(element.frame) { return }
            if element.exists && element.frame.minY < scroll.frame.minY { scroll.swipeDown() }
            else { scroll.swipeUp() }
        }
        XCTFail("Host control is not visible: \(element)\n\(app.debugDescription)")
    }

    private func waitEnabled(_ element: XCUIElement, timeout: TimeInterval) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), app.debugDescription)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, app.debugDescription)
    }

    private func waitLabel(_ id: String, contains value: String, timeout: TimeInterval) {
        let element = app.descendants(matching: .any).matching(identifier: id).firstMatch
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND (label CONTAINS %@ OR value CONTAINS %@)", value, value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, app.debugDescription)
    }

    private func allowLocalNetwork() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
    }

    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
