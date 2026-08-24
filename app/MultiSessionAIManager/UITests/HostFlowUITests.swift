import XCTest

/// Exercises host configuration from the Herdr shell's settings cog. Hosts are
/// setup metadata only: tapping a row opens Edit Host and never enters the removed
/// session/file browser shell.
@MainActor
final class HostFlowUITests: XCTestCase {

    private var app: XCUIApplication!
    private var stepIndex = 0
    /// Unique per run so persisted simulator state cannot bypass the Add Host flow.
    private let hostName = "Herdr WARP \(UUID().uuidString.prefix(8))"

    override func setUp() async throws {
        await MainActor.run {
            continueAfterFailure = false
            app = XCUIApplication()
        }
    }

    func testEditorInteractionGeometryRejectsClippedAndObstructedFrames() {
        let editor = CGRect(x: 226, y: 200, width: 580, height: 606.5)
        let save = CGRect(x: 238, y: 753, width: 556, height: 47)

        XCTAssertFalse(Self.isReadyForEditorInteraction(
            elementExists: true,
            elementIsHittable: true,
            elementFrame: CGRect(x: 250, y: 803, width: 532, height: 22),
            editorFrame: editor,
            obstructionFrame: save
        ), "a field clipped below the editor viewport must not be treated as ready")
        XCTAssertFalse(Self.isReadyForEditorInteraction(
            elementExists: true,
            elementIsHittable: true,
            elementFrame: CGRect(x: 250, y: 760, width: 532, height: 22),
            editorFrame: editor,
            obstructionFrame: save
        ), "a field behind the pinned Save control must not be treated as ready")
        XCTAssertTrue(Self.isReadyForEditorInteraction(
            elementExists: true,
            elementIsHittable: true,
            elementFrame: CGRect(x: 250, y: 700, width: 532, height: 22),
            editorFrame: editor,
            obstructionFrame: save
        ), "a fully visible, unobstructed field should be ready")
    }

    // MARK: - Helpers

