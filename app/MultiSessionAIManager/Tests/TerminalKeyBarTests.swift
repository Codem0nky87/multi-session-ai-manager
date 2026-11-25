import CoreGraphics
import Foundation
import Testing
@testable import MultiSessionAIManager

/// The bar under the terminal: one floating row of icon buttons, in groups.
@Suite struct TerminalKeyBarTests {

    // MARK: - What is on the bar

    @Test func theButtonsStandInFiveGroupsInTheOrderTheyAreDrawn() {
        #expect(TerminalKeyBar.groups.map { $0.map(\.rawValue) } == [
            ["keyboard", "voice", "esc", "tab", "return"],
            ["shift", "ctrl", "alt"],
            ["up", "down", "left", "right", "home", "end", "pageup", "pagedown"],
            ["clipboard", "shortcuts", "function-keys", "password"],
            ["attach", "intelligence"],
        ])
        // Every button is in exactly one group.
        let all = TerminalKeyBar.groups.flatMap { $0 }
        #expect(all.count == TerminalBarKey.allCases.count)
        #expect(Set(all) == Set(TerminalBarKey.allCases))
    }

    /// The names UI tests and VoiceOver find the buttons by.
    @Test func everyButtonHasItsOwnIdentifierAndASpokenName() {
        #expect(TerminalBarKey.esc.identifier == "msam.quickkey.esc")
        #expect(TerminalBarKey.keyboard.identifier == "msam.quickkey.keyboard")
        #expect(TerminalBarKey.enter.identifier == "msam.quickkey.return")
        #expect(TerminalBarKey.functionKeys.identifier == "msam.function-keys")
        #expect(Set(TerminalBarKey.allCases.map(\.identifier)).count == TerminalBarKey.allCases.count)
        // Tab and End are drawn with the same arrow, so the name has to tell them apart.
        #expect(TerminalBarKey.tab.symbol == TerminalBarKey.end.symbol)
        #expect(TerminalBarKey.tab.name != TerminalBarKey.end.name)
        #expect(Set(TerminalBarKey.allCases.map(\.name)).count == TerminalBarKey.allCases.count)
        #expect(TerminalBarKey.allCases.allSatisfy { !$0.name.isEmpty })
    }

    /// Sending a file and Apple Intelligence came down from the top bar, which only
    /// informs now. They are found by the names they had up there.
    @Test func theButtonsThatCameDownFromTheTopBarKeepTheirIdentifiers() {
        #expect(TerminalBarKey.attach.identifier == "msam.send.file")
        #expect(TerminalBarKey.intelligence.identifier == "msam.intelligence.toggle")
        #expect(TerminalBarKey.attach.symbol == "paperclip")
        #expect(TerminalBarKey.intelligence.symbol == "apple.intelligence")
    }

    /// Selecting and copying are behind the bar's scissors, so the top bar's own
    /// buttons for them are gone, not moved.
    @Test func theTopBarCarriesNoActionButtonsWhileATerminalIsOpen() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("UI/RootView.swift"), encoding: .utf8)
        for identifier in ["msam.select.text", "msam.copy.selection", "msam.send.file",
                           "msam.intelligence.toggle", "msam.compact.intelligence", "msam.compact.menu"] {
            #expect(!source.contains("\"\(identifier)\""), "\(identifier) is still declared in the top bar")
        }
        // With no host open there is no bar under a terminal, so the cog is up
        // there for exactly that case.
        #expect(source.contains("if selectedTab == nil {\n                    Button {\n                        showingSettings = true"))
    }

    /// A button with nothing behind it here is not drawn.
    @Test func anAppButtonWithNothingBehindItIsLeftOff() {
        #expect(TerminalKeyBar.unavailable(canSendFile: true, hasIntelligence: true).isEmpty)
        #expect(TerminalKeyBar.unavailable(canSendFile: false, hasIntelligence: true) == [.attach])
        #expect(TerminalKeyBar.unavailable(canSendFile: true, hasIntelligence: false) == [.intelligence])
        // The whole group goes, and leaves no gap.
        let neither = TerminalKeyBar.unavailable(canSendFile: false, hasIntelligence: false)
        #expect(TerminalKeyBar.groups(hiding: neither).count == 4)
    }

    /// The switches in Settings: one button at a time, the rest left as they were.
    @Test func aSwitchInSettingsShowsOrHidesOneButton() {
        var stored = ""
        stored = TerminalKeyBar.stored(stored, showing: .home, false)
        stored = TerminalKeyBar.stored(stored, showing: .attach, false)
        #expect(stored == "home,attach")
        #expect(!TerminalKeyBar.shows(.home, in: stored))
        #expect(TerminalKeyBar.shows(.end, in: stored))

        stored = TerminalKeyBar.stored(stored, showing: .home, true)
        #expect(stored == "attach")
        // Showing what is shown, or hiding what is hidden, changes nothing.
        #expect(TerminalKeyBar.stored(stored, showing: .home, true) == "attach")
        #expect(TerminalKeyBar.stored(stored, showing: .attach, false) == "attach")
    }

    /// The microphone stays second from the left, clear of the corner of the screen.
    @Test func theMicrophoneIsSecondFromTheLeft() {
        #expect(TerminalKeyBar.groups.first?.dropFirst().first == .voice)
    }

    // MARK: - Choosing which buttons show

    @Test func aHiddenButtonLeavesTheBarAndAnEmptyGroupLeavesNoGap() {
        let shown = TerminalKeyBar.groups(hiding: [.home, .end, .shift, .ctrl, .alt])
        #expect(shown.map { $0.map(\.rawValue) } == [
            ["keyboard", "voice", "esc", "tab", "return"],
            ["up", "down", "left", "right", "pageup", "pagedown"],
            ["clipboard", "shortcuts", "function-keys", "password"],
            ["attach", "intelligence"],
        ])
        #expect(TerminalKeyBar.groups(hiding: []) == TerminalKeyBar.groups)
        #expect(TerminalKeyBar.groups(hiding: Set(TerminalBarKey.allCases)).isEmpty)
    }

    @Test func theChoiceIsKeptAsTextAndReadBackTheSame() {
        let hidden: Set<TerminalBarKey> = [.password, .home, .functionKeys]
        let stored = TerminalKeyBar.stored(hidden)
        // In the bar's own order, whatever order the set gives them in.
        #expect(stored == "home,function-keys,password")
        #expect(TerminalKeyBar.hidden(from: stored) == hidden)
        #expect(TerminalKeyBar.stored([]) == "")
        #expect(TerminalKeyBar.hidden(from: "").isEmpty)
    }

    /// A name from an older or newer build must not hide everything or crash.
    @Test func anUnknownNameInTheStoredChoiceIsIgnored() {
        #expect(TerminalKeyBar.hidden(from: "home,no-such-key,,end ") == [.home, .end])
    }

    // MARK: - What a button types

    private func press(_ key: TerminalBarKey, shift: Bool = false, alt: Bool = false,
                       app: Bool = false) -> TerminalBarKeyPress? {
        TerminalBarKeyPress.of(key, shift: shift, alt: alt, applicationCursor: app)
    }

    private func text(_ press: TerminalBarKeyPress?) -> String? {
        press.map { String(decoding: $0.bytes, as: UTF8.self) }
    }

    @Test func returnTypesACarriageReturn() {
        #expect(text(press(.enter)) == "\r")
        #expect(press(.enter)?.clearsShift == false)
    }

    /// Shift or Alt with Return is "a new line, do not send" in the agent TUIs:
    /// the coding their own terminal setup asks for, Escape and then Return.
    @Test func returnWithShiftOrAltTypesEscapeThenReturnAndUsesTheModifierUp() {
        let shifted = press(.enter, shift: true)
        #expect(text(shifted) == "\u{1b}\r")
        #expect(shifted?.clearsShift == true)

        let alted = press(.enter, alt: true)
        #expect(text(alted) == "\u{1b}\r")
        #expect(alted?.clearsAlt == true)
    }

    @Test func homeAndEndFollowTheCursorKeyMode() {
        #expect(text(press(.home)) == "\u{1b}[H")
        #expect(text(press(.end)) == "\u{1b}[F")
        #expect(text(press(.home, app: true)) == "\u{1b}OH")
        #expect(text(press(.end, app: true)) == "\u{1b}OF")
    }

    @Test func homeAndEndWithShiftCarryTheShiftCoding() {
        let home = press(.home, shift: true)
        #expect(text(home) == "\u{1b}[1;2H")
        #expect(home?.clearsShift == true)
        #expect(text(press(.end, shift: true, app: true)) == "\u{1b}[1;2F")
    }

    /// What the old bar's keys typed, unchanged by the new look.
    @Test func theKeysTheOldBarHadTypeWhatTheyAlwaysDid() {
        #expect(text(press(.esc)) == "\u{1b}")
        #expect(press(.esc)?.clearsShift == true)
        #expect(press(.esc)?.clearsAlt == true)

        #expect(text(press(.tab)) == "\t")
        #expect(text(press(.tab, shift: true)) == "\u{1b}[Z")
        #expect(text(press(.tab, alt: true)) == "\u{1b}\t")
        // Shift wins on Tab and leaves Alt armed.
        #expect(press(.tab, shift: true, alt: true)?.clearsAlt == false)

        #expect(text(press(.up)) == "\u{1b}[A")
        #expect(text(press(.down, app: true)) == "\u{1b}OB")
        #expect(text(press(.left, shift: true)) == "\u{1b}[1;2D")
        #expect(text(press(.right, shift: true, app: true)) == "\u{1b}Oc")
        #expect(text(press(.up, shift: true, app: true)) == "\u{1b}Oa")
        // Alt with left and right is "a word back" and "a word on".
        #expect(text(press(.left, alt: true)) == "\u{1b}b")
        #expect(text(press(.right, alt: true)) == "\u{1b}f")
        #expect(text(press(.up, alt: true)) == "\u{1b}\u{1b}[A")
        // Alt wins on an arrow and leaves Shift armed.
        let both = press(.left, shift: true, alt: true)
        #expect(both?.clearsAlt == true)
        #expect(both?.clearsShift == false)
    }

    /// These open something or hold a modifier; pressing one types nothing by itself.
    @Test func buttonsThatOpenSomethingTypeNothingThemselves() {
        for key: TerminalBarKey in [.keyboard, .voice, .shift, .ctrl, .alt, .pageUp, .pageDown,
                                    .clipboard, .shortcuts, .functionKeys, .password,
                                    .attach, .intelligence] {
            #expect(press(key) == nil, "\(key)")
        }
    }

    // MARK: - Shortcuts

    @Test func theShortcutsTypeTheirControlCharacters() {
        func bytes(_ label: String) -> [UInt8]? {
            TerminalShortcut.all.first { $0.label == label }?.bytes
        }
        #expect(bytes("Ctrl-C") == [0x03])
        #expect(bytes("Ctrl-D") == [0x04])
        #expect(bytes("Ctrl-Z") == [0x1A])
        #expect(bytes("Ctrl-L") == [0x0C])
        #expect(bytes("Ctrl-R") == [0x12])
        #expect(bytes("Ctrl-\\") == [0x1C])
        #expect(Set(TerminalShortcut.all.map(\.label)).count == TerminalShortcut.all.count)
        #expect(TerminalShortcut.all.allSatisfy { $0.bytes.count == 1 && !$0.meaning.isEmpty })
    }

    // MARK: - Pasting

    @Test func pastedTextIsTypedAsItIsAndNothingIsTypedForAnEmptyClipboard() {
        #expect(TerminalClipboard.bytes(pasting: ["ls -la"]) == Array("ls -la".utf8))
        #expect(TerminalClipboard.bytes(pasting: ["one", "two"]) == Array("one\ntwo".utf8))
        #expect(TerminalClipboard.bytes(pasting: []) == nil)
        #expect(TerminalClipboard.bytes(pasting: [""]) == nil)
    }

    // MARK: - Where the bar sits

    /// An iPad's bar used to lie flush on the bottom edge, under the home indicator.
    /// The pill floats clear of it.
    @Test func thePillFloatsClearOfTheHomeIndicatorAndCloseAboveTheKeyboard() {
        // iPad, keyboard down: nothing is cleared for it, so it lifts itself.
        #expect(TerminalKeyBarMetrics.bottomGap(clearedInset: 0, windowHomeInset: 20) == 16)
        // iPad with a home button: no indicator to clear.
        #expect(TerminalKeyBarMetrics.bottomGap(clearedInset: 0, windowHomeInset: 0) == 6)
        // iPhone: the home strip is already cleared below it.
        #expect(TerminalKeyBarMetrics.bottomGap(clearedInset: 34, windowHomeInset: 34) == 6)
        // Any device with the keyboard up.
        #expect(TerminalKeyBarMetrics.bottomGap(clearedInset: 420, windowHomeInset: 20) == 6)
    }

    @Test func aCollapsedBarGivesItsRowsBackToTheTerminal() {
        let open = TerminalKeyBarMetrics.reservedHeight(isCollapsed: false, clearedInset: 0, windowHomeInset: 20)
        // The gap above, the pill, and the lift off the home indicator: 6 + 44 + 16.
        #expect(open == 66)
        #expect(TerminalKeyBarMetrics.reservedHeight(isCollapsed: true, clearedInset: 0, windowHomeInset: 20) == 0)
        #expect(TerminalKeyBarMetrics.pillHeight >= HerdrChromeMetrics.minimumHitTarget)
    }

    /// The margin that keeps the terminal's last row out of iPadOS's resize grip is
    /// only needed when nothing else is under the terminal. With the bar open it was
    /// 20 points of nothing between the two.
    @Test func theResizeGripMarginIsKeptOnlyWhileTheBarIsCollapsed() {
        #expect(TerminalKeyBarMetrics.terminalClearance(isPhone: false, isCollapsed: false) == 0)
        #expect(TerminalKeyBarMetrics.terminalClearance(isPhone: false, isCollapsed: true)
                == HerdrChromeMetrics.resizeGripClearance)
        #expect(TerminalKeyBarMetrics.terminalClearance(isPhone: true, isCollapsed: true) == 0)
        #expect(TerminalKeyBarMetrics.terminalClearance(isPhone: true, isCollapsed: false) == 0)
    }

    /// The open bar takes no more from an iPad's terminal than the old bar and its
    /// margin did together, give or take a couple of points.
    @Test func theOpenBarCostsAnIPadNoMoreRowsThanTheOldOne() {
        let old = HerdrChromeMetrics.resizeGripClearance + HerdrChromeMetrics.minimumHitTarget
        let new = TerminalKeyBarMetrics.reservedHeight(isCollapsed: false, clearedInset: 0, windowHomeInset: 20)
            + TerminalKeyBarMetrics.terminalClearance(isPhone: false, isCollapsed: false)
        #expect(new <= old + 2)
    }
}
