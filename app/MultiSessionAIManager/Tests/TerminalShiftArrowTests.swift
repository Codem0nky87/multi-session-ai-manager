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

    @Test func ctrlTurnsAKeyIntoItsStandardControlCode() {
        func ctrl(_ key: Character) -> UInt8 { key.asciiValue!.controlCharacter }
        #expect(ctrl("a") == 0x01)
        #expect(ctrl("c") == 0x03)
        #expect(ctrl("z") == 0x1A)
        // A capital is the same chord (Caps Lock, or Shift held too).
        #expect(ctrl("C") == 0x03)
        #expect(ctrl("Z") == 0x1A)
        #expect(ctrl("[") == 0x1B)
        #expect(ctrl("\\") == 0x1C)
        #expect(ctrl("]") == 0x1D)
        #expect(ctrl("^") == 0x1E)
        #expect(ctrl("_") == 0x1F)
        #expect(ctrl("/") == 0x1F)
        #expect(ctrl("@") == 0x00)
        #expect(ctrl(" ") == 0x00)
        #expect(ctrl("?") == 0x7F)
        // No control form: passed through, including the bytes of a multi-byte character.
        #expect(ctrl("1") == UInt8(ascii: "1"))
        #expect(ctrl(".") == UInt8(ascii: "."))
        #expect(UInt8(0xC3).controlCharacter == 0xC3)
        #expect(UInt8(0x03).controlCharacter == 0x03)
    }
}
