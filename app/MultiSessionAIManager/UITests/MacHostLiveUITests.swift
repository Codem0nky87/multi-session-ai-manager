import XCTest

/// Explicit opt-in: provisions the supplied macOS test host (the build Mac)
/// through the real wizard, then exercises a port forward with an SSH hop and
/// asserts the tunnel reaches Listening — and survives Stop + restart.
@MainActor
final class MacHostLiveUITests: XCTestCase {
    private var app = XCUIApplication()
    private let hostName = "Mac Live Test"

    struct Fixture: Decodable {
        let address: String
        let username: String
        let passwordFile: String
        let hopAddress: String
        let hopUsername: String
        let hopPasswordFile: String
        let targetHost: String
        let targetPort: Int
    }

    private var fixture: Fixture? {
        guard ProcessInfo.processInfo.environment["MSAM_MAC_IT"] == "1",
              let path = ProcessInfo.processInfo.environment["MSAM_MAC_FIXTURE"] else { return nil }
        return try? JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    func testMacHostPortForwardWithHopStartsStopsAndRestarts() throws {
        guard let fixture else {
            throw XCTSkip("Requires an explicitly authorized macOS test host")
        }
        continueAfterFailure = false
        let password = try String(contentsOfFile: fixture.passwordFile, encoding: .utf8)
            .trimmingCharacters(in: .newlines)
        let hopPassword = try String(contentsOfFile: fixture.hopPasswordFile, encoding: .utf8)
            .trimmingCharacters(in: .newlines)

        app.launch()
        openHosts()
        if !app.staticTexts[hostName].exists {
            app.buttons["Add Host"].tap()
            for (id, value) in [("host.name", hostName),
                                ("host.address", fixture.address),
                                ("host.username", fixture.username)] {
                let field = app.textFields[id]
                revealEditor(field)
                field.tap(); field.typeText(value + "\n")
            }
            let install = app.buttons["Install key on host…"]
            revealEditor(install)
            XCTAssertTrue(install.isEnabled, app.debugDescription)
            install.tap()
            let pw = app.secureTextFields["install.password"]
            XCTAssertTrue(pw.waitForExistence(timeout: 10), app.debugDescription)
            pw.tap(); pw.typeText(password)
            hideKeyboardIfNeeded()
            app.buttons["Install key"].firstMatch.tap()
            allowLocalNetwork()
            let done = app.scrollViews["install.form"].buttons["Done"]
            XCTAssertTrue(done.waitForExistence(timeout: 60), app.debugDescription)
            done.tap()
            XCTAssertTrue(app.buttons["Next"].waitForExistence(timeout: 10))
            app.buttons["Next"].tap()
            let services = app.buttons["Install or Check Services"]
            XCTAssertTrue(services.waitForExistence(timeout: 60), app.debugDescription)
            services.tap()
            // A transient SSH hiccup on the host-service step is retryable:
            // give the step two attempts before failing the run.
            var provisioned = false
            for _ in 0..<2 {
                let ready = XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "enabled == true"),
                    object: app.buttons["Next"])
                if XCTWaiter.wait(for: [ready], timeout: 300) == .completed { provisioned = true; break }
                dismissSystemAlerts()
                if services.exists { services.tap() }
            }
            XCTAssertTrue(provisioned, "host services never became ready: \(app.debugDescription)")
            screenshot("mac-it-services-ready")
            app.buttons["Next"].tap()
            waitEnabled(app.buttons["Next"], timeout: 60)
            let restore = app.buttons["Enable or Repair Session Restore"]
            if restore.exists && restore.isEnabled {
                restore.tap(); waitEnabled(app.buttons["Next"], timeout: 120)
            }
            app.buttons["Next"].tap()
            app.buttons["Save Host"].tap()
            if app.buttons["host.setup.close"].waitForExistence(timeout: 4) {
                app.buttons["host.setup.close"].tap()
            }
        }
        XCTAssertTrue(app.staticTexts[hostName].waitForExistence(timeout: 10), app.debugDescription)
        app.staticTexts[hostName].tap()

        // Open the port-forwarding manager.
        let pf = app.buttons["host.port-forwarding.manage"]
        revealEditor(pf)
        XCTAssertTrue(pf.isEnabled, app.debugDescription)
        pf.tap()
        XCTAssertTrue(app.navigationBars["SSH Web Tunnels"].waitForExistence(timeout: 60),
                      app.debugDescription)

