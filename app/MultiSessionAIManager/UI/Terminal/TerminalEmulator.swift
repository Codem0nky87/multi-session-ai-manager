//
//  TerminalEmulator.swift
//  MultiSessionAIManager
//
//  The headless terminal controller. Owns SwiftTerm's *core* `Terminal` (NOT its
//  iOS `TerminalView`) and renders it to SwiftUI on demand, NewTerm style: when
//  input or a viewport change makes the buffer dirty, rebuild the visible rows
//  from the live buffer via `TerminalStringSupplier` and publish them. Because each
//  frame re-derives the rows from the authoritative buffer, erases / `clear` /
//  redraws always reflect correctly — the class of ghosting bugs that lived in
//  the old `TerminalView` UIKit draw path simply can't occur.
//
//  Concurrency: `@MainActor`. PTY output arrives OFF-main via `feed(_:)`, which
//  only appends to a lock-guarded byte buffer (no UIKit / Terminal access), so it
//  is safe to call from any thread. A coalesced main-actor wake requests a temporary
//  display frame, which drains the buffer and rebuilds rows in wire byte order.
//

import Foundation
import SwiftUI
import SwiftTerm

enum TerminalHistoryPolicy: Equatable, Sendable {
    case hostOwned
    case local(limit: Int)

    var localLimit: Int {
        switch self {
        case .hostOwned:
            0
        case .local(let limit):
            max(limit, 0)
        }
    }
}

@MainActor
@Observable
final class TerminalEmulator {

    /// Published visible rows. The SwiftUI view observes this and re-lays-out when
    /// it changes. Each entry is one fully-rendered terminal row.
    private(set) var lines: [AnyView] = []

    /// Bumped whenever rendered row content changes, even if the row count stays the
    /// same. The scroll container uses this to keep following the tail while output
    /// repaints existing viewport rows.
    private(set) var renderGeneration = 0

    /// Current geometry, surfaced so callers can reuse it when re-attaching a PTY.
    @ObservationIgnored private(set) var cols: Int
    @ObservationIgnored private(set) var rows: Int

    /// The owner and bound for scrollback retained by this terminal core.
    @ObservationIgnored let history: TerminalHistoryPolicy
    @ObservationIgnored let localScrollbackLimit: Int

    /// Bumped every time `resize` changes geometry after a font, rotation, or
    /// display change.
    private(set) var resizeGeneration = 0

    /// Whether the core terminal is in application-cursor mode (DECCKM). Drives
    /// arrow-key escape selection in the key-input view.
    @ObservationIgnored var applicationCursor: Bool { terminal.applicationCursor }

    @ObservationIgnored private let terminal: Terminal
    @ObservationIgnored private let stringSupplier = TerminalStringSupplier()
    /// The active colour map. Swapped wholesale by `setTheme`; the view reads
    /// `colorMap.background` so the area outside text matches the theme.
    @ObservationIgnored private(set) var colorMap = TerminalColorMap()
    /// id of the currently-applied theme, so `setTheme` can no-op on a repeat. Exposed
    /// read-only (`currentThemeID`) so the picker can checkmark the active theme.
    @ObservationIgnored private var themeID: String = "dark"
    var currentThemeID: String { themeID }
    @ObservationIgnored private(set) var fontMetrics: TerminalFontMetrics

    /// Current render font size, in points. Mutated via `setFontSize`.
    @ObservationIgnored private var fontSize: CGFloat

    /// Set after a font-size change so the next tick repaints ALL rows: existing
    /// rows were laid out at the old cell size and must be rebuilt wholesale.
    @ObservationIgnored private var forceFullRebuild = false

    /// The PTY this emulator is bound to. `send` (core responses) and `resize`
    /// forward here. Weak: the session owns the PTY's lifetime.
    @ObservationIgnored weak var pty: PTYChannel?

    @ObservationIgnored private let delegate: EmulatorDelegate
    @ObservationIgnored private let frameClock: TerminalFrameClock
    @ObservationIgnored private var stopped = false

    /// When false (pane off-screen or its scene not foreground), inbound bytes
    /// still drain into the core terminal but no SwiftUI rows are produced.
    /// Showing the terminal requests one full viewport rebuild.
    @ObservationIgnored var isVisible: Bool = true {
        didSet {
            guard isVisible != oldValue else { return }
            guard !stopped else { return }
            if isVisible {
                forceFullRebuild = true
                lastCursorLocation = (-1, -1)
                requestFrame()
            } else {
                frameClock.stop()
                drainIntoCore()
            }
        }
    }

