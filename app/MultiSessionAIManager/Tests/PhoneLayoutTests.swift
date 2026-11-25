import CoreGraphics
import Foundation
import Testing
import UIKit
import SwiftUI
@testable import MultiSessionAIManager

/// The app runs on iPhone as well as iPad. These pin things that had only ever
/// been looked at on an iPad.
@Suite struct PhoneLayoutTests {

    /// A port is an identifier. Interpolating the `Int` into a `Text` localises it,
    /// which printed port 2222 as "2 222" in the host list and host picker.
    @Test func sshDestinationNeverGroupsThePortDigits() {
        let host = Host(name: "Foundry", address: "127.0.0.1", port: 2222,
                        username: "rufus", keyID: "key", defaultWorkdir: "")
        #expect(host.sshDestination == "rufus@127.0.0.1:2222")

        let high = Host(name: "High", address: "example.com", port: 65_535,
                        username: "root", keyID: "key", defaultWorkdir: "")
        #expect(high.sshDestination == "root@example.com:65535")
    }

    @Test func hostRowsShowTheDestinationThroughThatOneFormatter() throws {
        for path in ["UI/Hosts/HostListView.swift", "UI/HostPickerSheet.swift"] {
            let source = try sourceFile(path)
            #expect(source.contains("host.sshDestination"), "\(path)")
            #expect(!source.contains("\\(host.port)"), "\(path) must not interpolate the port into a Text")
        }
    }

    /// The Save/Next bar is a bottom inset of the form, so nothing scrolls underneath
    /// it; the port's number pad, which has no Return key, gets a Done key.
    @Test func hostEditorKeepsItsSaveBarOutOfTheFormAndCanDismissTheNumberPad() throws {
        let source = try sourceFile("UI/Hosts/HostEditView.swift")
        #expect(source.contains(".safeAreaInset(edge: .bottom, spacing: 0) { saveBar }"))
        #expect(!source.contains(".padding(.bottom, 100)"))
        #expect(source.contains(".number.grouping(.never)"))
        // The port field needs a keyboard with a Return key to be dismissible on a phone.
        #expect(source.contains("self.keyboard = .numbersAndPunctuation"))
        #expect(!source.contains("self.keyboard = .numberPad"))
    }

    /// The 20pt strip under the terminal exists for iPadOS's window-resize grip.
    @Test func phoneTerminalKeepsNoResizeGripMargin() {
        #expect(HerdrChromeMetrics.terminalBottomClearance(isPhone: true) == 0)
        #expect(HerdrChromeMetrics.terminalBottomClearance(isPhone: false) == HerdrChromeMetrics.resizeGripClearance)
    }

