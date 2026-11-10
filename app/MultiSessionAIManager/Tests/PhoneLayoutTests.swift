import CoreGraphics
import Foundation
import Testing
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

    /// Sixteen keys on one row of a phone are ~20pt wide each: too small to hit, and
    /// their labels broke in two ("ct" over "rl"). They wrap onto two rows instead.
    @Test func quickKeysWrapOntoTwoRowsWhenOneRowCannotFitThem() {
        // iPhone upright (SE, mini, standard, Pro Max).
        for width: CGFloat in [320, 375, 393, 402, 440] {
            #expect(TerminalQuickKeyBar.rowCount(forWidth: width) == 2, "\(width)")
        }
        // iPhone on its side (inside the safe area) and every iPad: one row, as before.
        for width: CGFloat in [734, 744, 820, 1024, 1366] {
            #expect(TerminalQuickKeyBar.rowCount(forWidth: width) == 1, "\(width)")
        }

        let wrapped = TerminalQuickKeyBar.keyRows(2)
        #expect(wrapped.map(\.count) == [8, 8])
        // Wrapping never reorders or drops a key.
        #expect(wrapped.flatMap { $0 }.map(\.identifier) == TerminalQuickKeyBar.orderedKeyIdentifiers)
        #expect(TerminalQuickKeyBar.keyRows(1).map(\.count) == [16])

        // On the narrowest phone each wrapped key is still wider than the minimum.
        let perRow = CGFloat(wrapped[0].count)
        let keyWidth = (320 - 2 * TerminalQuickKeyBar.horizontalPadding
                        - (perRow - 1) * TerminalQuickKeyBar.keySpacing) / perRow
        #expect(keyWidth >= TerminalQuickKeyBar.minimumKeyWidth - 2)

        #expect(TerminalQuickKeyBar.height(rows: 1) == HerdrChromeMetrics.minimumHitTarget)
        #expect(TerminalQuickKeyBar.height(rows: 2) == 84)
    }

    /// On a phone the terminal must not be shrunk for the keyboard twice: SwiftUI's own
    /// keyboard avoidance is switched off there because the quick-key bar already lifts
    /// itself by the keyboard's height.
    @Test func phoneTerminalOptsOutOfAutomaticKeyboardAvoidance() throws {
        let source = try sourceFile("UI/RootView.swift")
        #expect(source.contains(".ignoresSafeArea(Self.keyboardRegionsIgnoredByTheScreen, edges: .bottom)"))
        // Both regions in ONE modifier: the keyboard region alone stops 34pt short of
        // the bottom edge, which reopens a gap between the bar and the keyboard.
        #expect(source.contains("UIDevice.current.userInterfaceIdiom == .phone ? [.container, .keyboard] : []"))
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