    /// The core terminal's current cursor column — advances as content is fed.
    /// Exposed so tests can prove the buffer stays current while off-screen.
    @ObservationIgnored var coreCursorColumn: Int { terminal.getCursorLocation().x }

    /// Inbound bytes from the PTY, appended off-main and drained on the main tick.
    /// The buffer is a self-synchronising `Sendable` box so `feed` (nonisolated)
    /// can append without violating actor isolation.
    @ObservationIgnored private let inbound = InboundBuffer()

    /// Last cursor position we rendered, so we can repaint the old + new cursor rows.
    @ObservationIgnored private var lastCursorLocation: (x: Int, y: Int) = (-1, -1)

    /// SwiftTerm's private `linesTop`, tracked so bounded buffer-relative UI rows
    /// can resolve through `getScrollInvariantLine(row:)` after ring recycling.
    @ObservationIgnored private var localScrollInvariantBase = 0

    init(
        cols: Int = 80,
        rows: Int = 24,
        fontSize: CGFloat = 13,
        history: TerminalHistoryPolicy = .local(limit: 1_000),
        frameClock: TerminalFrameClock = DisplayLinkTerminalFrameClock()
    ) {
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        self.fontSize = fontSize
        switch history {
        case .hostOwned:
            self.history = .hostOwned
        case .local:
            self.history = .local(limit: history.localLimit)
        }
        self.localScrollbackLimit = self.history.localLimit
        self.fontMetrics = TerminalFontMetrics(fontSize: fontSize)
        self.frameClock = frameClock

        let delegate = EmulatorDelegate()
        self.delegate = delegate

        let options = TerminalOptions(cols: self.cols,
                                      rows: self.rows,
                                      termName: "xterm-256color",
                                      scrollback: localScrollbackLimit)
        self.terminal = Terminal(delegate: delegate, options: options)
        if case .hostOwned = self.history {
            // SwiftTerm treats `some(0)` as scrollback-enabled. Disable it with
            // nil so the initial normal buffer does not advance `linesTop`.
            self.terminal.changeScrollback(nil)
        }

        stringSupplier.terminal = terminal
        stringSupplier.colorMap = colorMap
        stringSupplier.fontMetrics = fontMetrics

        // The delegate forwards core responses to whatever PTY is bound at the time.
        delegate.onSend = { [weak self] bytes in
            self?.pty?.send(Data(bytes))
        }
    }

    // MARK: - Demand-driven frame clock

    private func inboundBecameReady() {
        guard !stopped else { return }
        if isVisible {
            requestFrame()
        } else {
            drainIntoCore()
        }
    }

    private func requestFrame() {
        guard !stopped, isVisible, !frameClock.isRunning else { return }
        frameClock.start { [weak self] in
            self?.tick()
        }
    }

    private func drainIntoCore() {
        let pending = inbound.drain()
        if !pending.isEmpty {
            terminal.feed(byteArray: pending)
        }
    }

    /// Whether a temporary render frame is currently scheduled. Internal so
    /// lifecycle tests can distinguish an idle terminal from leaked work.
    var isRenderLoopRunning: Bool { frameClock.isRunning }

    /// Permanently retire the emulator. Pending input is discarded and later
    /// feeds are rejected, so a torn-down session cannot restart rendering.
    func stop() {
        guard !stopped else { return }
        stopped = true
        frameClock.stop()
        inbound.shutdown()
    }

