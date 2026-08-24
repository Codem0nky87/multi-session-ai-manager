import Testing
import Foundation
@testable import MultiSessionAIManager

@MainActor
@Suite struct TerminalEmulatorTests {

    /// An off-screen emulator must keep DRAINING inbound bytes into the core
    /// terminal (so state/attention stay current) but must NOT rebuild the
    /// expensive SwiftUI rows until it becomes visible again.
    @Test func offscreenDrainsButDefersRowRebuild() {
        let e = TerminalEmulator(cols: 20, rows: 5)
        e.stop()                 // take manual control of ticks (no async display link)
        e.isVisible = false

        #expect(e.coreCursorColumn == 0)
        #expect(e.lines.isEmpty)

        e.feed(Data("hello".utf8))
        e.tick()                 // drains into the core terminal even though off-screen

        #expect(e.coreCursorColumn == 5)   // core terminal advanced → background-current
        #expect(e.lines.isEmpty)           // …but rows were NOT rebuilt while off-screen

        e.isVisible = true
        e.tick()                 // becoming visible replays the accumulated dirty range
        #expect(!e.lines.isEmpty)          // rows now rendered from the live buffer
    }

    /// While visible, a tick both drains and rebuilds (regression guard for the
    /// default path).
    @Test func visibleTickDrainsAndRebuilds() {
        let e = TerminalEmulator(cols: 20, rows: 5)
        e.stop()
        e.feed(Data("hi".utf8))
        e.tick()
        #expect(e.coreCursorColumn == 2)
        #expect(!e.lines.isEmpty)
    }

    @Test func setFontSizeRebuildsMetricsAndRows() {
        let e = TerminalEmulator(cols: 40, rows: 10, fontSize: 13); e.stop()
        let w0 = e.fontMetrics.width
        e.feed(Data("hello".utf8)); e.tick()
        e.setFontSize(9)
        #expect(e.fontMetrics.width < w0)   // metrics rebuilt smaller
        e.tick()                            // forceFullRebuild repaints
        #expect(!e.lines.isEmpty)
    }

    @Test func setFontSizeSameValueIsNoOp() {
        let e = TerminalEmulator(cols: 40, rows: 10, fontSize: 13); e.stop()
        let w0 = e.fontMetrics.width
        e.setFontSize(13)
        #expect(e.fontMetrics.width == w0)
    }

    /// A real geometry change bumps `resizeGeneration` so the view can react (the
    /// divider-handle refresh observes it); a no-op resize must NOT bump it.
    /// `selectedText` maps the renderer's scroll-invariant row index straight to
    /// `Terminal.getText`'s Position.row. On a fresh buffer (no scrollback trimming)
    /// the visible rows ARE the scroll-invariant rows, so a selection over a known
    /// string round-trips. End column is inclusive.
    @Test func selectedTextRoundTripsKnownString() {
        let e = TerminalEmulator(cols: 40, rows: 6); e.stop()
        e.feed(Data("COPYME".utf8)); e.tick()
        // "COPYME" lives on the first rendered row (scroll-invariant row 0), cols 0..5.
        let s = e.selectedText(fromRow: 0, fromCol: 0, toRow: 0, toCol: 5)
        #expect(s.contains("COPYME"))
    }

    /// Start/end order is normalized: a backwards selection yields the same text.
    @Test func selectedTextNormalizesOrder() {
        let e = TerminalEmulator(cols: 40, rows: 6); e.stop()
        e.feed(Data("ABCDEF".utf8)); e.tick()
        let forward = e.selectedText(fromRow: 0, fromCol: 0, toRow: 0, toCol: 5)
        let backward = e.selectedText(fromRow: 0, fromCol: 5, toRow: 0, toCol: 0)
        #expect(forward == backward)
        #expect(forward.contains("ABCDEF"))
    }

    /// After the scrollback fills and old lines are trimmed (linesTop > 0), a
    /// selection over a row that is STILL on-screen must still round-trip — proving
    /// the scroll-invariant→Position.row mapping holds once linesTop advances.
    @Test func selectedTextRoundTripsAfterScrollbackTrim() {
        let e = TerminalEmulator(cols: 40, rows: 6); e.stop()
        // Push well past the 1000-line scrollback so linesTop advances.
        for n in 0..<1100 {
            e.feed(Data("line\(n)\r\n".utf8))
        }
        e.feed(Data("FINDME".utf8))
        e.tick()
        // The renderer's last rendered row index is lines.count-1 (scroll-invariant).
        // "FINDME" is on the current cursor row = the last non-empty rendered row.
        let lastRow = e.lines.count - 1
        // Search the last few rows for the marker via selectedText to confirm mapping.
        var found = false
        for r in stride(from: lastRow, through: max(lastRow - 6, 0), by: -1) {
            if e.selectedText(fromRow: r, fromCol: 0, toRow: r, toCol: 39).contains("FINDME") {
                found = true; break
            }
        }
        #expect(found)
    }

    @Test func visibleTextCopiesViewportAndTrimsTrailingBlankRows() {
        let e = TerminalEmulator(cols: 20, rows: 5); e.stop()
        e.feed(Data("first\r\nsecond".utf8))
        e.tick()

        #expect(e.visibleText() == "first\nsecond")
    }

    @Test func resizeBumpsGenerationOnlyWhenGeometryChanges() {
        let e = TerminalEmulator(cols: 40, rows: 10); e.stop()
        let g0 = e.resizeGeneration
        e.resize(cols: 40, rows: 10)        // same size → no-op
        #expect(e.resizeGeneration == g0)
        e.resize(cols: 80, rows: 24)        // real change → bump
        #expect(e.resizeGeneration == g0 + 1)
        #expect(e.cols == 80 && e.rows == 24)
    }
}
