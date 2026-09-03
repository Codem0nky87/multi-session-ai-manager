import Testing
import Foundation
@testable import MultiSessionAIManager

@MainActor
final class TestTerminalFrameClock: TerminalFrameClock {
    private var action: (@MainActor () -> Void)?
    var onStop: (() -> Void)?

    private(set) var isRunning = false
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(_ action: @escaping @MainActor () -> Void) {
        guard !isRunning else { return }
        self.action = action
        isRunning = true
        startCount += 1
    }

    func stop() {
        guard isRunning else { return }
        action = nil
        isRunning = false
        stopCount += 1
        onStop?()
    }

    func fire() {
        action?()
    }
}

@MainActor
@Suite struct TerminalEmulatorTests {

    @Test func newlyCreatedTerminalIsIdle() {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(cols: 20, rows: 5, frameClock: clock)

        #expect(!clock.isRunning)
        #expect(!e.isRenderLoopRunning)
        #expect(clock.startCount == 0)
        #expect(e.coreCursorColumn == 0)
        #expect(e.lines.isEmpty)
        #expect(e.renderGeneration == 0)
    }

    @Test func burstFeedCoalescesIntoOneFrameAndPublishesRealTerminalState() async {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(cols: 20, rows: 5, frameClock: clock)

        e.feed(Data("a".utf8))
        e.feed(Data("b".utf8))
        e.feed(Data("c".utf8))

        #expect(e.coreCursorColumn == 0)
        #expect(e.lines.isEmpty)
        await Task.yield()
        #expect(clock.startCount == 1)
        #expect(clock.isRunning)

        clock.fire()

        #expect(e.coreCursorColumn == 3)
        #expect(e.visibleText() == "abc")
        #expect(!e.lines.isEmpty)
        #expect(e.renderGeneration == 1)
        #expect(!clock.isRunning)
        #expect(clock.stopCount == 1)
    }

    @Test func appendDuringFrameRetirementRestartsAndDrainsTheNextFrame() async {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(cols: 20, rows: 5, frameClock: clock)
        e.feed(Data("first".utf8))
        await Task.yield()

        clock.onStop = {
            clock.onStop = nil
            e.feed(Data("second".utf8))
        }
        clock.fire()

        #expect(e.coreCursorColumn == 5)
        #expect(e.visibleText() == "first")
        #expect(!clock.isRunning)
        await Task.yield()
        #expect(clock.startCount == 2)
        #expect(clock.isRunning)

        clock.fire()
        #expect(e.coreCursorColumn == 11)
        #expect(e.visibleText() == "firstsecond")
        #expect(e.renderGeneration == 2)
        #expect(!clock.isRunning)
        #expect(clock.stopCount == 2)
    }

    /// An off-screen emulator drains inbound bytes into the real terminal core,
    /// but never starts a frame or publishes SwiftUI rows.
    @Test func offscreenInputDrainsWithoutStartingAFrameOrPublishingRows() async {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(cols: 20, rows: 5, frameClock: clock)
        e.isVisible = false

        e.feed(Data("hello".utf8))
        await Task.yield()

        #expect(e.coreCursorColumn == 5)
        #expect(e.visibleText() == "hello")
        #expect(e.lines.isEmpty)
        #expect(e.renderGeneration == 0)
        #expect(clock.startCount == 0)
        #expect(!clock.isRunning)
    }

    @Test func hidingWithQueuedInputStopsTheFrameAndDrainsImmediately() async {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(cols: 20, rows: 5, frameClock: clock)
        e.feed(Data("pending".utf8))
        await Task.yield()
        #expect(clock.isRunning)
        #expect(e.coreCursorColumn == 0)

        e.isVisible = false

        #expect(!clock.isRunning)
        #expect(e.coreCursorColumn == 7)
        #expect(e.visibleText() == "pending")
        #expect(e.lines.isEmpty)
        #expect(e.renderGeneration == 0)
    }

    @Test func showingAHiddenTerminalRequestsOneFullViewportFrame() async {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(cols: 20, rows: 5, frameClock: clock)
        e.isVisible = false
        e.feed(Data("hello".utf8))
        await Task.yield()

        e.isVisible = true

        #expect(clock.startCount == 1)
        #expect(clock.isRunning)
        #expect(e.lines.isEmpty)
        clock.fire()
        #expect(e.lines.count == 5)
        #expect(e.visibleText() == "hello")
        #expect(e.renderGeneration == 1)
        #expect(!clock.isRunning)
        #expect(clock.stopCount == 1)
    }

    @Test func hiddenConfigurationChangesWaitForOneVisibleRepaint() {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(cols: 20, rows: 5, fontSize: 13, frameClock: clock)
        let oldCellWidth = e.fontMetrics.width
        let oldBackground = e.colorMap.background
        e.isVisible = false

        e.setFontSize(9)
        #expect(e.fontMetrics.width < oldCellWidth)
        #expect(clock.startCount == 0)
        #expect(e.lines.isEmpty)

        e.setTheme(.light)
        #expect(e.currentThemeID == TerminalTheme.light.id)
        #expect(e.colorMap.background != oldBackground)
        #expect(clock.startCount == 0)
        #expect(e.lines.isEmpty)

        e.resize(cols: 30, rows: 7)
        #expect(e.cols == 30)
        #expect(e.rows == 7)
        #expect(e.resizeGeneration == 1)
        #expect(clock.startCount == 0)
        #expect(e.lines.isEmpty)
        #expect(e.renderGeneration == 0)

        e.isVisible = true
        #expect(clock.startCount == 1)
        #expect(clock.isRunning)
        clock.fire()

        #expect(e.lines.count == 7)
        #expect(e.renderGeneration == 1)
        #expect(!clock.isRunning)
    }

