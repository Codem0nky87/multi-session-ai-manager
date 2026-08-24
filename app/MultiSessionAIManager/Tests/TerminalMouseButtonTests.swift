import CoreGraphics
import Foundation
import Testing
@testable import MultiSessionAIManager

/// Right-click is forwarded to the remote as SGR button 2 so Herdr can raise its
/// own context menu — the menu belongs to whatever runs in the pane, which is
/// the only thing that knows what the entries should be.
@Suite struct TerminalMouseButtonTests {

    private func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }

    @Test func aLeftClickIsStillButtonZero() {
        // Existing behaviour must not shift: pane focus and border-resize depend
        // on it.
        #expect(text(TerminalMouse.sgr(.press, col: 0, row: 0)) == "\u{1b}[<0;1;1M")
        #expect(text(TerminalMouse.sgr(.release, col: 0, row: 0)) == "\u{1b}[<0;1;1m")
    }

    @Test func aRightClickIsButtonTwo() {
        #expect(text(TerminalMouse.sgr(.press, button: .right, col: 4, row: 2)) == "\u{1b}[<2;5;3M")
        #expect(text(TerminalMouse.sgr(.release, button: .right, col: 4, row: 2)) == "\u{1b}[<2;5;3m")
    }

    @Test func aDragKeepsItsButtonAndAddsTheMotionFlag() {
        // Motion adds 32 ON TOP of the button code, so a right-drag is 34 — not
        // 32, which would report it as a left-drag.
        #expect(text(TerminalMouse.sgr(.drag, col: 0, row: 0)) == "\u{1b}[<32;1;1M")
        #expect(text(TerminalMouse.sgr(.drag, button: .right, col: 0, row: 0)) == "\u{1b}[<34;1;1M")
    }

    @Test func coordinatesStayOneBasedAndClamped() {
        // The protocol is 1-based; a negative cell would encode as 0 and be
        // read as out of range.
        #expect(text(TerminalMouse.sgr(.press, button: .right, col: -5, row: -5)) == "\u{1b}[<2;1;1M")
    }

    @Test func wheelCodesAreUnaffectedByTheButtonChange() {
        #expect(text(TerminalMouse.wheel(up: true, col: 0, row: 0)) == "\u{1b}[<64;1;1M")
        #expect(text(TerminalMouse.wheel(up: false, col: 0, row: 0)) == "\u{1b}[<65;1;1M")
    }

    @Test func aClickIsAPressAndAReleaseAtTheSameCell() {
        // A press with no release leaves the remote believing the button is
        // still held, which breaks the next interaction.
        let click = TerminalMouse.sgr(.press, button: .right, col: 3, row: 7)
            + TerminalMouse.sgr(.release, button: .right, col: 3, row: 7)
        #expect(text(click) == "\u{1b}[<2;4;8M\u{1b}[<2;4;8m")
    }
}
