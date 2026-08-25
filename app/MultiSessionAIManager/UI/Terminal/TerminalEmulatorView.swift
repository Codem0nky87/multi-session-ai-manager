//
//  TerminalEmulatorView.swift
//  MultiSessionAIManager
//
//  The SwiftUI terminal renderer that replaces the old SwiftTerm-`TerminalView`
//  container. It draws the emulator's published rows in a scrolling VStack
//  (auto-scrolling to the bottom), derives the terminal geometry (cols/rows) from
//  its frame using the font's cell metrics, and overlays a transparent
//  `TerminalKeyInputView` so the software/hardware keyboard types into the PTY.
//  Tapping the terminal focuses the key input.
//

import SwiftUI
import UIKit

struct TerminalEmulatorView: View {
    @Bindable var emulator: TerminalEmulator

    /// Optional bottom inset for a surrounding shell overlay.
    var bottomInset: CGFloat = 0
    /// Called from the terminal's own tap recognizer so pane focus does not need a
    /// parent tap gesture competing with the ScrollView's pan recognizer.
    var onTap: () -> Void = {}
    /// False while Herdr is reconnecting/synchronizing. The first responder resigns
    /// immediately and every callback is guarded independently.
    var inputEnabled = true
    /// Optional Herdr transport hooks. Nil preserves local PTY behavior.
    var onInputBytes: (([UInt8]) -> Void)? = nil
    var onRemoteScroll: ((Bool, Int) -> Void)? = nil
    var onGridChange: ((Int, Int) -> Void)? = nil
    var forwardsPointerClicks = true
    /// Existing local terminals focus on appearance. Remote Herdr panes opt out so
    /// launching the shell never covers its workspace with the software keyboard.
    var automaticallyFocusesInput = true
    /// Herdr pane runtimes provide a stable controller so first-responder intent
    /// survives SwiftUI replacing the compact and desktop presentation trees.
    var inputController: KeyInputController? = nil
    /// Modal text selection, shared with the app's top bar. While selecting, a
    /// plain drag selects instead of scrolling, touches stop reaching the remote
    /// pane, and the keyboard is not raised -- see `TerminalTouchPolicy`.
    var selection: TerminalSelectionModel? = nil

    /// Shared terminal appearance — drives the live render font size.
    @Environment(TerminalSettings.self) private var settings

    @State private var localKeyInputController = KeyInputController()

    private var resolvedInputController: KeyInputController {
        inputController ?? localKeyInputController
    }

    /// Latest measured geometry, so a font-size change can re-derive cols/rows
    /// without waiting for the next GeometryReader update.
    @State private var lastSize: CGSize = .zero

    /// True while the tail is visible (the user is "following" output). Set false
    /// when they scroll up, so new output stops auto-scrolling them back down.
    @State private var atBottom = true

    /// Effective font size captured at the start of a pinch, so the live scale is
    /// applied relative to where the gesture began (not compounded each tick).
    @State private var pinchStartSize: CGFloat? = nil

    /// Selection anchors in renderer cell coordinates: `row` is the scroll-invariant
    /// row index (same index as `emulator.lines` / the row passed to `selectedText`),
    /// `col` is the 0-based cell. Both nil = no active selection. Set by a
    /// long-press-then-drag inside the scroll content (so plain drags still scroll).
    /// Set by the scroll container so the selection drag can auto-scroll. Takes a
    /// signed point delta and returns how far it actually moved (0 at the ends).
    @State private var autoScroll: ((CGFloat) -> CGFloat)? = nil
    /// Viewport height, for edge-proximity. Reported by the container.
    @State private var viewportHeight: CGFloat = 0
    /// Drives the auto-scroll repeat while the drag is held near an edge.
    @State private var autoScrollTimer: Timer? = nil
    /// Latest drag point in VIEWPORT coordinates (the gesture reports content
    /// coordinates, which move as we scroll).
    @State private var lastDragViewportY: CGFloat = 0
    /// Live scroll offset, so viewport points can be converted to content points.
    @State private var currentScrollOffset: CGFloat = 0

    @State private var selStart: (col: Int, row: Int)? = nil
    @State private var selEnd: (col: Int, row: Int)? = nil

    /// The terminal area background, taken from the emulator's CURRENT theme so the
    /// region outside the glyph rows (and the per-row tile fill) matches the active
    /// palette. Recomputed on each render, so a `setTheme` repaints the backdrop too.
    private var backgroundColor: Color { Color(emulator.colorMap.background) }

    private var selecting: Bool { selection?.isSelecting ?? false }

