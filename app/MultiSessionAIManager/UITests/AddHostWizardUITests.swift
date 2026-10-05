import XCTest

@MainActor
final class AddHostWizardUITests: XCTestCase {
    func testRealRemoteFolderCanBeSelected() throws {
        guard ProcessInfo.processInfo.environment["MSAM_SSH_IT"] == "1" else {
            throw XCTSkip("Requires the disposable loopback SSH fixture")
        }
        struct Fixture: Decodable {
            let root: String
            let port: Int
            let username: String
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            URL(fileURLWithPath: ProcessInfo.processInfo.environment["MSAM_SSH_FIXTURE"]!)))
        continueAfterFailure = false
        let app = XCUIApplication()
        openWizard(app)
        for (id, value) in [("host.name", "Live folder browser"), ("host.address", "127.0.0.1"),
                            ("host.port", String(fixture.port)), ("host.username", fixture.username)] {
            let field = app.textFields[id]
            reveal(field, in: app)
            field.tap()
            if id == "host.port" {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + value)
            } else {
                field.typeText(value + "\n")
            }
        }

        let generate = app.buttons["Generate new key"]
        reveal(generate, in: app)
        generate.tap()
        let show = app.buttons["Show public key"]
        reveal(show, in: app)
        show.tap()
        let publicKey = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "ssh-ed25519 ")).firstMatch
        XCTAssertTrue(publicKey.waitForExistence(timeout: 10))
        // Authorize only this generated public key in the disposable server's
        // own fixture file. Never edit the user's ~/.ssh/authorized_keys.
        let authorizedKeys = URL(fileURLWithPath: fixture.root + "/client_key.pub")
        let existing = try String(contentsOf: authorizedKeys, encoding: .utf8)
        try (existing + "\n" + publicKey.label + "\n").write(to: authorizedKeys, atomically: true, encoding: .utf8)
        app.navigationBars["Public Key"].buttons["Done"].tap()

        let browse = app.buttons["host.workdir.browse"]
        reveal(browse, in: app)
        browse.tap()
        XCTAssertTrue(app.navigationBars["Choose folder"].waitForExistence(timeout: 10))
        let root = app.buttons["workdir.root"]
        XCTAssertTrue(root.waitForExistence(timeout: 15))
        root.tap()
        let chosenPath = fixture.root + "/folders/linked projects/nested folder"
        for folder in chosenPath.split(separator: "/").map(String.init) {
            let listing = app.scrollViews.matching(identifier: "workdir.folders").firstMatch
            XCTAssertTrue(listing.waitForExistence(timeout: 15))
            let row = listing.buttons.matching(NSPredicate(format: "label CONTAINS %@", folder)).firstMatch
            for _ in 0..<15 where !row.isHittable { listing.swipeUp() }
            XCTAssertTrue(row.isHittable, "Remote directory must be navigable: \(folder)")
            row.tap()
        }
        let choose = app.buttons["Use this folder"]
        XCTAssertTrue(choose.waitForExistence(timeout: 10))
        XCTAssertTrue(choose.isEnabled)
        choose.tap()
        XCTAssertTrue(app.navigationBars["Add Host - Step 1 of 4"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[chosenPath].exists, "The chosen remote path must be saved in the wizard draft")
    }

    func testFirstStepOffersKeyInstallationAndRemoteFolderExplorer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        openWizard(app)
        XCTAssertTrue(app.navigationBars["Add Host - Step 1 of 4"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Next"].isEnabled, "An empty draft cannot proceed to SSH setup")

        let scroll = app.scrollViews["host.editor.form"]
        let install = app.buttons["Install key on host…"]
        for _ in 0..<6 where !install.isHittable { scroll.swipeUp() }
        XCTAssertTrue(install.exists, "The wizard must retain password-based SSH key installation")
        let browse = app.buttons["Browse remote folders…"]
        for _ in 0..<4 where !browse.isHittable { scroll.swipeUp() }
        XCTAssertTrue(browse.exists, "Workdir selection must open the remote SSH explorer")
        XCTAssertFalse(browse.isEnabled, "Browsing requires SSH connection details and a key")
    }

    func testKeyInstallerAndRemoteExplorerPresentFromTheWizard() {
        continueAfterFailure = false
        let app = XCUIApplication()
        openWizard(app)
        // Loopback's reserved port 1 fails locally; no real host is provisioned.
        for (id, value) in [("host.name", "Wizard UI test"), ("host.address", "127.0.0.1"),
                            ("host.port", "1"), ("host.username", "wizard")] {
            let field = app.textFields[id]
            reveal(field, in: app)
            field.tap()
            if id == "host.port" {
                field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + value)
                XCTAssertEqual(field.value as? String, "1")
            } else {
                field.typeText(value + "\n")
            }
        }

        let install = app.buttons["Install key on host…"]
        reveal(install, in: app)
        install.tap()
        let installer = app.navigationBars["Install key"]
        XCTAssertTrue(installer.waitForExistence(timeout: 10))
        installer.buttons["Cancel"].tap()

        let browse = app.buttons["host.workdir.browse"]
        reveal(browse, in: app)
        XCTAssertTrue(browse.isEnabled, "Install-key preparation generates and selects a key")
        browse.tap()
        let explorer = app.navigationBars["Choose folder"]
        XCTAssertTrue(explorer.waitForExistence(timeout: 10))
        let choose = app.buttons["Use this folder"]
        XCTAssertTrue(choose.waitForExistence(timeout: 20))
        XCTAssertFalse(choose.isEnabled, "A failed remote connection must not select an unverified path")
        explorer.buttons["Cancel"].tap()

        app.buttons["Next"].tap()
        XCTAssertTrue(app.navigationBars["Add Host - Step 2 of 4"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Next"].isEnabled, "Failed SSH discovery must not unlock later steps")
        let back = app.buttons["Back"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: back)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 20), .completed)
        back.tap()
        XCTAssertTrue(app.navigationBars["Add Host - Step 1 of 4"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.textFields["host.name"].value as? String, "Wizard UI test")
    }

    private func openWizard(_ app: XCUIApplication) {
        app.launch()
        if !app.navigationBars["Hosts"].exists {
            let settings = app.buttons["msam.settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 15))
            settings.tap()
            let hosts = app.buttons["settings.hosts.manage"]
            XCTAssertTrue(hosts.waitForExistence(timeout: 10))
            hosts.tap()
        }
        let add = app.buttons["Add Host"]
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        add.tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["host.editor.form"]
        let next = app.buttons["Next"]
        for _ in 0..<8 {
            if element.exists && element.isHittable
                && scroll.frame.insetBy(dx: -4, dy: -4).contains(element.frame)
                && !next.frame.intersects(element.frame) { return }
            if element.exists && element.frame.minY < scroll.frame.minY {
                scroll.swipeDown()
            } else {
                scroll.swipeUp()
            }
        }
        XCTFail("Wizard control is not visible: \(element)\n\(app.debugDescription)")
    }
}