        // Add a hop tunnel: first host = Mac, hop = Forge, target = something
        // reachable from the hop.
        let tunnelLabel = "MacIT-\(Int(Date.now.timeIntervalSince1970))"
        app.buttons["tunnel.add"].tap()
        let label = app.textFields["tunnel.field.label"]
        XCTAssertTrue(label.waitForExistence(timeout: 10), app.debugDescription)
        label.tap(); label.typeText(tunnelLabel + "\n")
        let target = app.textFields["tunnel.field.targetHost"]
        target.tap(); target.typeText(fixture.targetHost + "\n")
        let targetPort = app.textFields["tunnel.field.targetPort"]
        targetPort.tap()
        targetPort.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8)
                            + String(fixture.targetPort) + "\n")   // clear the prefilled scheme port
        let hopToggle = app.switches["tunnel.field.hopEnabled"].firstMatch
        XCTAssertTrue(hopToggle.waitForExistence(timeout: 5), app.debugDescription)
        // The row-level switch sometimes swallows the first tap, and reading
        // .value immediately races the animation: retry with a settle wait.
        // The identifier lands on the row container; the real control is the
        // inner switch knob at the trailing edge.
        let hopKnob = hopToggle.descendants(matching: .switch).firstMatch
        for attempt in 0..<4 {
            if hopToggle.value as? String == "1" { break }
            hopKnob.tap()
            let on = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == '1'"), object: hopToggle)
            if XCTWaiter.wait(for: [on], timeout: 5) == .completed { break }
            if attempt == 3 {
                XCTFail("hop toggle never engaged: \(hopToggle.debugDescription)")
            }
        }
        hideKeyboardIfNeeded()
        // Form rows below the fold are lazily realized: scroll until the hop
        // username field exists.
        let hopUser = revealField(app.textFields["tunnel.field.hopUsername"])
        hopUser.tap(); hopUser.typeText(fixture.hopUsername + "\n")
        let hopHost = revealField(app.textFields["tunnel.field.hopHost"])
        hopHost.tap(); hopHost.typeText(fixture.hopAddress + "\n")
        let hopPw = revealField(app.secureTextFields["tunnel.field.hopPassword"])
        hopPw.tap(); hopPw.typeText(hopPassword)
        hideKeyboardIfNeeded()
        // Prove the password actually landed: reveal it and read the value.
        revealField(app.buttons["tunnel.field.hopPasswordReveal"].firstMatch).tap()
        let revealed = app.textFields["tunnel.field.hopPassword"]
        XCTAssertTrue(revealed.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(revealed.value as? String, hopPassword,
                       "typed hop password did not land in the field")
        revealField(app.buttons["tunnel.save"]).tap()

        // Start it: the row's external-open button drives model.start. Wait
        // for the editor sheet to finish dismissing before touching the row.
        let status = app.descendants(matching: .any).matching(identifier: "tunnel.status").firstMatch
        XCTAssertTrue(app.buttons["tunnel.add"].waitForExistence(timeout: 30),
                      "editor never dismissed: \(app.debugDescription)")
        sleep(2)
        revealField(app.buttons["tunnel.open.external"].firstMatch).tap()
        screenshot("mac-it-starting")
        let listening = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS 'Listening' OR label CONTAINS 'Open on'"),
            object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [listening], timeout: 120), .completed,
                       "tunnel never reached Listening: \(status.debugDescription)\n\(app.debugDescription)")
        screenshot("mac-it-listening")

        // Stop, then restart: the restart must authenticate without re-prompt
        // (the password survives in the app-owned session).
        revealField(app.buttons["tunnel.stop"].firstMatch).tap()
        let idle = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS 'Not running'"),
            object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [idle], timeout: 30), .completed, app.debugDescription)
        revealField(app.buttons["tunnel.open.external"].firstMatch).tap()
        let relistening = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS 'Listening' OR label CONTAINS 'Open on'"),
            object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [relistening], timeout: 120), .completed,
                       "restart after stop failed: \(status.debugDescription)\n\(app.debugDescription)")
        screenshot("mac-it-restarted")

        // Clean up: stop the tunnel and leave the host provisioned.
        revealField(app.buttons["tunnel.stop"].firstMatch).tap()
        app.navigationBars["SSH Web Tunnels"].buttons["Done"].tap()
        if app.navigationBars["Edit Host"].buttons["Cancel"].waitForExistence(timeout: 4) {
            app.navigationBars["Edit Host"].buttons["Cancel"].tap()
        }
    }

    private func openHosts() {
        if app.navigationBars["Hosts"].exists { return }
        XCTAssertTrue(app.buttons["msam.settings"].waitForExistence(timeout: 20))
        app.buttons["msam.settings"].tap()
        XCTAssertTrue(app.buttons["settings.hosts.manage"].waitForExistence(timeout: 10))
        app.buttons["settings.hosts.manage"].tap()
    }

    private func revealEditor(_ element: XCUIElement) {
        let scroll = app.scrollViews["host.editor.form"]
        for _ in 0..<12 {
            if element.exists && element.isHittable
                && scroll.frame.insetBy(dx: -4, dy: -4).contains(element.frame) { return }
            if element.exists && element.frame.minY < scroll.frame.minY { scroll.swipeDown() }
            else { scroll.swipeUp() }
        }
        if element.exists { return }
        XCTFail("Host control is not visible: \(element)\n\(app.debugDescription)")
    }

    private func waitEnabled(_ element: XCUIElement, timeout: TimeInterval) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), app.debugDescription)
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, app.debugDescription)
    }

    /// Form rows are lazily realized: scroll the presented sheet until the
    /// element exists, then return it.
    private func revealField(_ element: XCUIElement) -> XCUIElement {
        for _ in 0..<8 {
            if element.waitForExistence(timeout: 4) && element.isHittable { return element }
            app.swipeUp()
        }
        XCTAssertTrue(element.waitForExistence(timeout: 10),
                      "field never realized: \(element)\n\(app.debugDescription)")
        return element
    }

    private func hideKeyboardIfNeeded() {
        let hide = app.keyboards.buttons["Hide keyboard"]
        if hide.exists { hide.tap() }
    }

    private func allowLocalNetwork() {
        dismissSystemAlerts()
    }

    /// Springboard interrupts (local-network permission, "Save Password?")
    /// block the app's own buttons; sweep them away.
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