    var body: some View {
        GeometryReader { geometry in
            TerminalScrollContainer(
                backgroundColor: emulator.colorMap.background,
                followsBottom: atBottom,
                scrollVersion: emulator.renderGeneration,
                isAltScreen: emulator.isAlternateScreen,
                cellSize: emulator.fontMetrics.boundingBox,
                scrollEnabled: TerminalTouchPolicy.scrollEnabled(isSelecting: selecting),
                onScrollHandle: { scroller, height in
                    autoScroll = scroller
                    viewportHeight = height
                },
                onScrollOffsetChange: { currentScrollOffset = $0 },
                onBottomStateChange: { atBottom = $0 },
                onTap: { location in handleTerminalTap(at: location) },
                onSecondaryTap: { location in handleTerminalSecondaryClick(at: location) },
                onScrollWheel: { up, count, location in
                    if let onRemoteScroll {
                        guard inputEnabled else { return }
                        onRemoteScroll(up, count)
                        return
                    }
                    let glyph = emulator.fontMetrics.boundingBox
                    let c = TerminalMouse.cell(x: location.x, y: location.y,
                                               cellWidth: glyph.width, cellHeight: glyph.height)
                    emulator.scrollWheel(up: up, count: count, col: c.col, row: c.row)
                },
                onZoom: { step, persist in
                    settings.setFontSize(settings.fontSize + step, persist: persist)
                }
            ) {
                scrollContent
            }
            .background(backgroundColor)
            .coordinateSpace(name: Self.viewportSpace)
            .onChange(of: selection?.copyRequest ?? 0) { _, _ in
                copySelection()
            }
            .onAppear {
                emulator.isVisible = true
                // Font size FIRST so cols/rows are derived from the new cell metrics.
                emulator.setFontSize(settings.fontSize)
                applySize(geometry.size)
                DispatchQueue.main.async {
                    if inputEnabled, automaticallyFocusesInput { resolvedInputController.focus() }
                }
            }
            .onChange(of: geometry.size) { _, newSize in applySize(newSize) }
            // The scroll view's own bounds are the only honest measure of how
            // many rows can actually be SEEN. Re-derive the grid whenever it
            // reports a new height, or the remote keeps drawing rows into space
            // this view was allotted but does not display.
            .onChange(of: viewportHeight) { _, _ in applySize(lastSize) }
            .onChange(of: settings.fontSize) { _, newSize in
                emulator.setFontSize(newSize)
                applySize(lastSize)
            }
            .onChange(of: inputEnabled) { _, enabled in
                if !enabled {
                    resolvedInputController.blur()
                } else if automaticallyFocusesInput {
                    resolvedInputController.focus()
                }
            }
        }
        .background(backgroundColor)
        .overlay(
            // Transparent key-input layer underneath the visible glyphs. It captures
            // keyboard input; a tap focuses it.
            KeyInputRepresentable(controller: resolvedInputController,
                                  onInput: routeInput,
                                  applicationCursorProvider: { emulator.applicationCursor })
        )
        .contentShape(Rectangle())
        // Pinch to fine-tune the font size. Runs simultaneously with scroll + the tap
        // gesture. We scale from the size captured at gesture start and commit the
        // persisted delta once on end (live changes don't hammer UserDefaults).
        .simultaneousGesture(
            MagnificationGesture()
                .onChanged { value in
                    let start = pinchStartSize ?? settings.fontSize
                    if pinchStartSize == nil { pinchStartSize = start }
                    settings.setFontSize(start * value, persist: false)
                }
                .onEnded { _ in
                    settings.setFontSize(settings.fontSize, persist: true)
                    pinchStartSize = nil
                }
        )
        .onDisappear { emulator.isVisible = false }
    }

    // MARK: - Text selection + copy

    @ViewBuilder
    private var scrollContent: some View {
        if selecting {
            rowsContent
                // Selection highlight, drawn in the SAME (scroll-content) coordinate
                // space the cell mapping uses, so rects line up with the glyphs.
                .overlay(alignment: .topLeading) { selectionHighlight }
                .gesture(selectionGesture)
        } else {
            rowsContent
        }
    }