    @Test func stoppedTerminalDiscardsPendingAndLateInputAndNeverRestarts() async {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(cols: 20, rows: 5, frameClock: clock)
        e.feed(Data("pending".utf8))
        await Task.yield()
        #expect(clock.isRunning)

        e.stop()
        e.stop()
        e.feed(Data("late".utf8))
        await Task.yield()
        clock.fire()

        #expect(!clock.isRunning)
        #expect(clock.startCount == 1)
        #expect(clock.stopCount == 1)
        #expect(e.coreCursorColumn == 0)
        #expect(e.lines.isEmpty)
        #expect(e.renderGeneration == 0)
    }

    @Test func setFontSizeSchedulesAndRepaintsRows() async {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(cols: 40, rows: 10, fontSize: 13, frameClock: clock)
        let w0 = e.fontMetrics.width
        e.feed(Data("hello".utf8))
        await Task.yield()
        clock.fire()
        let generation = e.renderGeneration
        let starts = clock.startCount

        e.setFontSize(9)
        #expect(e.fontMetrics.width < w0)
        #expect(clock.startCount == starts + 1)
        #expect(clock.isRunning)
        clock.fire()

        #expect(!e.lines.isEmpty)
        #expect(e.renderGeneration == generation + 1)
        #expect(!clock.isRunning)
    }

    @Test func setFontSizeSameValueIsNoOp() {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(cols: 40, rows: 10, fontSize: 13, frameClock: clock)
        let w0 = e.fontMetrics.width
        e.setFontSize(13)
        #expect(e.fontMetrics.width == w0)
        #expect(clock.startCount == 0)
        #expect(!clock.isRunning)
    }

    @Test func setThemeSchedulesAndRepaintsRows() async {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(cols: 40, rows: 10, frameClock: clock)
        e.feed(Data("hello".utf8))
        await Task.yield()
        clock.fire()
        let generation = e.renderGeneration
        let oldBackground = e.colorMap.background

        e.setTheme(.light)

        #expect(e.currentThemeID == TerminalTheme.light.id)
        #expect(e.colorMap.background != oldBackground)
        #expect(clock.isRunning)
        clock.fire()
        #expect(e.renderGeneration == generation + 1)
        #expect(!clock.isRunning)
    }

    /// A real geometry change bumps `resizeGeneration` so the view can react (the
    /// divider-handle refresh observes it); a no-op resize must NOT bump it.
    /// `selectedText` maps the renderer's scroll-invariant row index straight to
    /// `Terminal.getText`'s Position.row. On a fresh buffer (no scrollback trimming)
    /// the visible rows ARE the scroll-invariant rows, so a selection over a known
    /// string round-trips. End column is inclusive.
    @Test func selectedTextRoundTripsKnownString() async {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(cols: 40, rows: 6, frameClock: clock)
        e.feed(Data("COPYME".utf8))
        await Task.yield()
        clock.fire()
        // "COPYME" lives on the first rendered row (scroll-invariant row 0), cols 0..5.
        let s = e.selectedText(fromRow: 0, fromCol: 0, toRow: 0, toCol: 5)
        #expect(s.contains("COPYME"))
    }

    /// Start/end order is normalized: a backwards selection yields the same text.
    @Test func selectedTextNormalizesOrder() async {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(cols: 40, rows: 6, frameClock: clock)
        e.feed(Data("ABCDEF".utf8))
        await Task.yield()
        clock.fire()
        let forward = e.selectedText(fromRow: 0, fromCol: 0, toRow: 0, toCol: 5)
        let backward = e.selectedText(fromRow: 0, fromCol: 5, toRow: 0, toCol: 0)
        #expect(forward == backward)
        #expect(forward.contains("ABCDEF"))
    }

    /// After the scrollback fills and old lines are trimmed (linesTop > 0), a
    /// selection over a row that is STILL on-screen must still round-trip — proving
    /// the scroll-invariant→Position.row mapping holds once linesTop advances.
    @Test func selectedTextRoundTripsAfterScrollbackTrim() async {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(cols: 40, rows: 6, frameClock: clock)
        // Push well past the 1000-line scrollback so linesTop advances.
        for n in 0..<1100 {
            e.feed(Data("line\(n)\r\n".utf8))
        }
        e.feed(Data("FINDME".utf8))
        await Task.yield()
        #expect(clock.startCount == 1)
        clock.fire()
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

    @Test func visibleTextCopiesViewportAndTrimsTrailingBlankRows() async {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(cols: 20, rows: 5, frameClock: clock)
        e.feed(Data("first\r\nsecond".utf8))
        await Task.yield()
        clock.fire()

        #expect(e.visibleText() == "first\nsecond")
    }

    @Test func resizeBumpsGenerationOnlyWhenGeometryChanges() {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(cols: 40, rows: 10, frameClock: clock)
        let g0 = e.resizeGeneration
        e.resize(cols: 40, rows: 10)        // same size → no-op
        #expect(e.resizeGeneration == g0)
        #expect(clock.startCount == 0)
        e.resize(cols: 80, rows: 24)        // real change → bump
        #expect(e.resizeGeneration == g0 + 1)
        #expect(e.cols == 80 && e.rows == 24)
        #expect(clock.startCount == 1)
        #expect(clock.isRunning)
        clock.fire()
        #expect(e.lines.count == 24)
        #expect(e.renderGeneration == 1)
        #expect(!clock.isRunning)
    }
}
