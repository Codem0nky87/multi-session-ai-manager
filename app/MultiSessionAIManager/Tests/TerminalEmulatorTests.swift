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

    @Test func negativeLocalHistoryLimitNormalizesToZero() {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(history: .local(limit: -1), frameClock: clock)

        #expect(e.history == .local(limit: 0))
        #expect(e.localScrollbackLimit == 0)
    }

    @Test func hostOwnedHistoryPublishesOnlyTheViewportAfterSustainedOutput() async {
        let rowCount = 5
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(
            cols: 20,
            rows: rowCount,
            history: .hostOwned,
            frameClock: clock
        )
        // RIS recreates SwiftTerm's normal buffer from options.scrollback. Its
        // options type cannot represent nil, so this also exercises the row-sized
        // ring after a remote reset has restored `some(0)` internally.
        let output = "\u{1b}c" + (0..<2_000).map { "line-\($0)\r\n" }.joined()

        e.feed(Data(output.utf8))
        await Task.yield()
        #expect(clock.startCount == 1)
        clock.fire()

        #expect(e.lines.count == rowCount)
        #expect(e.lines.map(\.plainText).joined(separator: "\n").contains("line-1999"))
        #expect(e.visibleText().contains("line-1999"))
    }

    @Test func hostOwnedRowsStayViewportRelativeAcrossAlternateScreenTransitions() async {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(cols: 30, rows: 5, history: .hostOwned, frameClock: clock)

        e.feed(Data("NORMAL-MARKER".utf8))
        await Task.yield()
        clock.fire()
        #expect(e.lines.contains { $0.plainText.contains("NORMAL-MARKER") })

        e.feed(Data("\u{1b}[?1049hALT-MARKER".utf8))
        await Task.yield()
        clock.fire()
        #expect(e.isAlternateScreen)
        #expect(e.lines.count == e.rows)
        #expect(e.lines.contains { $0.plainText.contains("ALT-MARKER") })

        e.feed(Data("\u{1b}[?1049l".utf8))
        await Task.yield()
        clock.fire()
        #expect(!e.isAlternateScreen)
        #expect(e.lines.count == e.rows)
        #expect(e.lines.contains { $0.plainText.contains("NORMAL-MARKER") })
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

    @Test func unchangedRowsRemainEqualAcrossADirtyRowUpdate() async {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(cols: 20, rows: 5, frameClock: clock)
        e.feed(Data("one\r\ntwo".utf8))
        await Task.yield()
        clock.fire()
        let before = e.lines

        e.feed(Data("!".utf8))
        await Task.yield()
        clock.fire()

        #expect(e.lines[0] == before[0])
        #expect(e.lines[1] != before[1])
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

    @Test func renderStyleGenerationChangesOnlyForRealStyleChanges() {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(cols: 40, rows: 10, fontSize: 13, frameClock: clock)

        #expect(e.renderStyleGeneration == 0)
        e.setFontSize(13)
        #expect(e.renderStyleGeneration == 0)
        e.setFontSize(12)
        #expect(e.renderStyleGeneration == 1)
        e.setFontSize(12)
        #expect(e.renderStyleGeneration == 1)
        e.setTheme(.dark)
        #expect(e.renderStyleGeneration == 1)
        e.setTheme(.light)
        #expect(e.renderStyleGeneration == 2)
        e.setTheme(.light)
        #expect(e.renderStyleGeneration == 2)
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
    /// `selectedText` and the renderer both use bounded, buffer-relative rows, so
    /// a selection over a known string round-trips. End column is inclusive.
    @Test func selectedTextRoundTripsKnownString() async {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(cols: 40, rows: 6, frameClock: clock)
        e.feed(Data("COPYME".utf8))
        await Task.yield()
        clock.fire()
        // "COPYME" lives on the first rendered row (buffer-relative row 0), cols 0..5.
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

    /// After the scrollback fills and old lines are trimmed, a selection over a
    /// retained buffer-relative row must still round-trip.
    @Test func selectedTextRoundTripsAfterScrollbackTrim() async {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(
            cols: 40,
            rows: 6,
            history: .local(limit: 1_000),
            frameClock: clock
        )
        // Push well past the 1000-line scrollback so the bounded ring recycles.
        for n in 0..<1100 {
            e.feed(Data("line\(n)\r\n".utf8))
        }
        e.feed(Data("FINDME".utf8))
        await Task.yield()
        #expect(clock.startCount == 1)
        clock.fire()
        #expect(e.lines.count > e.rows)
        #expect(e.lines.count <= e.rows + e.localScrollbackLimit)
        // The renderer's last rendered row index is lines.count-1 (buffer-relative).
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

    @Test func renderedRowsAndSelectionShareBufferRelativeCoordinatesAfterTrim() async throws {
        let clock = TestTerminalFrameClock()
        let e = TerminalEmulator(
            cols: 40,
            rows: 6,
            history: .local(limit: 1_000),
            frameClock: clock
        )
        for n in 0..<1_100 {
            e.feed(Data("line\(n)\r\n".utf8))
        }
        await Task.yield()
        clock.fire()

        let firstRenderedRow = try #require(e.lines.first)
        let selectedFirstRow = e.selectedText(
            fromRow: 0,
            fromCol: 0,
            toRow: 0,
            toCol: e.cols - 1
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(!firstRenderedRow.plainText.isEmpty)
        #expect(firstRenderedRow.plainText == selectedFirstRow)
        #expect(e.lines.count <= e.rows + e.localScrollbackLimit)
    }

    @Test func localRowsStayAlignedWhenTheRingRecyclesAcrossLaterFrames() async throws {
        let frameClock = TestTerminalFrameClock()
        let e = TerminalEmulator(
            cols: 40,
            rows: 4,
            history: .local(limit: 12),
            frameClock: frameClock
        )

        e.feed(Data((0..<30).map { "first-\($0)\r\n" }.joined().utf8))
        await Task.yield()
        frameClock.fire()
        let firstSourceBeforeRecycle = try #require(e.lines.first?.plainText)
        #expect(e.lines.count == e.rows + e.localScrollbackLimit)

        e.feed(Data((30..<40).map { "second-\($0)\r\n" }.joined().utf8))
        await Task.yield()
        frameClock.fire()
        e.feed(Data(((40..<50).map { "third-\($0)\r\n" }.joined() + "STAGED-LATEST").utf8))
        await Task.yield()
        frameClock.fire()

        let firstSourceAfterRecycle = try #require(e.lines.first?.plainText)
        let selectedFirstRow = e.selectedText(
            fromRow: 0,
            fromCol: 0,
            toRow: 0,
            toCol: e.cols - 1
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(firstSourceAfterRecycle != firstSourceBeforeRecycle)
        #expect(firstSourceAfterRecycle == selectedFirstRow)
        #expect(e.lines.count == e.rows + e.localScrollbackLimit)
        #expect(e.lines.contains { $0.plainText.contains("STAGED-LATEST") })
    }

    @Test func resetAndRetrimAfterAnEarlierTrimUsesCurrentBufferRelativeRows() async throws {
        let frameClock = TestTerminalFrameClock()
        let e = TerminalEmulator(
            cols: 40,
            rows: 4,
            history: .local(limit: 8),
            frameClock: frameClock
        )
        e.feed(Data((0..<80).map { "old-\($0)\r\n" }.joined().utf8))
        await Task.yield()
        frameClock.fire()

        let resetOutput = "\u{1b}c"
            + (0..<30).map { "reset-\($0)\r\n" }.joined()
            + "RESET-LATEST"
        e.feed(Data(resetOutput.utf8))
        await Task.yield()
        let elapsed = ContinuousClock().measure {
            frameClock.fire()
        }

        let firstSource = try #require(e.lines.first?.plainText)
        let selectedFirstRow = e.selectedText(
            fromRow: 0,
            fromCol: 0,
            toRow: 0,
            toCol: e.cols - 1
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(elapsed < .seconds(1))
        #expect(firstSource == selectedFirstRow)
        #expect(e.lines.count == e.rows + e.localScrollbackLimit)
        #expect(e.lines.contains { $0.plainText.contains("RESET-LATEST") })
    }

    @Test func localRowsStayBufferRelativeAcrossAlternateScreenTransitions() async throws {
        let frameClock = TestTerminalFrameClock()
        let e = TerminalEmulator(
            cols: 40,
            rows: 4,
            history: .local(limit: 8),
            frameClock: frameClock
        )
        let rowPadding = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)

        e.feed(Data(((0..<20).map { "normal-\($0)\r\n" }.joined() + "NORMAL-LATEST").utf8))
        await Task.yield()
        frameClock.fire()
        let normalRow = try #require(e.lines.firstIndex {
            $0.plainText.contains("NORMAL-LATEST")
        })
        #expect(e.lines[normalRow].plainText.trimmingCharacters(in: rowPadding)
            == e.selectedText(
            fromRow: normalRow,
            fromCol: 0,
            toRow: normalRow,
            toCol: e.cols - 1
        ).trimmingCharacters(in: .whitespacesAndNewlines))

        e.feed(Data("\u{1b}[?1049hALT-LATEST".utf8))
        await Task.yield()
        frameClock.fire()
        #expect(e.isAlternateScreen)
        let alternateRow = try #require(e.lines.firstIndex {
            $0.plainText.contains("ALT-LATEST")
        })
        let alternateSource = e.lines[alternateRow].plainText
            .trimmingCharacters(in: rowPadding)
        let alternateSelection = e.selectedText(
            fromRow: alternateRow,
            fromCol: 0,
            toRow: alternateRow,
            toCol: e.cols - 1
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(alternateSource == alternateSelection)

        e.feed(Data("\u{1b}[?1049l".utf8))
        await Task.yield()
        frameClock.fire()
        #expect(!e.isAlternateScreen)
        let restoredRow = try #require(e.lines.firstIndex {
            $0.plainText.contains("NORMAL-LATEST")
        })
        #expect(e.lines[restoredRow].plainText.trimmingCharacters(in: rowPadding)
            == e.selectedText(
            fromRow: restoredRow,
            fromCol: 0,
            toRow: restoredRow,
            toCol: e.cols - 1
        ).trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(e.lines.count <= e.rows + e.localScrollbackLimit)
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