    private var rowsContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(zip(emulator.lines, emulator.lines.indices)), id: \.1) { line, i in
                line
                    // Pin each row to the exact (whole-point) cell height and fill
                    // it with the terminal background BEFORE rasterizing. The glyph
                    // runs paint no background of their own, so without this the
                    // `drawingGroup(opaque:)` tile fills transparent pixels with
                    // black while the parent shows the near-black bg — producing
                    // faint horizontal seams between rows at small font sizes.
                    // Painting the bg into each integer-height tile makes the rows
                    // tile seamlessly. `.topLeading` keeps glyphs from being
                    // vertically clipped.
                    .frame(maxWidth: .infinity,
                           minHeight: emulator.fontMetrics.boundingBox.height,
                           maxHeight: emulator.fontMetrics.boundingBox.height,
                           alignment: .topLeading)
                    .background(backgroundColor)
                    .drawingGroup(opaque: true)
                    .id(i)
            }
            // Invisible bottom anchor. While it's on-screen the user is
            // "following" the tail, so new output auto-scrolls; once they
            // scroll up it leaves the viewport and we STOP yanking them
            // back down. Its height is real and is subtracted by
            // `TerminalGridSizing.rows` -- see the note there.
            Color.clear.frame(height: TerminalGridSizing.bottomAnchorHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, bottomInset)
    }

    /// Long-press (0.35s) THEN drag to select. The long-press requirement is what keeps
    /// a plain one-finger drag scrolling the ScrollView — only once the press has been
    /// held does the drag start extending a selection. Both anchors are renderer cell
    /// coordinates (scroll-invariant row + 0-based col), so they feed `selectedText`
    /// directly. The drag location is in the scroll-content space (this gesture is on
    /// the VStack), so `cellAt` maps it to a row that matches `emulator.lines`.
    private var selectionGesture: some Gesture {
        // A PLAIN drag: scrolling is disabled while selecting, so there is no
        // pan recognizer left to disambiguate against and no long-press needed.
        // Holding the drag near an edge auto-scrolls, so a selection can run
        // past what is currently on screen.
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.viewportSpace))
            .onChanged { drag in
                lastDragViewportY = drag.location.y
                extendSelection(toContentPoint: drag.startLocation, current: drag.location)
                startAutoScrollIfNeeded()
            }
            .onEnded { _ in stopAutoScroll() }
    }

    static let viewportSpace = "terminal.viewport"

    /// Anchor once at the press point, then track the finger. Both are viewport
    /// points; `cellAt` converts using the live scroll offset, so a row revealed
    /// by auto-scroll maps correctly even though the finger has not moved.
    private func extendSelection(toContentPoint start: CGPoint, current: CGPoint) {
        if selStart == nil { selStart = cellAtViewport(start) }
        selEnd = cellAtViewport(current)
        selection?.setHasSelection(true)
    }

    /// Repeat while the drag is held in an edge zone. A timer rather than
    /// per-drag-event work: a stationary finger at the edge emits no further
    /// drag events, but must keep scrolling.
    private func startAutoScrollIfNeeded() {
        guard autoScrollTimer == nil else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            Task { @MainActor in stepAutoScroll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoScrollTimer = timer
    }

    private func stepAutoScroll() {
        let delta = TerminalSelectionAutoScroll.velocity(
            atY: lastDragViewportY, viewportHeight: viewportHeight
        )
        guard delta != 0, let autoScroll, autoScroll(delta) != 0 else { return }
        // the finger has not moved, but the content under it has
        selEnd = cellAtViewport(CGPoint(x: 0, y: lastDragViewportY))
    }

    private func stopAutoScroll() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
    }

    /// Map a VIEWPORT point to a renderer cell, adding the live scroll offset so a
    /// row revealed by auto-scroll resolves correctly under a stationary finger.
    private func cellAtViewport(_ point: CGPoint) -> (col: Int, row: Int) {
        cellAt(CGPoint(x: point.x, y: point.y + currentScrollOffset))
    }

    /// Map a point in the scroll-content coordinate space to a renderer cell. Row is
    /// `floor(y / cellHeight)` which equals the `emulator.lines` index (each row is
    /// pinned to exactly `boundingBox.height`), so it matches `selectedText`'s rows.
    private func cellAt(_ point: CGPoint) -> (col: Int, row: Int) {
        let glyph = emulator.fontMetrics.boundingBox
        guard glyph.width > 0, glyph.height > 0 else { return (0, 0) }
        let col = max(Int((point.x / glyph.width).rounded(.down)), 0)
        let row = max(Int((point.y / glyph.height).rounded(.down)), 0)
        return (col, min(row, max(emulator.lines.count - 1, 0)))
    }

    /// The selection highlight, in scroll-content coordinates. Single row → one rect;
    /// multi-row → text-flow shape (first row start→end-of-line, full middle rows, last
    /// row start→end col). Empty when there's no selection.
    @ViewBuilder
    private var selectionHighlight: some View {
        if let start = selStart, let end = selEnd {
            let glyph = emulator.fontMetrics.boundingBox
            let cols = max(emulator.cols, 1)
            // Normalize so `a` is before `b` in reading order.
            let (a, b) = ordered(start, end)
            let rects = selectionRects(a: a, b: b, cols: cols, glyph: glyph)
            ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
                Rectangle()
                    .fill(Theme.accent.opacity(0.3))
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
    }

    /// Order two cells in reading order (row-major).
    private func ordered(_ p: (col: Int, row: Int), _ q: (col: Int, row: Int)) -> ((col: Int, row: Int), (col: Int, row: Int)) {
        if q.row < p.row || (q.row == p.row && q.col < p.col) { return (q, p) }
        return (p, q)
    }

    /// Highlight rects for an ordered selection `a`→`b` (text-flow shape).
    private func selectionRects(a: (col: Int, row: Int), b: (col: Int, row: Int),
                                cols: Int, glyph: CGSize) -> [CGRect] {
        let w = glyph.width, h = glyph.height
        func rowRect(row: Int, fromCol: Int, toCol: Int) -> CGRect {
            let lo = min(fromCol, toCol), hi = max(fromCol, toCol)
            return CGRect(x: CGFloat(lo) * w, y: CGFloat(row) * h,
                          width: CGFloat(hi - lo + 1) * w, height: h)
        }
        if a.row == b.row {
            return [rowRect(row: a.row, fromCol: a.col, toCol: b.col)]
        }
        var rects: [CGRect] = []
        rects.append(rowRect(row: a.row, fromCol: a.col, toCol: cols - 1))   // first row → EOL
        if b.row - a.row > 1 {
            // Full middle rows as one block.
            rects.append(CGRect(x: 0, y: CGFloat(a.row + 1) * h,
                                width: CGFloat(cols) * w, height: CGFloat(b.row - a.row - 1) * h))
        }
        rects.append(rowRect(row: b.row, fromCol: 0, toCol: b.col))          // last row start → end
        return rects
    }

    /// Floating Copy / clear control, shown only while a selection exists. Pinned
    /// top-trailing of the terminal so it never covers the selection itself.
    private func copySelection() {
        guard let start = selStart, let end = selEnd else { return }
        let text = emulator.selectedText(fromRow: start.row, fromCol: start.col,
                                         toRow: end.row, toCol: end.col)
        UIPasteboard.general.string = text
        clearSelection()
        selection?.exit()
    }

    private func clearSelection() {
        selStart = nil
        selEnd = nil
        selection?.setHasSelection(false)
    }

    /// A tap focuses the keyboard and optionally forwards a left-button click to
    /// the remote pane. The recognizer coexists with the scroll view's pan gesture.
    private func handleTerminalTap(at location: CGPoint) {
        guard !selecting else {
            // a tap outside the selection clears it, rather than being forwarded
            clearSelection()
            return
        }
        onTap()
        clearSelection()
        if TerminalTouchPolicy.focusesKeyboard(isSelecting: selecting, inputEnabled: inputEnabled) {
            resolvedInputController.focus()
        }

        guard inputEnabled, forwardsPointerClicks else { return }
        let glyph = emulator.fontMetrics.boundingBox
        let c = TerminalMouse.cell(x: location.x, y: location.y,
                                   cellWidth: glyph.width, cellHeight: glyph.height)
        // A click is a press then release at the same terminal cell.
        routeInput(TerminalMouse.sgr(.press, col: c.col, row: c.row)
                   + TerminalMouse.sgr(.release, col: c.col, row: c.row))
    }

    /// Forward a right-click so the remote can raise its own context menu.
    ///
    /// Sent as SGR button 2 rather than being turned into an app-side menu: the
    /// menu belongs to whatever is running in the pane, and it is the only thing
    /// that knows what the entries should be.
    private func handleTerminalSecondaryClick(at location: CGPoint) {
        guard !selecting else {
            clearSelection()
            return
        }
        guard inputEnabled, forwardsPointerClicks else { return }
        let glyph = emulator.fontMetrics.boundingBox
        let c = TerminalMouse.cell(x: location.x, y: location.y,
                                   cellWidth: glyph.width, cellHeight: glyph.height)
        routeInput(TerminalMouse.sgr(.press, button: .right, col: c.col, row: c.row)
                   + TerminalMouse.sgr(.release, button: .right, col: c.col, row: c.row))
    }

    private func applySize(_ size: CGSize) {
        lastSize = size
        let glyph = emulator.fontMetrics.boundingBox
        guard glyph.width > 0, glyph.height > 0 else { return }
        let cols = TerminalGridSizing.columns(viewportWidth: size.width, cellWidth: glyph.width)
        // Rows come from the SCROLL VIEW's bounds, not from `size` -- this view's
        // allotted frame can be taller than the area the scroll view actually
        // shows (safe-area expansion, clipping by an ancestor). Sizing from the
        // allotted frame told the remote it had more rows than we could draw, so
        // it drew them, the content overflowed, and following the tail scrolled
        // the top rows -- Herdr's tab bar and pane labels -- out of sight.
        let visibleHeight = viewportHeight > 0 ? viewportHeight : size.height
        let rows = TerminalGridSizing.rows(
            viewportHeight: visibleHeight,
            bottomInset: bottomInset,
            cellHeight: glyph.height
        )
        if let onGridChange {
            onGridChange(cols, rows)
        } else {
            emulator.resize(cols: cols, rows: rows)
        }
    }

    private func routeInput(_ bytes: [UInt8]) {
        guard inputEnabled, !bytes.isEmpty else { return }
        if let onInputBytes {
            onInputBytes(bytes)
        } else {
            emulator.feedInputToPTY(bytes)
        }
    }
}

