import Testing
@testable import MultiSessionAIManager

@Suite struct TerminalShiftArrowTests {
    @Test func shiftArrowsUseXtermModifierCodings() {
        // Codex (and most TUIs) bind "access queued messages" to Shift+Left.
        // The iPad hardware shift never reaches the session, so the quick-key
        // bar sends these codings itself. xterm normal mode: CSI 1;2 <letter>.
        #expect(EscapeSequences.leftShift == Array("\u{1b}[1;2D".utf8))
        #expect(EscapeSequences.rightShift == Array("\u{1b}[1;2C".utf8))
        #expect(EscapeSequences.upShift == Array("\u{1b}[1;2A".utf8))
        #expect(EscapeSequences.downShift == Array("\u{1b}[1;2B".utf8))
    }

    @Test func shiftArrowsHaveApplicationCursorForms() {
        // In DECCKM application mode the modifier coding is SS3 + lowercase.
        #expect(EscapeSequences.leftShiftApp == Array("\u{1b}Od".utf8))
        #expect(EscapeSequences.rightShiftApp == Array("\u{1b}Oc".utf8))
        #expect(EscapeSequences.upShiftApp == Array("\u{1b}Oa".utf8))
        #expect(EscapeSequences.downShiftApp == Array("\u{1b}Ob".utf8))
    }

    @Test func backtabIsShiftTab() {
        #expect(EscapeSequences.backtab == Array("\u{1b}[Z".utf8))
    }
}