    /// One requested render frame: drain inbound bytes into the core terminal,
    /// rebuild dirty rows, then retire the clock once the work has settled.
    func tick() {
        guard !stopped else {
            frameClock.stop()
            return
        }
        drainIntoCore()

        // A clock can fire just as the pane becomes hidden. Keep the core current,
        // but leave its dirty range intact for the forced rebuild when shown.
        guard isVisible else {
            frameClock.stop()
            return
        }

        let previousScrollInvariantBase = localScrollInvariantBase
        synchronizeLocalScrollInvariantBase()
        let rowAlignmentChanged = realignPublishedRows(from: previousScrollInvariantBase)

        defer {
            // If an off-main append races this frame after its drain, either this
            // check keeps the clock alive or its queued main-actor wake restarts it
            // after stop. In neither ordering can accepted bytes become stranded.
            if !inbound.hasPendingBytes && !forceFullRebuild {
                frameClock.stop()
            }
        }

        // A font-size change invalidates every laid-out row (the cell size changed):
        // repaint the whole viewport + scrollback wholesale this tick.
        if forceFullRebuild {
            forceFullRebuild = false
            let total = renderedRowCount
            terminal.clearUpdateRange()
            lines.removeAll(keepingCapacity: true)
            for row in 0..<total {
                guard let rendered = renderedLine(at: row) else {
                    assertionFailure("Missing terminal source row \(row)")
                    break
                }
                lines.append(rendered)
            }
            lastCursorLocation = rendererCursorLocation
            renderGeneration &+= 1
            return
        }

        let total = renderedRowCount
        let cursorLocation = rendererCursorLocation

        let updateRange = rendererUpdateRange
        if updateRange == nil && cursorLocation == lastCursorLocation && !rowAlignmentChanged {
            return // Nothing changed.
        }
        terminal.clearUpdateRange()

        // Drop rows that no longer exist.
        if lines.count > total {
            lines.removeSubrange(total...)
        }
        // Grow only from real source rows. A missing SwiftTerm row must not be
        // published as a successful-looking EmptyView placeholder.
        while lines.count < total {
            let row = lines.count
            guard let rendered = renderedLine(at: row) else {
                assertionFailure("Missing terminal source row \(row)")
                break
            }
            lines.append(rendered)
        }

        // Compute the set of rows to re-render: the dirty range, plus the cursor's
        // old and new rows (so the cursor block moves cleanly).
        var linesToUpdate = Set<Int>()
        if let updateRange, total > 0 {
            let start = max(updateRange.startY, 0)
            let end = min(updateRange.endY, total - 1)
            if start <= end {
                linesToUpdate.formUnion(start...end)
            }
        }
        if cursorLocation != lastCursorLocation {
            linesToUpdate.insert(cursorLocation.y)
            if lastCursorLocation.y != -1 && lastCursorLocation.y < total {
                linesToUpdate.insert(lastCursorLocation.y)
            }
        }

        for i in linesToUpdate where i >= 0 && i < lines.count {
            guard let rendered = renderedLine(at: i) else {
                assertionFailure("Missing terminal source row \(i)")
                continue
            }
            lines[i] = rendered
        }

        lastCursorLocation = cursorLocation
        renderGeneration &+= 1
    }

    /// The real source for a published UI row. Production rendering and tests use
    /// this same seam, so an unresolved SwiftTerm row cannot hide behind AnyView.
    func sourceRow(at row: Int) -> TerminalRowSource? {
        switch history {
        case .hostOwned:
            stringSupplier.sourceForViewportRow(row)
        case .local:
            stringSupplier.sourceForBufferRow(row, scrollInvariantBase: localScrollInvariantBase)
        }
    }

    private func renderedLine(at row: Int) -> AnyView? {
        sourceRow(at: row).map(stringSupplier.attributedString(for:))
    }

    private var renderedRowCount: Int {
        switch history {
        case .hostOwned:
            terminal.rows
        case .local:
            terminal.getTopVisibleRow() + terminal.rows
        }
    }

    private var rendererCursorLocation: (x: Int, y: Int) {
        var cursor = terminal.getCursorLocation()
        if case .local = history {
            cursor.y += terminal.getTopVisibleRow()
        }
        return cursor
    }

    private var rendererUpdateRange: (startY: Int, endY: Int)? {
        switch history {
        case .hostOwned:
            terminal.getUpdateRange()
        case .local:
            terminal.getScrollInvariantUpdateRange()
        }
    }

    /// Recover SwiftTerm's private `linesTop`. In this pinned SwiftTerm version it
    /// only advances as the ring recycles or resets to zero with a buffer reset.
    private func synchronizeLocalScrollInvariantBase() {
        guard case .local = history else { return }
        if terminal.getScrollInvariantLine(row: 0) != nil {
            localScrollInvariantBase = 0
            return
        }
        while terminal.getScrollInvariantLine(row: localScrollInvariantBase) == nil {
            localScrollInvariantBase &+= 1
        }
    }

    /// When the bounded local ring drops leading rows, retain the already-built
    /// views that still represent the same source rows and render only the new tail.
    @discardableResult
    private func realignPublishedRows(from previousBase: Int) -> Bool {
        guard case .local = history, localScrollInvariantBase != previousBase else {
            return false
        }
        guard localScrollInvariantBase > previousBase else {
            lines.removeAll(keepingCapacity: true)
            lastCursorLocation = (-1, -1)
            return true
        }

        let droppedRows = localScrollInvariantBase - previousBase
        lines.removeFirst(min(droppedRows, lines.count))
        if lastCursorLocation.y >= droppedRows {
            lastCursorLocation.y -= droppedRows
        } else {
            lastCursorLocation = (-1, -1)
        }
        return true
    }