/// A UIKit scroll host for the terminal body.
///
/// The terminal rows are still rendered with SwiftUI, but direct touch scrolling is
/// owned by `UIScrollView`. This avoids gesture arbitration problems between
/// SwiftUI's scroll view, terminal overlays, and keyboard focus layers on iPad.
private struct TerminalScrollContainer<Content: View>: UIViewControllerRepresentable {
    let backgroundColor: UIColor
    let followsBottom: Bool
    let scrollVersion: Int
    let isAltScreen: Bool
    let cellSize: CGSize
    let scrollEnabled: Bool
    let onScrollHandle: ((@escaping (CGFloat) -> CGFloat), CGFloat) -> Void
    let onScrollOffsetChange: (CGFloat) -> Void
    let onBottomStateChange: (Bool) -> Void
    let onTap: (CGPoint) -> Void
    let onSecondaryTap: (CGPoint) -> Void
    let onScrollWheel: (Bool, Int, CGPoint) -> Void
    /// `(step, persist)` — apply a font-size delta from Shift+wheel; `persist`
    /// is true only on gesture end.
    let onZoom: (CGFloat, Bool) -> Void
    @ViewBuilder let content: () -> Content

    func makeCoordinator() -> Coordinator {
        Coordinator(onBottomStateChange: onBottomStateChange,
                    onTap: onTap,
                    onSecondaryTap: onSecondaryTap,
                    onScrollWheel: onScrollWheel,
                    onZoom: onZoom)
    }

