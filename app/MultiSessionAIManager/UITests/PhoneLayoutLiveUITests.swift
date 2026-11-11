import XCTest

/// Explicit opt-in. Drives the REAL app on a phone-width simulator against a REAL
/// host and saves a screenshot of every screen, so the phone layout can be reviewed
/// as a whole rather than one sheet at a time.
///
/// The host is added the way a user without the account password would add it:
/// the wizard generates a key, the test hands the PUBLIC half out through
/// `exchangeDirectory/pubkey`, and waits for `exchangeDirectory/authorized` to
/// appear once whoever runs the test has installed that key on the host.
///
/// Run with `TEST_RUNNER_MSAM_PHONE_IT=1` and `TEST_RUNNER_MSAM_PHONE_FIXTURE`
/// pointing at a JSON object with `name`, `address`, `port`, `username` and
/// `exchangeDirectory`. Screenshots land in `exchangeDirectory/shots`.
@MainActor
final class PhoneLayoutLiveUITests: XCTestCase {
    private var app = XCUIApplication()
    private var fixture: Fixture?

    struct Fixture: Decodable {
        let name: String
        let address: String
        let port: Int
        let username: String
        let exchangeDirectory: String
    }

    private func requireFixture() throws -> Fixture {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MSAM_PHONE_IT"] == "1", let path = environment["MSAM_PHONE_FIXTURE"] else {
            throw XCTSkip("Requires an explicitly authorized test host")
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    }

    // MARK: - 1 · Add the host