    // MARK: - Selection / copy

    /// Text for an inclusive rendered-cell range (rows are the bounded,
    /// buffer-relative indices used by the `lines` ForEach; cols are 0-based).
    ///
    /// `Terminal.getText` expects the same buffer-relative row space. The supplier
    /// separately adds SwiftTerm's private `linesTop` only when resolving a local
    /// row for display. The end column is made inclusive (+1) so a single-cell
    /// selection still yields that cell's character.
    func selectedText(fromRow: Int, fromCol: Int, toRow: Int, toCol: Int) -> String {
        var startRow = fromRow, startCol = fromCol
        var endRow = toRow, endCol = toCol
        if endRow < startRow || (endRow == startRow && endCol < startCol) {
            swap(&startRow, &endRow)
            swap(&startCol, &endCol)
        }
        let start = Position(col: max(startCol, 0), row: max(startRow, 0))
        let end = Position(col: max(endCol, 0) + 1, row: max(endRow, 0))
        return terminal.getText(start: start, end: end)
    }

    /// Plain text for the currently visible terminal viewport. Used as a local copy
    /// fallback for a locally driven PTY.
    func visibleText() -> String {
        let top = terminal.getTopVisibleRow()
        var rowTexts: [String] = []
        rowTexts.reserveCapacity(terminal.rows)
        for r in 0..<terminal.rows {
            let text = terminal.getText(start: Position(col: 0, row: top + r),
                                        end: Position(col: cols, row: top + r))
                .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            rowTexts.append(text)
        }
        return rowTexts
            .joined(separator: "\n")
            .replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
    }

    // MARK: - I/O

    /// Feed inbound PTY bytes. Safe from any thread: only appends to a lock-guarded
    /// buffer; the main display tick drains it into the core terminal. Strips shell
    /// size-report query responses (`ESC[1{4,5,6,8,9}t`) so the shell never ingests
    /// them as literal text.
    nonisolated func feed(_ data: Data) {
        let filtered = TerminalEmulator.dropSizeReportQueries([UInt8](data))
        guard !filtered.isEmpty, inbound.append(filtered) else { return }
        Task { @MainActor [weak self] in
            self?.inboundBecameReady()
        }
    }

    /// Apply terminal bytes received from a Herdr pane-frame stream. This intentionally
    /// shares the same ordered, lock-guarded inbound path as PTY output without binding
    /// a local/SSH PTY or echoing the bytes back to the server.
    nonisolated func feedRemoteFrame(_ data: Data) {
        feed(data)
    }

    /// Send keyboard input straight to the PTY. The shell echoes it back through
    /// `feed`, so we deliberately do NOT feed it into the core terminal here.
    func feedInputToPTY(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        pty?.send(Data(bytes))
    }

    /// True when the core terminal is showing its alternate screen. While true,
    /// scroll gestures are sent to the remote application as mouse-wheel events.
    var isAlternateScreen: Bool { terminal.isCurrentBufferAlternate }

    /// Forward `count` scroll-wheel notches to the PTY at cell (`col`,`row`).
    /// Sends xterm wheel events to the active remote terminal application.
    func scrollWheel(up: Bool, count: Int, col: Int, row: Int) {
        guard isAlternateScreen, count > 0 else { return }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(count * 12)
        for _ in 0..<count {
            bytes += TerminalMouse.wheel(up: up, col: col, row: row)
        }
        feedInputToPTY(bytes)
    }

    /// Change the render font size: rebuild metrics + force a full row rebuild on the
    /// next tick (existing rows were laid out at the old cell size). The view re-derives
    /// cols/rows afterwards via applySize.
    func setFontSize(_ size: CGFloat) {
        guard size != fontSize else { return }
        fontSize = size
        fontMetrics = TerminalFontMetrics(fontSize: size)
        stringSupplier.fontMetrics = fontMetrics
        forceFullRebuild = true
        lastCursorLocation = (-1, -1)
        requestFrame()
    }

    /// Switch the terminal's colour theme: rebuild the colour map + force a full row
    /// rebuild on the next tick so every visible row repaints with the new colours
    /// (mirrors `setFontSize`). No-ops if the theme is already applied.
    func setTheme(_ theme: TerminalTheme) {
        guard theme.id != themeID else { return }
        themeID = theme.id
        colorMap = TerminalColorMap(theme: theme)
        stringSupplier.colorMap = colorMap
        forceFullRebuild = true
        lastCursorLocation = (-1, -1)
        requestFrame()
    }