    func makeUIViewController(context: Context) -> Controller<Content> {
        let controller = Controller(rootView: content(), coordinator: context.coordinator)
        controller.update(backgroundColor: backgroundColor,
                          followsBottom: followsBottom,
                          scrollVersion: scrollVersion,
                          isAltScreen: isAltScreen,
                          cellSize: cellSize)
        return controller
    }

    func updateUIViewController(_ controller: Controller<Content>, context: Context) {
        context.coordinator.onBottomStateChange = onBottomStateChange
        context.coordinator.onTap = onTap
        context.coordinator.onSecondaryTap = onSecondaryTap
        context.coordinator.onScrollWheel = onScrollWheel
        context.coordinator.onZoom = onZoom
        context.coordinator.isAltScreen = isAltScreen
        context.coordinator.cellSize = cellSize
        controller.hostingController.rootView = content()
        controller.scrollView.isScrollEnabled = scrollEnabled
        // Separate recognizer, separate switch: this one forwards drags to the
        // remote as wheel events while the alternate screen is up (a TUI has no
        // app-side scrollback). Leaving it enabled meant a selection drag
        // scrolled Herdr instead of selecting.
        controller.directScrollRecognizer?.isEnabled = scrollEnabled
        let scrollView = controller.scrollView
        onScrollHandle({ delta in
            let maximum = scrollView.contentSize.height - scrollView.bounds.height
            let before = scrollView.contentOffset.y
            let after = TerminalSelectionAutoScroll.clampedOffset(
                current: before, delta: delta, maximum: maximum
            )
            guard after != before else { return 0 }
            scrollView.contentOffset.y = after
            return after - before
        }, scrollView.bounds.height)
        controller.update(backgroundColor: backgroundColor,
                          followsBottom: followsBottom,
                          scrollVersion: scrollVersion,
                          isAltScreen: isAltScreen,
                          cellSize: cellSize)
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var onBottomStateChange: (Bool) -> Void
        var onTap: (CGPoint) -> Void
        var onSecondaryTap: (CGPoint) -> Void
        var onScrollWheel: (Bool, Int, CGPoint) -> Void
        var onZoom: (CGFloat, Bool) -> Void
        var isAltScreen = false
        var cellSize: CGSize = .zero
        var isUserInteracting = false
        weak var directScrollRecognizer: UIPanGestureRecognizer?
        weak var wheelRecognizer: UIPanGestureRecognizer?
        private var directScrollSentTicks = 0
        private var wheelSentTicks = 0
        private var zoomSentSteps: CGFloat = 0

        init(onBottomStateChange: @escaping (Bool) -> Void,
             onTap: @escaping (CGPoint) -> Void,
             onSecondaryTap: @escaping (CGPoint) -> Void,
             onScrollWheel: @escaping (Bool, Int, CGPoint) -> Void,
             onZoom: @escaping (CGFloat, Bool) -> Void) {
            self.onBottomStateChange = onBottomStateChange
            self.onTap = onTap
            self.onSecondaryTap = onSecondaryTap
            self.onScrollWheel = onScrollWheel
            self.onZoom = onZoom
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isUserInteracting = true
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard isUserInteracting else { return }
            guard scrollView.hasScrollableContent else { return }
            onBottomStateChange(scrollView.isAtBottom)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { finishUserScroll(scrollView) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            finishUserScroll(scrollView)
        }

        private func finishUserScroll(_ scrollView: UIScrollView) {
            isUserInteracting = false
            guard scrollView.hasScrollableContent else {
                onBottomStateChange(true)
                return
            }
            onBottomStateChange(scrollView.isAtBottom)
        }

        @objc func handleSecondaryTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            onSecondaryTap(recognizer.location(in: view))
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view else { return }
            onTap(recognizer.location(in: view))
        }

        @objc func handleDirectScroll(_ recognizer: UIPanGestureRecognizer) {
            guard isAltScreen, let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                directScrollSentTicks = 0
            case .changed:
                let signedTicks = TerminalScroll.ticks(
                    forDelta: recognizer.translation(in: view).y,
                    cellHeight: cellSize.height)
                let delta = signedTicks - directScrollSentTicks
                guard delta != 0 else { return }
                directScrollSentTicks = signedTicks
                onScrollWheel(delta > 0, abs(delta), recognizer.location(in: view))
            case .ended, .cancelled, .failed:
                directScrollSentTicks = 0
            default:
                break
            }
        }