    func test1AddHostWithGeneratedKey() throws {
        let fixture = try requireFixture()
        continueAfterFailure = false
        app.launch()
        dismissSystemAlerts()
        shot(fixture, "01-launch")

        openHosts()
        shot(fixture, "02-hosts")
        if app.staticTexts[fixture.name].waitForExistence(timeout: 4) { return }

        let add = app.buttons["Add Host"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription)
        add.tap()
        XCTAssertTrue(app.navigationBars["Add Host - Step 1 of 4"].waitForExistence(timeout: 10), app.debugDescription)
        shot(fixture, "03-step1-empty")

        self.fixture = fixture
        type(fixture.name, into: "host.name")
        shot(fixture, "04a-name-typed")
        type(fixture.address, into: "host.address")
        let port = app.textFields["host.port"]
        reveal(port)
        port.tap()
        port.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + String(fixture.port))
        shot(fixture, "04b-port-typed-keyboard-up")
        // What a user does next: drag the visible part of the form to reach the
        // field under the keyboard. (A swipe from the form's centre would start
        // on the pinned Next bar, which does not scroll anything.)
        let form = app.scrollViews["host.editor.form"]
        form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
            .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)))
        shot(fixture, "04c-after-drag-with-keyboard")
        hideKeyboardIfNeeded()
        type(fixture.username, into: "host.username")
        hideKeyboardIfNeeded()
        shot(fixture, "04-step1-filled")

        let generate = app.buttons["Generate new key"]
        reveal(generate)
        generate.tap()
        let show = app.buttons["Show public key"]
        reveal(show)
        shot(fixture, "05-step1-key")
        show.tap()
        let publicKey = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "ssh-ed25519 ")).firstMatch
        XCTAssertTrue(publicKey.waitForExistence(timeout: 10), app.debugDescription)
        shot(fixture, "06-public-key")

        let exchange = URL(fileURLWithPath: fixture.exchangeDirectory, isDirectory: true)
        try FileManager.default.createDirectory(at: exchange, withIntermediateDirectories: true)
        let authorized = exchange.appendingPathComponent("authorized")
        try? FileManager.default.removeItem(at: authorized)
        try (publicKey.label + "\n").write(to: exchange.appendingPathComponent("pubkey"), atomically: true, encoding: .utf8)
        app.navigationBars["Public Key"].buttons["Done"].tap()

        let deadline = Date().addingTimeInterval(300)
        while !FileManager.default.fileExists(atPath: authorized.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(2))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: authorized.path), "The generated key was never authorized on the host")

        // Walk the wizard as a state machine: prefer Next, and only run a setup
        // action when Next stays disabled without it.
        let next = app.buttons["Next"]
        let saveHost = app.buttons["Save Host"]
        XCTAssertTrue(next.waitForExistence(timeout: 20), app.debugDescription)
        next.tap()
        var lastTitle = ""
        for pass in 0..<14 {
            dismissSystemAlerts()
            let title = app.navigationBars.firstMatch.identifier
            if title != lastTitle {
                lastTitle = title
                _ = next.waitForExistence(timeout: 5)
                RunLoop.current.run(until: Date().addingTimeInterval(4))
                shot(fixture, "07-wizard-\(pass)-top")
                app.scrollViews.firstMatch.swipeUp()
                shot(fixture, "07-wizard-\(pass)-bottom")
                app.scrollViews.firstMatch.swipeDown()
            }
            if saveHost.exists && saveHost.isHittable { break }
            let notNow = app.descendants(matching: .button)["Not Now"]
            if notNow.exists && notNow.isHittable { notNow.tap(); continue }
            if waitFor(next, "exists == true AND enabled == true AND hittable == true", timeout: 25) {
                next.tap()
                continue
            }
            for label in ["Install or Check Services", "Enable or Repair Session Restore", "Continue without Background Updater"] {
                let action = app.buttons[label]
                if action.exists && action.isHittable && action.isEnabled {
                    action.tap()
                    _ = waitFor(next, "enabled == true", timeout: 300)
                    shot(fixture, "07-wizard-\(pass)-after-\(label.prefix(7))")
                    break
                }
            }
        }
        XCTAssertTrue(saveHost.waitForExistence(timeout: 10), app.debugDescription)
        shot(fixture, "08-save")
        saveHost.tap()
        if app.buttons["host.setup.close"].waitForExistence(timeout: 4) {
            shot(fixture, "09-setup-sheet")
            app.buttons["host.setup.close"].tap()
        }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot(fixture, "10-after-save")
    }

    // MARK: - 2 · The terminal

    func test2TerminalScreens() throws {
        let fixture = try requireFixture()
        self.fixture = fixture
        continueAfterFailure = true
        app.launch()
        dismissSystemAlerts()
        openHostTab(fixture)
        RunLoop.current.run(until: Date().addingTimeInterval(6))
        shot(fixture, "20-terminal")
        dumpTree(fixture, "20-terminal")

        // Raise the keyboard from the quick-key bar and type into the pane.
        let keyboardKey = app.buttons["msam.quickkey.keyboard"]
        if keyboardKey.waitForExistence(timeout: 10) {
            keyboardKey.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            shot(fixture, "21-terminal-keyboard-up")
            app.typeText("clear; seq 1 150\n")
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            shot(fixture, "22-terminal-after-seq")
            keyboardKey.tap()
            _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            shot(fixture, "23-terminal-keyboard-down")
        }

        // One-finger drag down = scroll back through history.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70)))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot(fixture, "24-terminal-scrolled-back")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30)))
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot(fixture, "25-terminal-scrolled-forward")
    }

    // MARK: - 3 · Keyboard geometry, text size, and the other phone screens

    func test3KeyboardTextSizeAndSheets() throws {
        let fixture = try requireFixture()
        self.fixture = fixture
        continueAfterFailure = true
        app.launch()
        dismissSystemAlerts()
        openHostTab(fixture)
        RunLoop.current.run(until: Date().addingTimeInterval(5))
        // Leave nothing half-typed at the host's prompt from an earlier pass.
        interrupt()
        var report: [String] = []
        let bar = app.descendants(matching: .any).matching(identifier: "msam.quickkeys").firstMatch
        let screen = app.windows.firstMatch.frame
        report.append("window \(screen)")
        report.append("keyboard down: bar \(bar.frame)")
        for id in ["esc", "voice", "tab", "ctrl", "alt", "shift", "left", "up", "pagedown", "keyboard"] {
            let key = app.buttons["msam.quickkey.\(id)"]
            report.append("  key \(id): exists=\(key.exists) frame=\(key.exists ? "\(key.frame)" : "-") hittable=\(key.exists && key.isHittable)")
        }

        let keyboardKey = app.buttons["msam.quickkey.keyboard"]
        keyboardKey.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        // The swipe-typing tip covers the keys on a fresh simulator.
        let tip = app.buttons["Continue"]
        if tip.waitForExistence(timeout: 2) { tip.tap() }
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        let keyboardFrame = app.keyboards.firstMatch.frame
        report.append("keyboard up: keyboard \(keyboardFrame) bar \(bar.frame)")
        report.append("gap between bar bottom and keyboard top: \(keyboardFrame.minY - bar.frame.maxY)")
        shot(fixture, "30-keyboard-up")
        app.typeText("clear; printf 'cols=%s rows=%s\\n' \"$(tput cols)\" \"$(tput lines)\"\n")
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot(fixture, "31-keyboard-up-size")
        keyboardKey.tap()
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        RunLoop.current.run(until: Date().addingTimeInterval(2))
        shot(fixture, "32-keyboard-down-size")

        // Text size from Settings: smaller, then larger, looking at the terminal each time.
        for (name, taps, control) in [("33-text-smaller", 4, "settings.terminal.decrease"),
                                      ("35-text-larger", 8, "settings.terminal.increase")] {
            app.buttons["msam.settings"].tap()
            let button = app.buttons[control]
            for _ in 0..<6 where !(button.exists && button.isHittable) { app.swipeUp() }
            XCTAssertTrue(button.waitForExistence(timeout: 5), app.debugDescription)
            for _ in 0..<taps { button.tap() }
            shot(fixture, name + "-settings")
            let done = app.navigationBars.buttons["Done"].firstMatch
            if done.exists { done.tap() }
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            shot(fixture, name + "-terminal")
            report.append("\(name): bar \(bar.frame)")
        }
        // Back to the default size.
        app.buttons["msam.settings"].tap()
        let reset = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Reset to'")).firstMatch
        for _ in 0..<6 where !(reset.exists && reset.isHittable) { app.swipeUp() }
        if reset.exists { reset.tap() }
        shot(fixture, "37-settings-bottom")
        app.swipeDown(); app.swipeDown()
        shot(fixture, "38-settings-top")
        let done = app.navigationBars.buttons["Done"].firstMatch
        if done.exists { done.tap() }

        // The compact top bar's sheets.
        for (name, label) in [("40-hardware", "Hardware metrics"), ("41-pulse", "AI Provider Pulse")] {
            let button = app.buttons[label]
            guard button.waitForExistence(timeout: 5) else { report.append("missing button \(label)"); continue }
            button.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            shot(fixture, name)
            for page in 1...4 {
                app.swipeUp()
                shot(fixture, name + "-scrolled-\(page)")
            }
            if label == "AI Provider Pulse" {
                let provider = app.staticTexts["Claude Code"].firstMatch
                if provider.exists && provider.isHittable {
                    provider.tap()
                    RunLoop.current.run(until: Date().addingTimeInterval(2))
                    shot(fixture, name + "-provider-detail")
                    app.swipeUp()
                    shot(fixture, name + "-provider-detail-scrolled")
                    dismissSheet()
                }
            }
            dismissSheet()
        }
        app.buttons["msam.compact.intelligence"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        shot(fixture, "42-intelligence")
        dismissSheet()
        app.buttons["msam.compact.menu"].tap()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        shot(fixture, "43-menu")
        // Outside the menu (a tap in the middle of the screen lands on one of its F-keys).
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.118)).tap()
        let fn = app.buttons["msam.function-keys"]
        if fn.exists { fn.tap(); RunLoop.current.run(until: Date().addingTimeInterval(1)); shot(fixture, "44-function-keys") }

        let directory = URL(fileURLWithPath: fixture.exchangeDirectory, isDirectory: true)
            .appendingPathComponent("shots", isDirectory: true)
        try? report.joined(separator: "\n").write(to: directory.appendingPathComponent("report.txt"),
                                                  atomically: true, encoding: .utf8)
    }

    // MARK: - 4 · Host screens and landscape

    func test4HostScreensAndLandscape() throws {
        let fixture = try requireFixture()
        self.fixture = fixture
        continueAfterFailure = true
        app.launch()
        dismissSystemAlerts()

        // Host picker (the + in the tab strip).
        let addTab = app.buttons["host.tab.add"]
        if addTab.waitForExistence(timeout: 10) {
            addTab.tap()
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            shot(fixture, "60-host-picker")
            let cancel = app.navigationBars.buttons["Cancel"].firstMatch
            if cancel.exists { cancel.tap() }
        }

        openHosts()
        shot(fixture, "61-hosts-list")

        // The editor for the saved host, top to bottom.
        // The row inside the Hosts list, not the same-named tab behind the sheet.
        let hostRow = app.collectionViews.staticTexts[fixture.name].firstMatch
        XCTAssertTrue(hostRow.waitForExistence(timeout: 5), app.debugDescription)
        hostRow.tap()
        let editor = app.scrollViews["host.editor.form"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15), app.debugDescription)
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        shot(fixture, "62-editor-0")
        for page in 1...6 {
            editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                .press(forDuration: 0.05, thenDragTo: editor.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
            shot(fixture, "62-editor-\(page)")
        }
        app.navigationBars["Edit Host"].buttons["Cancel"].tap()

        // The wizard's first step: number pad and the pinned Next bar.
        let add = app.buttons["Add Host"]
        XCTAssertTrue(add.waitForExistence(timeout: 10), app.debugDescription)
        add.tap()
        XCTAssertTrue(app.navigationBars["Add Host - Step 1 of 4"].waitForExistence(timeout: 10), app.debugDescription)
        let port = app.textFields["host.port"]
        port.tap()
        port.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5) + "2222")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        shot(fixture, "63-wizard-port-keyboard")
        // Return must be there and must put the keyboard away.
        port.typeText("\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5),
                      "The port field's keyboard must be dismissible with Return")
        XCTAssertEqual(port.value as? String, "2222", "A port must not be shown with digit grouping")
        shot(fixture, "64-wizard-after-done")
        let form = app.scrollViews["host.editor.form"]
        for page in 1...3 {
            form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
                .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)))
            shot(fixture, "65-wizard-scrolled-\(page)")
        }
        app.navigationBars.buttons["Cancel"].firstMatch.tap()

        // Landscape: the keys go back onto one row and the terminal keeps the height.
        for nav in ["Hosts", "MSAM Settings"] {
            let done = app.navigationBars[nav].buttons["Done"]
            if done.waitForExistence(timeout: 5) && done.isHittable { done.tap() }
        }
        openHostTab(fixture)
        XCUIDevice.shared.orientation = .landscapeLeft
        RunLoop.current.run(until: Date().addingTimeInterval(4))
        shot(fixture, "70-landscape")
        let bar = app.descendants(matching: .any).matching(identifier: "msam.quickkeys").firstMatch
        var report = ["landscape window \(app.windows.firstMatch.frame) bar \(bar.frame)"]
        let keyboardKey = app.buttons["msam.quickkey.keyboard"]
        if keyboardKey.exists {
            report.append("landscape keyboard key \(keyboardKey.frame) esc \(app.buttons["msam.quickkey.esc"].frame)")
            keyboardKey.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
            RunLoop.current.run(until: Date().addingTimeInterval(2))
            report.append("landscape keyboard up: keyboard \(app.keyboards.firstMatch.frame) bar \(bar.frame)")
            shot(fixture, "71-landscape-keyboard")
            RunLoop.current.run(until: Date().addingTimeInterval(5))
            let strip = app.descendants(matching: .any).matching(identifier: "host.tabstrip").firstMatch
            report.append("landscape keyboard up, settled: strip \(strip.exists ? "\(strip.frame)" : "-") settings \(app.buttons["msam.settings"].frame) bar \(bar.frame)")
            shot(fixture, "71-landscape-keyboard-settled")
            keyboardKey.tap()
            _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        }
        XCUIDevice.shared.orientation = .portrait
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        interrupt()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        shot(fixture, "72-back-to-portrait")
        report.append("portrait again: bar \(bar.frame)")
        let directory = URL(fileURLWithPath: fixture.exchangeDirectory, isDirectory: true)
            .appendingPathComponent("shots", isDirectory: true)
        try? report.joined(separator: "\n").write(to: directory.appendingPathComponent("report.txt"),
                                                  atomically: true, encoding: .utf8)
    }

    private func dismissSheet() {
        for label in ["Done", "Close", "Cancel"] {
            let button = app.navigationBars.buttons[label].firstMatch
            if button.exists && button.isHittable { button.tap(); return }
        }
        let close = app.buttons.matching(NSPredicate(format: "label IN {'Done','Close','Close Intelligence'}")).firstMatch
        if close.exists && close.isHittable { close.tap(); return }
        // No visible control: drag the sheet down.
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
    }

    private func openHostTab(_ fixture: Fixture) {
        let session = app.descendants(matching: .any).matching(identifier: "msam.quickkeys").firstMatch
        if session.waitForExistence(timeout: 6) { return }
        let addTab = app.buttons["host.tab.add"]
        let openFirst = app.buttons["Open a host"]
        let picker = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH 'host.picker.host.'")).firstMatch
        if addTab.waitForExistence(timeout: 5) { addTab.tap() }
        if !picker.waitForExistence(timeout: 8), openFirst.waitForExistence(timeout: 3) { openFirst.tap() }
        XCTAssertTrue(picker.waitForExistence(timeout: 15), app.debugDescription)
        shot(fixture, "19-host-picker")
        picker.tap()
        XCTAssertTrue(session.waitForExistence(timeout: 30), app.debugDescription)
        let status = app.descendants(matching: .any).matching(identifier: "host.session.status").firstMatch
        _ = status.waitForNonExistence(timeout: 45)
    }

    /// Writes the accessibility tree next to the screenshots, for reading frames.
    private func dumpTree(_ fixture: Fixture, _ name: String) {
        let directory = URL(fileURLWithPath: fixture.exchangeDirectory, isDirectory: true)
            .appendingPathComponent("shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? app.debugDescription.write(to: directory.appendingPathComponent("\(name).tree.txt"),
                                        atomically: true, encoding: .utf8)
    }

    // MARK: - Helpers

    private func openHosts() {
        if app.navigationBars["Hosts"].exists { return }
        let settings = app.buttons["msam.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 20), app.debugDescription)
        settings.tap()
        let manage = app.buttons["settings.hosts.manage"]
        XCTAssertTrue(manage.waitForExistence(timeout: 10), app.debugDescription)
        manage.tap()
        XCTAssertTrue(app.navigationBars["Hosts"].waitForExistence(timeout: 10), app.debugDescription)
    }

    private func type(_ value: String, into identifier: String) {
        let field = app.textFields[identifier]
        reveal(field)
        // Phone keyboards can swallow the first tap; verify the text landed and retry.
        for _ in 0..<3 {
            field.tap()
            field.typeText(value + "\n")
            if (field.value as? String) == value { return }
            field.tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + value + "\n")
            if (field.value as? String) == value { return }
        }
        XCTFail("Could not type \(value) into \(identifier): \(String(describing: field.value))")
    }

    private func reveal(_ element: XCUIElement) {
        let scroll = app.scrollViews["host.editor.form"]
        let next = app.buttons["Next"]
        for _ in 0..<10 {
            if element.exists && element.isHittable
                && scroll.frame.insetBy(dx: -4, dy: -4).contains(element.frame)
                && !next.frame.intersects(element.frame) { return }
            if element.exists && element.frame.minY < scroll.frame.minY {
                scroll.swipeDown()
            } else {
                scroll.swipeUp()
            }
        }
        if let fixture { shot(fixture, "zz-not-visible") }
        XCTFail("Control is not visible: \(element)\n\(app.debugDescription)")
    }

    @discardableResult
    private func waitFor(_ element: XCUIElement, _ format: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Ctrl-C at the host's prompt, through sticky `ctrl` and the keyboard: the bar
    /// has no key of its own for it. Leaves the keyboard as it found it.
    private func interrupt() {
        let ctrl = app.buttons["msam.quickkey.ctrl"]
        let keyboardKey = app.buttons["msam.quickkey.keyboard"]
        guard ctrl.waitForExistence(timeout: 5), keyboardKey.exists else { return }
        let keyboardWasUp = app.keyboards.firstMatch.exists
        if !keyboardWasUp {
            keyboardKey.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 5)
        }
        ctrl.tap()
        app.typeText("c")
        if !keyboardWasUp, app.keyboards.firstMatch.exists {
            keyboardKey.tap()
            _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
        }
    }

    private func hideKeyboardIfNeeded() {
        guard app.keyboards.firstMatch.exists else { return }
        let hide = app.keyboards.buttons["Hide keyboard"]
        if hide.exists && hide.isHittable {
            hide.tap()
        } else {
            app.navigationBars.firstMatch.tap()
        }
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 5)
    }

    private func dismissSystemAlerts() {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        for label in ["Allow", "Save Password", "Don't Save", "OK", "Not Now", "Save"] {
            let button = springboard.alerts.buttons[label]
            if button.waitForExistence(timeout: 1) { button.tap() }
        }
    }

    /// Saves the screen to `exchangeDirectory/shots` and attaches it to the result.
    private func shot(_ fixture: Fixture, _ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let directory = URL(fileURLWithPath: fixture.exchangeDirectory, isDirectory: true)
            .appendingPathComponent("shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