    private static func isReadyForEditorInteraction(
        elementExists: Bool,
        elementIsHittable: Bool,
        elementFrame: CGRect,
        editorFrame: CGRect,
        obstructionFrame: CGRect?
    ) -> Bool {
        guard elementExists,
              elementIsHittable,
              !elementFrame.isNull,
              !elementFrame.isInfinite,
              !elementFrame.isEmpty,
              !editorFrame.isNull,
              !editorFrame.isInfinite,
              !editorFrame.isEmpty,
              editorFrame.contains(elementFrame) else {
            return false
        }
        if let obstructionFrame,
           !obstructionFrame.isNull,
           !obstructionFrame.isEmpty,
           elementFrame.intersects(obstructionFrame) {
            return false
        }
        return true
    }

    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        stepIndex += 1
        attachment.name = String(format: "%02d_%@", stepIndex, name)
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func typeInto(_ identifier: String, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textFields[identifier]
        var focused = false
        for _ in 0..<3 where !focused {
            guard scrollEditorUntilReadyForInteraction(
                field,
                description: "text field \(identifier)",
                file: file,
                line: line
            ) else { break }
            field.tap()
            _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
            let focusExpectation = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hasKeyboardFocus == true"),
                object: field
            )
            focused = XCTWaiter.wait(for: [focusExpectation], timeout: 2) == .completed
        }
        XCTAssertTrue(
            focused,
            "text field \(identifier) never acquired keyboard focus; "
                + "value=\(String(describing: field.value)); "
                + editorInteractionDiagnostics(for: field) + "\n\(app.debugDescription)",
            file: file,
            line: line
        )
        guard focused else { return }
        field.typeText(text)
    }

    /// Scrolls the identified host editor—not an arbitrary root scroll view—until
    /// a known descendant can receive input. Frame comparison selects the semantic
    /// direction and the bounded failure includes the hierarchy for diagnosis.
    @discardableResult
    private func scrollEditorUntilReadyForInteraction(
        _ element: XCUIElement,
        description: String,
        towardTopWhenAbsent: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let editor = app.scrollViews["host.editor.form"]
        guard editor.waitForExistence(timeout: 5) else {
            XCTFail(
                "host.editor.form scroll view missing\n\(app.debugDescription)",
                file: file,
                line: line
            )
            return false
        }

        for attempt in 0...8 {
            if isReadyForEditorInteraction(element, editor: editor) { return true }
            guard attempt < 8 else { break }
            guard element.exists else {
                towardTopWhenAbsent ? editor.swipeDown() : editor.swipeUp()
                continue
            }
            let elementFrame = element.frame
            let editorFrame = editor.frame
            let pinnedSave = app.buttons["Save host"]
            let bandBottom = pinnedSave.exists
                ? min(editorFrame.maxY, pinnedSave.frame.minY)
                : editorFrame.maxY
            let margin: CGFloat = 12
            if elementFrame.minY < editorFrame.minY {
                nudgeEditor(editor, byPoints: editorFrame.minY - elementFrame.minY + margin)
            } else if elementFrame.maxY > bandBottom {
                nudgeEditor(editor, byPoints: bandBottom - elementFrame.maxY - margin)
            } else {
                editor.swipeUp()
            }
        }

        XCTFail(
            "\(description) is not fully visible and unobstructed after bounded scrolling; "
                + editorInteractionDiagnostics(for: element, editor: editor)
                + "\n\(app.debugDescription)",
            file: file,
            line: line
        )
        return false
    }

    /// Scrolls the editor by an exact number of points (positive moves content
    /// down, i.e. back toward the top of the form). `swipeUp()`/`swipeDown()`
    /// move roughly a viewport, which overshoots whenever the target only needs
    /// to clear the editor's top edge or the pinned Save bar -- and when the
    /// scroll is already at one end, the correcting swipe simply returns it to
    /// the same place, so the search oscillates until it gives up.
    private func nudgeEditor(_ editor: XCUIElement, byPoints delta: CGFloat) {
        let frame = editor.frame
        guard frame.height > 0, delta != 0 else { return }
        let limit = frame.height * 0.5
        let clamped = max(-limit, min(limit, delta))
        // Drag along the right edge, clear of the text fields, so the press
        // cannot land in one and raise the keyboard.
        let anchorY = clamped > 0 ? 0.3 : 0.7
        let start = editor.coordinate(withNormalizedOffset: CGVector(dx: 0.97, dy: anchorY))
        start.press(
            forDuration: 0.05,
            thenDragTo: start.withOffset(CGVector(dx: 0, dy: clamped))
        )
    }

    private func isReadyForEditorInteraction(
        _ element: XCUIElement,
        editor: XCUIElement
    ) -> Bool {
        let pinnedSave = app.buttons["Save host"]
        return Self.isReadyForEditorInteraction(
            elementExists: element.exists,
            elementIsHittable: element.isHittable,
            elementFrame: element.exists ? element.frame : .null,
            editorFrame: editor.frame,
            obstructionFrame: pinnedSave.exists ? pinnedSave.frame : nil
        )
    }

    private func editorInteractionDiagnostics(
        for element: XCUIElement,
        editor: XCUIElement? = nil
    ) -> String {
        let editor = editor ?? app.scrollViews["host.editor.form"]
        let pinnedSave = app.buttons["Save host"]
        return "element.exists=\(element.exists) element.hittable=\(element.isHittable) "
            + "element.frame=\(element.exists ? element.frame : .null) "
            + "editor.exists=\(editor.exists) editor.frame=\(editor.exists ? editor.frame : .null) "
            + "save.exists=\(pinnedSave.exists) "
            + "save.frame=\(pinnedSave.exists ? pinnedSave.frame : .null)"
    }

    /// Resign the keyboard only when the editor's neutral Authentication label is
    /// visible. Never use a global coordinate: this editor is a centered sheet, so
    /// tapping outside its bounds dismisses the entire Add/Edit flow.
    /// Resigns first responder. This has to actually succeed: while a field
    /// stays focused, SwiftUI re-scrolls the editor to keep it visible, so a
    /// swipe toward any other control is undone as fast as it is made. The
    /// "AUTHENTICATION" label is the preferred neutral target but is itself
    /// scrolled out of reach on a short form, hence the iPad keyboard's own
    /// dismiss key as a fallback.
    private func dismissKeyboard() {
        guard app.keyboards.firstMatch.exists else { return }
        let label = app.staticTexts["AUTHENTICATION"]
        let hideKey = app.keyboards.buttons["Hide keyboard"]
        if label.exists && label.isHittable {
            label.tap()
        } else if hideKey.exists && hideKey.isHittable {
            hideKey.tap()
        }
        _ = app.keyboards.firstMatch.waitForNonExistence(timeout: 3)
    }

    /// Save used to be polled with ten fixed 300 ms sleeps while SwiftUI committed
    /// text/key state. A predicate wait observes the actual enabled transition and
    /// prints the control plus hierarchy when that transition never arrives.
    private func waitUntilEnabled(
        _ element: XCUIElement,
        timeout: TimeInterval,
        description: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        guard element.waitForExistence(timeout: timeout) else {
            XCTFail("\(description) does not exist\n\(app.debugDescription)", file: file, line: line)
            return false
        }
        if element.isEnabled { return true }

        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: element
        )
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        guard result == .completed else {
            XCTFail(
                "\(description) stayed disabled; value=\(String(describing: element.value)) "
                    + "frame=\(element.frame)\n\(app.debugDescription)",
                file: file,
                line: line
            )
            return false
        }
        return true
    }

    /// SwiftUI's `List` exposes only its current lazy window to accessibility.
    /// Repeated simulator runs retain prior hosts, so a newly appended row may be
    /// persisted correctly but start below that window. Scroll the actual Hosts
    /// collection a bounded number of times and fail with the hierarchy if the
    /// named row never becomes visible.
    private func scrollHostsUntilVisible(
        _ hostName: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> Bool {
        let nameText = app.staticTexts[hostName]
        if nameText.exists && nameText.isHittable { return true }

        let list = app.collectionViews.firstMatch
        guard list.waitForExistence(timeout: 5) else {
            XCTFail("Hosts list collection is missing\n\(app.debugDescription)", file: file, line: line)
            return false
        }

        for _ in 0..<10 {
            if nameText.exists && nameText.isHittable { return true }
            list.swipeUp()
        }

        XCTFail(
            "host row '\(hostName)' was not visible after bounded Hosts-list scrolling\n"
                + app.debugDescription,
            file: file,
            line: line
        )
        return false
    }

    /// Exercises the help content without tapping any action that leaves the test
    /// app or contacts a live Cloudflare/private-network endpoint.
    /// Asserts the Host Setup sheet as it exists now.
    ///
    /// It used to assert Cloudflare install/enrol buttons, a team name, and
    /// `brew install cloudflared`. All of that was removed with the Cloudflare
    /// integration — how the iPad reaches a host is the user's own business —
    /// so the sheet is down to testing the route, Herdr, and plugins.
    private func assertHostSetupSheet(endpoint: String) {
        XCTAssertTrue(
            app.navigationBars["Host Setup"].waitForExistence(timeout: 8),
            "Host Setup sheet did not present\n\(app.debugDescription)"
        )
        XCTAssertTrue(app.buttons["host.setup.test.route"].exists,
                      "route test action missing")
        XCTAssertTrue(app.staticTexts["host.setup.endpoint"].label.contains(endpoint),
                      "sheet did not carry the endpoint through")
        XCTAssertFalse(app.staticTexts["host.setup.team"].exists,
                       "Cloudflare team name is still shown")
        XCTAssertFalse(app.buttons["host.setup.install.cloudflare"].exists,
                       "Cloudflare install action is still shown")
    }

    // MARK: - Test

    func testHostSettingsFlowEditsWithoutLegacySessionNavigation() throws {
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))

        // (a) Hosts are managed through the Herdr shell's app settings.
        let hostsNav = app.navigationBars["Hosts"]
        if !hostsNav.exists {
            let settingsCog = app.buttons["msam.settings"]
            XCTAssertTrue(
                settingsCog.waitForExistence(timeout: 8),
                "MSAM settings cog did not appear at launch"
            )
            settingsCog.tap()
            let manageHosts = app.buttons["settings.hosts.manage"]
            XCTAssertTrue(manageHosts.waitForExistence(timeout: 15),
                          "Manage Hosts action did not appear in app settings")
            manageHosts.tap()
        }
        XCTAssertTrue(hostsNav.waitForExistence(timeout: 15),
                      "Hosts list did not open from app settings")
        shot("a_hosts_launch")

        // Ensure a host row exists. If a persisted host is already present we add
        // ours anyway so the test is deterministic about which row it taps.
        addHostThroughUI()

        // Locate the row by its name static text, then resolve the enclosing cell.
        let nameText = app.staticTexts[hostName]
        XCTAssertTrue(nameText.waitForExistence(timeout: 10),
                      "host row '\(hostName)' not visible after add")
        let cell = app.cells.containing(.staticText, identifier: hostName).firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 10), "host cell not found")
        shot("a_host_row_present")

        // The list no longer offers Host Setup at all — neither a toolbar info
        // button nor a context action. It reached the sheet with a BLANK host
        // (no address, username or key), so it could not test a route or
        // install anything. Host Setup now lives in the editor, against a real
        // host.
        cell.press(forDuration: 1.0)
        XCTAssertFalse(app.buttons["host.setup.help.context"].waitForExistence(timeout: 2),
                       "removed Host Setup context action is still present")
        app.tap()   // dismiss the context menu

        // (b) No disclosure chevron: this is an edit action, not legacy navigation.
        let chevrons = cell.images.matching(identifier: "chevron.right")
        let chevronCount = chevrons.count
        shot("b_chevron_count_\(chevronCount)")
        XCTAssertEqual(chevronCount, 0,
            "host settings row must not advertise removed session navigation")

        // (c) Tap the row and prove it opens the host editor directly.
        let target: XCUIElement = nameText.isHittable ? nameText : cell
        target.tap()
        let editNavigation = app.navigationBars["Edit Host"]
        XCTAssertTrue(editNavigation.waitForExistence(timeout: 12),
                      "tapping a saved host did not open Edit Host")
        XCTAssertTrue(app.scrollViews["host.editor.form"].exists,
                      "host editor form is missing")
        XCTAssertFalse(app.buttons["Sessions"].exists)
        XCTAssertFalse(app.buttons["Files"].exists)
        shot("c_host_editor")

        // (d) Cancel returns to the Hosts settings list.
        let cancelEdit = app.buttons["Cancel"]
        XCTAssertTrue(cancelEdit.waitForExistence(timeout: 8), "Cancel button not found")
        cancelEdit.tap()
        XCTAssertTrue(hostsNav.waitForExistence(timeout: 10),
            "did not return to Hosts list after cancelling Edit Host")
        let addButton = app.buttons["Add Host"]
        XCTAssertTrue(addButton.waitForExistence(timeout: 8) || app.staticTexts[hostName].exists,
            "Hosts list affordances not visible after cancelling Edit Host")
        shot("d_back_on_hosts")

        // (e) Swipe actions: left-swipe reveals Delete, right-swipe reveals Edit.
        let rowForSwipe = app.cells.containing(.staticText, identifier: hostName).firstMatch
        XCTAssertTrue(rowForSwipe.waitForExistence(timeout: 8), "row missing for swipe")

        // Trailing (swipe left) -> Delete.
        rowForSwipe.swipeLeft()
        let deleteAction = app.buttons["Delete"]
        let deleteVisible = deleteAction.waitForExistence(timeout: 6)
        shot("e_swipe_left_delete")
        XCTAssertTrue(deleteVisible, "Delete swipe action did not appear on left swipe")
        // Dismiss the revealed action without deleting.
        if deleteVisible { rowForSwipe.swipeRight() }

        // Leading (swipe right) -> Edit. Re-resolve the row after the dismiss swipe.
        XCTAssertTrue(
            scrollHostsUntilVisible(hostName),
            "row did not return to the Hosts accessibility window after dismissing Delete"
        )
        let rowForEdit = app.cells.containing(.staticText, identifier: hostName).firstMatch
        XCTAssertTrue(rowForEdit.waitForExistence(timeout: 6), "row missing before edit swipe")
        rowForEdit.swipeRight()
        let editAction = app.buttons["Edit"]
        let editVisible = editAction.waitForExistence(timeout: 6)
        shot("e_swipe_right_edit")
        if !editVisible {
            // Fallback: a context menu (long press) must surface Edit + Delete.
            rowForEdit.press(forDuration: 1.0)
            let menuEdit = app.buttons["Edit"]
            let menuVisible = menuEdit.waitForExistence(timeout: 6)
            shot("e_context_menu")
            XCTAssertTrue(menuVisible, "neither swipe nor context menu surfaced Edit")
            // Open the editor to prove Edit works, then cancel.
            menuEdit.tap()
        } else {
            // Invoke Edit and assert the editor sheet opens.
            editAction.tap()
        }
        let editNav = app.navigationBars["Edit Host"]
        let editOpened = editNav.waitForExistence(timeout: 8)
        shot("e_edit_sheet")
        XCTAssertTrue(editOpened, "Edit did not open the Edit Host editor sheet")
        // Cancel out of the editor (do NOT mutate the host).
        let cancel = app.buttons["Cancel"]
        if cancel.exists { cancel.tap() }
        shot("e_done")
    }

    // MARK: - Add host through the real UI

    /// Drives the add-host editor: empty-state CTA or toolbar +, fills the
    /// connection fields, generates a key (Save is gated on a key), saves.
    private func addHostThroughUI() {
        // If our host already exists, nothing to do.
        if app.staticTexts[hostName].exists { return }

        let addCTA = app.buttons["Add a host"]      // empty-state NeonButton
        let addToolbar = app.buttons["Add Host"]    // toolbar +
        if addCTA.waitForExistence(timeout: 3) {
            addCTA.tap()
        } else if addToolbar.waitForExistence(timeout: 3) {
            addToolbar.tap()
        } else {
            XCTFail("no Add Host affordance found")
            return
        }

        // Editor sheet.
        XCTAssertTrue(app.navigationBars["Add Host"].waitForExistence(timeout: 10),
                      "Add Host editor did not present")

        XCTAssertTrue(app.staticTexts["PRIVATE SSH OVER WARP"].waitForExistence(timeout: 5),
                      "Private SSH over WARP section missing")
        XCTAssertTrue(app.buttons["Host Setup"].waitForExistence(timeout: 5),
                      "accessible Host Setup action missing")
        // Every Cloudflare/Access field is gone, the team name included: how the
        // iPad reaches a host is the user's own business.
        XCTAssertFalse(app.textFields["host.cloudflare.team"].exists,
                       "removed Cloudflare team field is still present")
        XCTAssertFalse(app.textFields["host.herdr.origin"].exists,
                       "removed Herdr origin field is still present")
        XCTAssertFalse(app.textFields["host.cloudflare.audience"].exists,
                       "removed Access audience field is still present")
        XCTAssertFalse(app.textFields["host.cloudflare.emails"].exists,
                       "removed allowed identities field is still present")
        XCTAssertFalse(app.descendants(matching: .any)["host.route.preference"].exists,
                       "removed browser route picker is still present")

        // Save is gated on a non-empty keyID — generate a key so Save enables.
        // This runs FIRST, while the editor is still scrolled to the top: with
        // the Access card trimmed to a single field, the form is short enough
        // that scrolling back UP from the bottom drags the sheet toward
        // interactive dismissal instead of scrolling the content.
        let generate = app.buttons["Generate new key"]
        guard scrollEditorUntilReadyForInteraction(
            generate,
            description: "Generate new key button"
        ) else { return }
        generate.tap()

        typeInto("host.name", hostName)
        typeInto("host.address", "127.0.0.1")
        typeInto("host.username", "test")
        // Port defaults to 22; leave it.

        // The keyboard otherwise receives the swipe gestures needed to bring the
        // lower Access card on screen.
        // The Add Host toolbar action must use the current unsaved draft values.
        dismissKeyboard()
        let setup = app.navigationBars["Add Host"].buttons["host.setup.help"]
        XCTAssertTrue(setup.waitForExistence(timeout: 5), "draft Host Setup action missing")
        setup.tap()
        assertHostSetupSheet(endpoint: "127.0.0.1:22")

        // Dismiss the keyboard so the pinned Save bar is unobstructed. There's
        // no keyboard-toolbar Done button, so tap a neutral non-field area (the
        // "Authentication" section label) to resign first responder.
        dismissKeyboard()

        let save = app.buttons["Save host"]
        XCTAssertTrue(
            waitUntilEnabled(save, timeout: 8, description: "Save host button"),
            "Save host stayed disabled — fields/key not committed"
        )
        save.tap()

        XCTAssertTrue(
            app.navigationBars["Hosts"].waitForExistence(timeout: 10),
            "Hosts list did not return after Save\n\(app.debugDescription)"
        )
        XCTAssertTrue(scrollHostsUntilVisible(hostName),
                      "host row did not appear after Save")
        let savedCell = app.cells.containing(.staticText, identifier: hostName).firstMatch
        XCTAssertTrue(savedCell.staticTexts["Private SSH · test@127.0.0.1:22"].exists,
                      "saved row does not identify its private SSH endpoint")
        // The Herdr setup badge was removed: it read from dead Access config and
        // so labelled every correctly-working host "Herdr not configured".
        XCTAssertFalse(savedCell.staticTexts["Herdr settings complete"].exists)
        XCTAssertFalse(savedCell.staticTexts["Herdr not configured"].exists)
    }
}