    /// Copy that names the device must be true on a phone. Any string that says
    /// "iPad" therefore has to say "iPhone" as well, or say neither.
    @Test func userFacingCopyNeverCallsAnIPhoneAnIPad() throws {
        let literal = try NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*""#)
        var offenders: [String] = []
        for directory in ["UI", "Core", "App"] {
            let root = appRoot.appendingPathComponent(directory, isDirectory: true)
            let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let file = files?.nextObject() as? URL {
                guard file.pathExtension == "swift" else { continue }
                let source = try String(contentsOf: file, encoding: .utf8)
                for (index, line) in source.components(separatedBy: "\n").enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.hasPrefix("//") else { continue }
                    let range = NSRange(line.startIndex..<line.endIndex, in: line)
                    for match in literal.matches(in: line, range: range) {
                        guard let swiftRange = Range(match.range, in: line) else { continue }
                        let text = String(line[swiftRange])
                        if text.contains("iPad"), !text.contains("iPhone") {
                            offenders.append("\(file.lastPathComponent):\(index + 1): \(text)")
                        }
                    }
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }

    /// On one row of a phone the keys were ~20pt wide each: too small to hit. They
    /// keep a width a thumb can hit on every device, and the row scrolls sideways
    /// where it does not fit, so the bar is one row high everywhere.
    @Test func quickKeysKeepAHittableWidthAndTheBarStaysOneRowHigh() {
        #expect(TerminalKeyBarMetrics.keyWidth(isPhone: true) >= 40)
        #expect(TerminalKeyBarMetrics.keyWidth(isPhone: false) >= HerdrChromeMetrics.minimumHitTarget)
        #expect(TerminalKeyBarMetrics.pillHeight == HerdrChromeMetrics.minimumHitTarget)
        // A phone's home strip is already cleared under the bar, so the bar adds
        // one row of keys and its two gaps: less than the two rows it used to be.
        let onPhone = TerminalKeyBarMetrics.reservedHeight(isCollapsed: false, clearedInset: 34, windowHomeInset: 34)
        #expect(onPhone == 56)
        #expect(onPhone < 84)
    }

    /// The bar has no key of its own for a single chord (it had `^c` and `^/`): sticky
    /// Control and then the key sends any of them, and the shortcuts button holds the
    /// common ones.
    @Test func quickKeysCarryNoSingleChordKeys() {
        let keys = TerminalKeyBar.groups.flatMap { $0 }.map(\.identifier)
        #expect(keys.allSatisfy { !$0.contains("ctrl-") && !$0.contains("^") })
        #expect(keys.contains("msam.quickkey.ctrl"))
        #expect(keys.contains("msam.quickkey.shortcuts"))
        #expect(keys.contains("msam.function-keys"))
    }

    /// Sticky `ctrl` is the only way to send Ctrl-C and Ctrl-/ from the bar, so it has
    /// to produce them from either keyboard — and Ctrl-/ used to come out as a plain "/".
    @MainActor
    @Test func stickyCtrlThenAKeySendsTheChordsTheBarUsedToHaveKeysFor() {
        let controller = KeyInputController()
        let inputView = TerminalKeyInputView(frame: .zero)
        var sent: [[UInt8]] = []
        inputView.onInput = { sent.append($0) }
        controller.view = inputView

        // On-screen keyboard.
        for (typed, expected) in [("c", UInt8(0x03)), ("/", 0x1F), ("C", 0x03), ("d", 0x04)] {
            controller.toggleCtrl()
            inputView.insertText(typed)
            #expect(sent.last == [expected], "ctrl then \(typed)")
            #expect(controller.isCtrlArmed == false, "one key only")
        }
        inputView.insertText("/")
        #expect(sent.last == [UInt8(ascii: "/")], "unarmed, the key is itself again")

        // Hardware keyboard.
        controller.toggleCtrl()
        #expect(inputView.handleHardwareKey(keyCode: .keyboardSlash, characters: "/", modifierFlags: []))
        #expect(sent.last == [0x1F])
        controller.toggleCtrl()
        #expect(inputView.handleHardwareKey(keyCode: .keyboardC, characters: "c", modifierFlags: []))
        #expect(sent.last == [0x03])
        // A held Control key needs no latch.
        #expect(inputView.handleHardwareKey(keyCode: .keyboardSlash, characters: "/", modifierFlags: [.control]))
        #expect(sent.last == [0x1F])
    }

    /// Both devices already reserve the keyboard's height beneath the quick keys.
    @Test @MainActor func terminalOptsOutOfAutomaticKeyboardAvoidanceOnEveryDevice() {
        // Both regions in ONE modifier: the keyboard region alone stops 34pt short of
        // the bottom edge, which reopens a gap between the bar and the keyboard.
        #expect(RootView.keyboardRegionsIgnoredByTheScreen == [.container, .keyboard])
    }

    /// The quick-key bar clears the keyboard while it is up and the home-indicator
    /// strip otherwise. The terminal view's own safe-area reading is 0 (it ignores the
    /// safe area), so a phone takes the window's.
    @Test func quickKeyBarClearsTheHomeIndicatorOnAPhone() {
        // Keyboard down, iPhone: lifted by the window's 34pt strip.
        #expect(KeyboardVisibilityModel.barBottomInset(
            keyboardOverlap: 0, measuredHomeInset: 0, windowHomeInset: 34, isPhone: true) == 34)
        // Keyboard up: the keyboard covers the strip, so only its height counts.
        #expect(KeyboardVisibilityModel.barBottomInset(
            keyboardOverlap: 301, measuredHomeInset: 0, windowHomeInset: 34, isPhone: true) == 301)
        // iPad is unchanged: it never used the window's inset.
        #expect(KeyboardVisibilityModel.barBottomInset(
            keyboardOverlap: 0, measuredHomeInset: 0, windowHomeInset: 20, isPhone: false) == 0)
        #expect(KeyboardVisibilityModel.barBottomInset(
            keyboardOverlap: 300, measuredHomeInset: 0, windowHomeInset: 20, isPhone: false) == 300)
    }

    private var appRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        try String(contentsOf: appRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }
}