        /// Shift zooms the font; otherwise, on an alternate screen, the wheel
        /// is forwarded to the remote application. On a normal screen with no
        /// Shift it stays unbegun so the scroll view's own pan handles pointer
        /// scrolling of the app-side scrollback.
        @objc func handleWheel(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                wheelSentTicks = 0
                zoomSentSteps = 0
            case .changed:
                let translation = recognizer.translation(in: view).y
                if recognizer.modifierFlags.contains(.shift) {
                    let steps = TerminalScroll.zoomSteps(forTranslation: translation)
                    let pending = steps - zoomSentSteps
                    guard pending != 0 else { return }
                    zoomSentSteps = steps
                    onZoom(pending, false)
                } else {
                    guard isAltScreen else { return }
                    let ticks = TerminalScroll.wheelTicks(forTranslation: translation)
                    let delta = ticks - wheelSentTicks
                    guard delta != 0 else { return }
                    wheelSentTicks = ticks
                    onScrollWheel(delta > 0, abs(delta), recognizer.location(in: view))
                }
            case .ended, .cancelled, .failed:
                if zoomSentSteps != 0 { onZoom(0, true) }
                wheelSentTicks = 0
                zoomSentSteps = 0
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === directScrollRecognizer {
                return isAltScreen
            }
            if gestureRecognizer === wheelRecognizer {
                return gestureRecognizer.modifierFlags.contains(.shift) || isAltScreen
            }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }
    }

    @MainActor
    final class Controller<HostedContent: View>: UIViewController {
        let scrollView = UIScrollView()
        weak var directScrollRecognizer: UIPanGestureRecognizer?
        let hostingController: UIHostingController<HostedContent>
        private let coordinator: Coordinator
        private var lastScrollVersion: Int?
        private var followsBottom = true

        init(rootView: HostedContent, coordinator: Coordinator) {
            self.hostingController = UIHostingController(rootView: rootView)
            self.coordinator = coordinator
            super.init(nibName: nil, bundle: nil)
            hostingController.sizingOptions = [.intrinsicContentSize]
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidLoad() {
            super.viewDidLoad()

            scrollView.delegate = coordinator
            // The terminal computes its own geometry from the viewport, so UIKit
            // must NOT inject safe-area insets on top of it. With `.automatic`,
            // a terminal that extends under the home indicator gets a ~20pt
            // bottom inset added, and `contentSize + adjustedContentInset >
            // bounds` makes the view scrollable by exactly that much even though
            // the content fits the screen perfectly.
            scrollView.contentInsetAdjustmentBehavior = .never
            scrollView.alwaysBounceVertical = true
            scrollView.showsVerticalScrollIndicator = true
            scrollView.delaysContentTouches = false
            scrollView.canCancelContentTouches = true
            scrollView.keyboardDismissMode = .none
            // Same reasoning: a pointer drag must not be swallowed as a scroll.
            // Wheel scrolling is unaffected -- it arrives through a separate
            // recognizer using `allowedScrollTypesMask`.
            scrollView.panGestureRecognizer.allowedTouchTypes =
                TerminalTouchPolicy.panAllowedTouchTypes
            scrollView.accessibilityIdentifier = "terminal.scroll"

            let tap = UITapGestureRecognizer(target: coordinator,
                                             action: #selector(Coordinator.handleTap(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = coordinator
            scrollView.addGestureRecognizer(tap)

            // Secondary (right) click. `buttonMaskRequired` keeps this off the
            // primary tap's path, and a right-click only exists on a pointer, so
            // this never competes with touch.
            let secondaryTap = UITapGestureRecognizer(
                target: coordinator, action: #selector(Coordinator.handleSecondaryTap(_:))
            )
            secondaryTap.buttonMaskRequired = .secondary
            // Required, not belt-and-braces: `buttonMaskRequired` filters
            // POINTER events, but a finger carries no buttons so UIKit does not
            // apply the mask to direct touches -- without this every tap fired
            // the secondary click and raised the remote's context menu.
            secondaryTap.allowedTouchTypes = TerminalTouchPolicy.secondaryClickAllowedTouchTypes
            secondaryTap.cancelsTouchesInView = false
            secondaryTap.delegate = coordinator
            scrollView.addGestureRecognizer(secondaryTap)

            let directScroll = UIPanGestureRecognizer(target: coordinator,
                                                      action: #selector(Coordinator.handleDirectScroll(_:)))
            directScroll.minimumNumberOfTouches = 1
            directScroll.maximumNumberOfTouches = 1
            // Finger drags only. A mouse click carries a pixel or two of
            // movement; left unrestricted this pan claimed it, the tap never
            // fired, and the click reached the remote as a WHEEL event instead
            // -- so controls like Herdr's sidebar collapse could not be clicked
            // at all with a pointer.
            directScroll.allowedTouchTypes = TerminalTouchPolicy.panAllowedTouchTypes
            directScroll.delegate = coordinator
            coordinator.directScrollRecognizer = directScroll
            directScrollRecognizer = directScroll
            view.addGestureRecognizer(directScroll)

            // Pointer wheel / trackpad scroll. On the controller's root view,
            // NOT an overlay: UIKit only delivers scroll events to recognizers
            // on the hit-tested view and its ancestors, so a non-hit-testable
            // sibling overlay never sees them — which is how pointer scrolling
            // silently did nothing while touch scrolling worked.
            let wheel = UIPanGestureRecognizer(target: coordinator,
                                               action: #selector(Coordinator.handleWheel(_:)))
            wheel.allowedScrollTypesMask = [.continuous, .discrete]
            // Scroll events only — never finger drags, never a click's jitter.
            wheel.allowedTouchTypes = TerminalTouchPolicy.wheelAllowedTouchTypes
            wheel.delegate = coordinator
            coordinator.wheelRecognizer = wheel
            view.addGestureRecognizer(wheel)

            view.addSubview(scrollView)
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: view.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])

            addChild(hostingController)
            scrollView.addSubview(hostingController.view)
            hostingController.view.translatesAutoresizingMaskIntoConstraints = false
            hostingController.view.backgroundColor = .clear
            hostingController.view.isOpaque = false
            NSLayoutConstraint.activate([
                hostingController.view.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
                hostingController.view.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
                hostingController.view.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
                hostingController.view.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
                hostingController.view.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor)
            ])
            hostingController.didMove(toParent: self)
        }

        func update(backgroundColor: UIColor,
                    followsBottom: Bool,
                    scrollVersion: Int,
                    isAltScreen: Bool,
                    cellSize: CGSize) {
            view.backgroundColor = backgroundColor
            scrollView.backgroundColor = backgroundColor
            self.followsBottom = followsBottom
            coordinator.isAltScreen = isAltScreen
            coordinator.cellSize = cellSize
            // Keep UIKit scrolling enabled so programmatic tail-follow keeps working;
            // the sibling pan recognizer still forwards remote wheel events.
            scrollView.isScrollEnabled = true
            // Bounce is what lets a finger drag a view that has nothing to
            // scroll to. On the alternate screen there IS nothing -- the remote
            // owns the viewport -- so bouncing only ever drags Herdr's tab bar
            // off the top edge.
            scrollView.alwaysBounceVertical = !isAltScreen
            invalidateHostedContentLayout()

            let changed = lastScrollVersion != scrollVersion
            lastScrollVersion = scrollVersion
            if TerminalScrollAnchor.pinsToTop(isAltScreen: isAltScreen) {
                pinToTopAfterLayout()
            } else if canAutoFollow && changed {
                scrollToBottomAfterLayout()
            }
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            if TerminalScrollAnchor.pinsToTop(isAltScreen: coordinator.isAltScreen) {
                pinToTopAfterLayout()
            } else if canAutoFollow {
                scrollToBottomAfterLayout()
            }
        }

        private var canAutoFollow: Bool {
            TerminalScrollAnchor.followsTail(
                isAltScreen: coordinator.isAltScreen,
                userIsFollowing: followsBottom
            ) && !coordinator.isUserInteracting
        }

        private func scrollToBottomAfterLayout() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.canAutoFollow else { return }
                self.invalidateHostedContentLayout()
                self.hostingController.view.layoutIfNeeded()
                self.scrollView.layoutIfNeeded()
                self.view.layoutIfNeeded()
                self.scrollView.setContentOffset(self.scrollView.bottomContentOffset, animated: false)
                self.coordinator.onBottomStateChange(true)
            }
        }

        /// Hold the alternate screen against the TOP of the viewport.
        ///
        /// Not merely "do not auto-scroll": the offset is actively reset,
        /// because a layout pass that briefly reports a taller content size can
        /// leave the view scrolled down with nothing to bring it back.
        private func pinToTopAfterLayout() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard !self.coordinator.isUserInteracting else { return }
                self.invalidateHostedContentLayout()
                self.hostingController.view.layoutIfNeeded()
                self.scrollView.layoutIfNeeded()
                self.view.layoutIfNeeded()
                let top = -self.scrollView.adjustedContentInset.top
                if self.scrollView.contentOffset.y != top {
                    self.scrollView.setContentOffset(CGPoint(x: 0, y: top), animated: false)
                }
            }
        }

        private func invalidateHostedContentLayout() {
            hostingController.view.invalidateIntrinsicContentSize()
            hostingController.view.setNeedsLayout()
            scrollView.setNeedsLayout()
            view.setNeedsLayout()
        }
    }
}

