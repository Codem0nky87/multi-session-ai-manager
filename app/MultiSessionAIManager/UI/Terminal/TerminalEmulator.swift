//
//  TerminalEmulator.swift
//  MultiSessionAIManager
//
//  The headless terminal controller. Owns SwiftTerm's *core* `Terminal` (NOT its
//  iOS `TerminalView`) and renders it to SwiftUI on a display-link timer, NewTerm
//  style: every frame, if the buffer is dirty, rebuild the visible rows from the
//  live buffer via `TerminalStringSupplier` and publish them. Because each frame
//  re-derives the rows from the authoritative buffer, erases / `clear` / redraws
//  always reflect correctly — the class of ghosting bugs that lived in the old
//  `TerminalView` UIKit draw path simply can't occur.
//
//  Concurrency: `@MainActor`. PTY output arrives OFF-main via `feed(_:)`, which
//  only appends to a lock-guarded byte buffer (no UIKit / Terminal access), so it
//  is safe to call from any thread. The display tick (main) drains that buffer
//  into the core `Terminal` and rebuilds the rows, preserving wire byte order.
//

import Foundation
import SwiftUI
import SwiftTerm
import QuartzCore

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
    @ObservationIgnored private var displayLink: CADisplayLink?

    /// When false (pane off-screen or its scene not foreground), the tick
    /// still DRAINS inbound bytes into the core terminal — keeping state and
    /// scrollback current — but SKIPS the expensive SwiftUI row rebuild.
    /// The accumulated dirty range is replayed when we become visible again.
    @ObservationIgnored var isVisible: Bool = true {
        didSet {
            guard isVisible != oldValue else { return }
            // Throttle the background drain when off-screen; full rate when visible.
            displayLink?.preferredFrameRateRange = isVisible
                ? .default
                : CAFrameRateRange(minimum: 5, maximum: 12, preferred: 8)
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

    init(cols: Int = 80, rows: Int = 24, fontSize: CGFloat = 13) {
        self.cols = max(cols, 1)
        self.rows = max(rows, 1)
        self.fontSize = fontSize
        self.fontMetrics = TerminalFontMetrics(fontSize: fontSize)

        let delegate = EmulatorDelegate()
        self.delegate = delegate

        let options = TerminalOptions(cols: self.cols,
                                      rows: self.rows,
                                      termName: "xterm-256color",
                                      scrollback: 1000)
        self.terminal = Terminal(delegate: delegate, options: options)

        stringSupplier.terminal = terminal
        stringSupplier.colorMap = colorMap
        stringSupplier.fontMetrics = fontMetrics

        // The delegate forwards core responses to whatever PTY is bound at the time.
        delegate.onSend = { [weak self] bytes in
            self?.pty?.send(Data(bytes))
        }
        startDisplayLink()
    }

    deinit {
        // Nothing to do here, and nothing that CAN be done: `displayLink` is
        // MainActor-isolated and deinit is nonisolated. The link's target is a
        // proxy holding this emulator WEAKLY, so it never kept us alive -- but a
        // still-scheduled link goes on waking the main thread every frame. It
        // now notices the emulator is gone on its next fire and invalidates
        // itself (see DisplayLinkProxy.tick), so a missed `stop()` costs one
        // frame rather than the life of the process.
    }

    // MARK: - Display timer

    private func startDisplayLink() {
        displayLink?.invalidate()
        let proxy = DisplayLinkProxy(emulator: self)
        let link = CADisplayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick))
        // So the link can retire itself once the emulator is gone -- see tick().
        proxy.link = link
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    /// Whether the CADisplayLink render loop is still scheduled. Internal (not
    /// private) so tests can prove a teardown path actually stopped it: a closed
    /// tab that skips `stop()` leaves a display link ticking for the life of the
    /// process, and nothing else observable distinguishes that from a clean tab.
    var isRenderLoopRunning: Bool { displayLink != nil }

    /// Stop the render loop. Call from the view's `onDisappear` to break the
    /// CADisplayLink retain cycle deterministically.
    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    /// One render frame: drain inbound bytes into the core terminal, then rebuild
    /// any dirty rows (plus the cursor's old/new rows) and republish.
    func tick() {
        // Drain inbound bytes (preserving order) and feed the core terminal.
        let pending = inbound.drain()
        if !pending.isEmpty {
            terminal.feed(byteArray: pending)
        }

        // Off-screen: core terminal is now current (drained above); skip the row
        // rebuild. Do NOT clear the update range — the accumulated dirty rows are all
        // rebuilt on the first tick after we become visible again.
        guard isVisible else { return }

        // A font-size change invalidates every laid-out row (the cell size changed):
        // repaint the whole viewport + scrollback wholesale this tick.
        if forceFullRebuild {
            forceFullRebuild = false
            let scrollbackRows = terminal.getTopVisibleRow()
            let total = scrollbackRows + terminal.rows
            terminal.clearUpdateRange()
            lines = (0..<total).map { stringSupplier.attributedString(forScrollInvariantRow: $0) }
            var cur = terminal.getCursorLocation(); cur.y += scrollbackRows
            lastCursorLocation = (cur.x, cur.y)
            renderGeneration &+= 1
            return
        }

        let scrollbackRows = terminal.getTopVisibleRow()
        var cursorLocation = terminal.getCursorLocation()
        cursorLocation.y += scrollbackRows

        let updateRange = terminal.getScrollInvariantUpdateRange() ?? (0, 0)
        if updateRange == (0, 0) && cursorLocation == lastCursorLocation {
            return // Nothing changed.
        }
        terminal.clearUpdateRange()

        let scrollInvariantRows = scrollbackRows + terminal.rows

        // Drop rows that no longer exist.
        if lines.count > scrollInvariantRows {
            lines.removeSubrange(scrollInvariantRows...)
        }
        // Grow to cover the dirty range / current viewport.
        let targetLineCount = max(updateRange.endY + 1, scrollInvariantRows)
        while lines.count < targetLineCount {
            lines.append(AnyView(EmptyView()))
        }

        // Compute the set of rows to re-render: the dirty range, plus the cursor's
        // old and new rows (so the cursor block moves cleanly).
        var linesToUpdate = updateRange == (0, 0) ? Set<Int>() : Set(updateRange.startY...updateRange.endY)
        if cursorLocation != lastCursorLocation {
            linesToUpdate.insert(cursorLocation.y)
            if lastCursorLocation.y != -1 && lastCursorLocation.y < scrollInvariantRows {
                linesToUpdate.insert(lastCursorLocation.y)
            }
        }

        for i in linesToUpdate where i >= 0 && i < lines.count {
            lines[i] = stringSupplier.attributedString(forScrollInvariantRow: i)
        }

        lastCursorLocation = cursorLocation
        renderGeneration &+= 1
    }

    // MARK: - Selection / copy

    /// Text for an inclusive rendered-cell range (rows are the scroll-invariant row
    /// indices used by the `lines` ForEach; cols are 0-based). Used for copy.
    ///
    /// The renderer's scroll-invariant row index is exactly the `Position.row` that
    /// `Terminal.getText` expects: `TerminalStringSupplier` renders row `i` via
    /// `getScrollInvariantLine(row: i)`. These are the same row indices accepted by
    /// `Terminal.getText`, so no further conversion is needed. We pass them through after
    /// normalizing start/end order. The end column is made inclusive (+1) so a
    /// single-cell selection still yields that cell's character.
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
        guard !filtered.isEmpty else { return }
        inbound.append(filtered)
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
        // Signal observers (e.g. the divider-handle refresh) that the geometry moved.
        resizeGeneration &+= 1
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

/// A thread-safe FIFO byte buffer for inbound PTY data. `feed` appends from the
/// off-main SSH callback; the main display tick drains it. The internal `NSLock`
/// makes all access safe, so this is genuinely `Sendable`.
private final class InboundBuffer: @unchecked Sendable {
    private var bytes = [UInt8]()
    private let lock = NSLock()

    func append(_ newBytes: [UInt8]) {
        lock.lock()
        bytes.append(contentsOf: newBytes)
        lock.unlock()
    }

    func drain() -> [UInt8] {
        lock.lock()
        defer { bytes.removeAll(keepingCapacity: true); lock.unlock() }
        return bytes
    }
}

/// CADisplayLink target. The link retains its target; this tiny proxy holds a weak
/// reference to the emulator so the link doesn't keep the emulator alive. It must
/// be an NSObject for the `@objc` selector.
private final class DisplayLinkProxy: NSObject {
    weak var emulator: TerminalEmulator?
    /// The link this proxy is the target of. Weak because the run loop owns it;
    /// a strong reference here would be a cycle the invalidation below is meant
    /// to avoid needing.
    weak var link: CADisplayLink?

    init(emulator: TerminalEmulator) { self.emulator = emulator }

    @MainActor @objc func tick() {
        guard let emulator else {
            // The emulator is gone but this link is still scheduled, so it keeps
            // waking the main thread every frame doing nothing. `stop()` is the
            // intended teardown, but it is a call somebody has to remember, and
            // a sheet dismissed by swipe never makes it. Left alone these
            // accumulate for the life of the process -- which is exactly the
            // "gets slower the longer it runs, fine after a restart" shape.
            //
            // A weak target cannot leak the emulator, but it also cannot stop
            // the timer; only the timer can. So it retires itself.
            link?.invalidate()
            return
        }
        emulator.tick()
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
