import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct TerminalRunSplitterTests {

    private func split(
        _ cells: [(Character, Int, Bool)]
    ) -> [(text: String, attribute: Int, isCursor: Bool)] {
        TerminalRunSplitter.runs(cells: cells.map { (char: $0.0, attribute: $0.1, isCursor: $0.2) })
    }

    @Test func plainASCIICoalescesIntoOneRun() {
        let runs = split([("h", 1, false), ("e", 1, false), ("y", 1, false)])
        #expect(runs.count == 1)
        #expect(runs[0].text == "hey")
        #expect(!runs[0].isCursor)
    }

    @Test func anAttributeChangeStartsANewRun() {
        let runs = split([("a", 1, false), ("b", 2, false)])
        #expect(runs.map(\.text) == ["a", "b"])
        #expect(runs.map(\.attribute) == [1, 2])
    }

    @Test func theCursorCellIsAlwaysItsOwnRun() {
        let runs = split([("a", 1, false), ("b", 1, true), ("c", 1, false)])
        #expect(runs.map(\.text) == ["a", "b", "c"])
        #expect(runs.map(\.isCursor) == [false, true, false])
    }

    @Test func aFallbackGlyphIsIsolatedSoItsDriftCannotAccumulate() {
        // A nerd-font icon renders ~6pt wider than its cell; coalesced into a
        // text run it shifted every glyph after it, sliding the last typed
        // char under the cursor block. Isolated, the drift dies at its cell.
        let runs = split([("a", 1, false), ("\u{e0b0}", 1, false), ("b", 1, false)])
        #expect(runs.map(\.text) == ["a", "\u{e0b0}", "b"])
    }

    @Test func consecutiveFallbackGlyphsAreIsolatedIndividually() {
        // Grouping them would re-accumulate each glyph's drift.
        let runs = split([("❯", 1, false), ("❯", 1, false)])
        #expect(runs.map(\.text) == ["❯", "❯"])
    }

    @Test func aCursorOnAFallbackGlyphIsOneCursorRun() {
        let runs = split([("❯", 1, true)])
        #expect(runs.count == 1)
        #expect(runs[0].isCursor)
    }

    @Test func emptyInputYieldsNoRuns() {
        #expect(split([]).isEmpty)
    }

    @Test func boxDrawingAndBlockGlyphsStayCoalesced() {
        // Borders and progress bars repeat these for a full row; isolating each
        // cell would multiply the view count ~200x (the documented watchdog
        // crash was a render storm). Measured: every glyph in U+2500-259F has
        // exactly zero drift in the system monospaced font.
        let runs = split([("─", 1, false), ("─", 1, false), ("█", 1, false),
                          ("░", 1, false)])
        #expect(runs.count == 1)
        #expect(runs[0].text == "──█░")
    }

    @Test func brailleSpinnersAreStillIsolated() {
        // ⠋ measures +0.85pt of drift, so it does not join the safe range.
        let runs = split([("a", 1, false), ("⠋", 1, false), ("b", 1, false)])
        #expect(runs.map(\.text) == ["a", "⠋", "b"])
    }
}