private extension UIScrollView {
    var hasScrollableContent: Bool {
        // Insets deliberately excluded -- see TerminalScrollAnchor.hasScrollableContent.
        TerminalScrollAnchor.hasScrollableContent(
            contentHeight: contentSize.height,
            viewportHeight: bounds.height
        )
    }

    var bottomContentOffset: CGPoint {
        let bottomY = max(-adjustedContentInset.top,
                          contentSize.height - bounds.height + adjustedContentInset.bottom)
        return CGPoint(x: contentOffset.x, y: bottomY)
    }

    var isAtBottom: Bool {
        contentOffset.y >= bottomContentOffset.y - 2
    }
}

/// Bridges the UIKit `TerminalKeyInputView` into SwiftUI and exposes a `focus()`
/// handle via a shared controller object.
private struct KeyInputRepresentable: UIViewRepresentable {
    let controller: KeyInputController
    let onInput: ([UInt8]) -> Void
    let applicationCursorProvider: () -> Bool

    func makeUIView(context: Context) -> TerminalKeyInputView {
        let view = TerminalKeyInputView(frame: .zero)
        view.onInput = onInput
        view.applicationCursorProvider = applicationCursorProvider
        controller.view = view
        return view
    }

    func updateUIView(_ uiView: TerminalKeyInputView, context: Context) {
        uiView.onInput = onInput
        uiView.applicationCursorProvider = applicationCursorProvider
    }
}

/// A small main-actor handle the SwiftUI view uses to focus the key-input view on tap.
@MainActor
@Observable
final class KeyInputController {
    private(set) var isFocusRequested = false
    weak var view: TerminalKeyInputView? {
        didSet {
            guard isFocusRequested else { return }
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.focusAttachedViewIfRequested()
            }
        }
    }

    func focus() {
        isFocusRequested = true
        focusAttachedViewIfRequested()
    }

    func blur() {
        isFocusRequested = false
        view?.resignFirstResponder()
    }

    private func focusAttachedViewIfRequested() {
        guard isFocusRequested, let view, !view.isFirstResponder else { return }
        view.becomeFirstResponder()
    }
}