    /// Resize the core terminal and the bound PTY.
    func resize(cols newCols: Int, rows newRows: Int) {
        let c = max(newCols, 1)
        let r = max(newRows, 1)
        guard c != cols || r != rows else { return }
        cols = c
        rows = r
        terminal.resize(cols: c, rows: r)
        pty?.resize(cols: c, rows: r)
        forceFullRebuild = true
        lastCursorLocation = (-1, -1)
        // Signal observers (e.g. the divider-handle refresh) that the geometry moved.
        resizeGeneration &+= 1
        requestFrame()
    }

    /// Strip xterm window size-report queries from a byte stream. Some shells echo
    /// the report bytes (`ESC[14t`, `ESC[15t`, `ESC[16t`, `ESC[18t`, `ESC[19t`) as
    /// literal input if they arrive before the PTY is fully wired; filtering them
    /// here prevents that garbage from landing on the command line.
    nonisolated static func dropSizeReportQueries(_ bytes: [UInt8]) -> [UInt8] {
        guard !bytes.isEmpty else { return bytes }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        let n = bytes.count
        while i < n {
            // Look for ESC [ 1 X t where X in {4,5,6,8,9}
            if bytes[i] == 0x1b, i + 4 < n,
               bytes[i + 1] == 0x5b, // [
               bytes[i + 2] == 0x31, // 1
               (bytes[i + 3] == 0x34 || bytes[i + 3] == 0x35 || bytes[i + 3] == 0x36 ||
                bytes[i + 3] == 0x38 || bytes[i + 3] == 0x39), // 4,5,6,8,9
               bytes[i + 4] == 0x74 { // t
                i += 5
                continue
            }
            out.append(bytes[i])
            i += 1
        }
        return out
    }
}

/// Pure drag-to-wheel-tick math for forwarding terminal scroll remotely.
/// Returns signed whole notches for a cumulative drag. Positive means the finger
/// moved down, which maps to wheel-up / older remote history.
enum TerminalScroll {
    static func ticks(forDelta delta: CGFloat, cellHeight: CGFloat) -> Int {
        guard cellHeight > 0 else { return 0 }
        return Int(delta / cellHeight)
    }

    /// ~16pt of pointer scroll per remote wheel notch. Scroll UP is a NEGATIVE
    /// pan translation, so the sign flips to the wheel's "up is positive".
    static let pointsPerWheelNotch: CGFloat = 16
    /// ~24pt of Shift+scroll per ±1pt of font size.
    static let pointsPerZoomStep: CGFloat = 24

    static func wheelTicks(forTranslation translation: CGFloat) -> Int {
        Int((-translation / pointsPerWheelNotch).rounded(.towardZero))
    }

    static func zoomSteps(forTranslation translation: CGFloat) -> CGFloat {
        (-translation / pointsPerZoomStep).rounded(.towardZero)
    }
}

/// A thread-safe FIFO byte buffer for inbound PTY data. It coalesces off-main
/// appends into one main-actor wake while preserving a wake for any append that
/// races after a drain.
private final class InboundBuffer: @unchecked Sendable {
    private var bytes = [UInt8]()
    private var wakeQueued = false
    private var acceptingInput = true
    private let lock = NSLock()

    func append(_ newBytes: [UInt8]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard acceptingInput else { return false }
        bytes.append(contentsOf: newBytes)
        guard !wakeQueued else { return false }
        wakeQueued = true
        return true
    }

    func drain() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        let drained = bytes
        bytes.removeAll(keepingCapacity: true)
        wakeQueued = false
        return drained
    }

    func shutdown() {
        lock.lock()
        acceptingInput = false
        wakeQueued = false
        bytes.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    var hasPendingBytes: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !bytes.isEmpty
    }
}

/// SwiftTerm `TerminalDelegate`. The only required method is `send` (core responses
/// such as cursor-position reports / DA replies). `onSend` is set by the emulator
/// to forward those bytes to the bound PTY.
///
/// `@unchecked Sendable`: `onSend` is only assigned once at init on the main actor
/// and only invoked synchronously by the core terminal during `feed`, which the
/// emulator drives on the main actor. No mutable shared state is touched off-main.
private final class EmulatorDelegate: NSObject, TerminalDelegate, @unchecked Sendable {
    var onSend: (([UInt8]) -> Void)?

    func send(source: Terminal, data: ArraySlice<UInt8>) {
        onSend?([UInt8](data))
    }

    func bell(source: Terminal) {}

    func isProcessTrusted(source: Terminal) -> Bool { false }
}
