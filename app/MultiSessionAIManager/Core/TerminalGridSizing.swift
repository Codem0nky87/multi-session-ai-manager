import CoreGraphics

/// How many terminal rows fit in a viewport, and how tall the rendered content
/// then is.
///
/// Pure arithmetic so the invariant that matters can be tested: the content must
/// NEVER be taller than the viewport. The scroll view follows the bottom, so a
/// content height that exceeds the viewport by even a fraction of a point scrolls
/// down and shaves the TOP row — which is exactly where Herdr draws its pane
/// labels, so it surfaces as "the label is cut off a bit".
enum TerminalGridSizing {
    /// The invisible follow-the-tail anchor appended below the last row.
    ///
    /// It has real height, so it MUST be subtracted before dividing into rows.
    /// Leaving it out is what let content overflow the viewport by up to a point
    /// whenever the height happened to divide almost exactly.
    static let bottomAnchorHeight: CGFloat = 1

    /// One row held back from the remote.
    ///
    /// The arithmetic alone says content fits: cell heights are whole points and
    /// the row count is floored. In practice it still overflowed and the view
    /// could be dragged, because the viewport height the grid is derived from is
    /// sampled from the scroll view's bounds and can be momentarily stale --
    /// during a window resize, a rotation, or the first layout pass. When it is
    /// stale HIGH the remote is told to draw rows that do not fit, and on the
    /// alternate screen (pinned to the top) the extra rows are simply
    /// unreachable: scrolling down to see them snaps straight back.
    ///
    /// Trading one row for "the remote can never draw more than is visible" is
    /// worth it -- a row is cheap, and an unreachable status line is not.
    static let reservedRows = 1

    static func rows(viewportHeight: CGFloat, bottomInset: CGFloat, cellHeight: CGFloat) -> Int {
        guard cellHeight > 0 else { return 1 }
        let reserved = CGFloat(reservedRows) * cellHeight
        let usable = max(viewportHeight - bottomInset - bottomAnchorHeight - reserved, cellHeight)
        return max(Int((usable / cellHeight).rounded(.down)), 1)
    }

    static func columns(viewportWidth: CGFloat, cellWidth: CGFloat) -> Int {
        guard cellWidth > 0 else { return 1 }
        return max(Int((viewportWidth / cellWidth).rounded(.down)), 1)
    }

    /// What `rowsContent` actually lays out.
    static func contentHeight(rows: Int, cellHeight: CGFloat, bottomInset: CGFloat) -> CGFloat {
        CGFloat(rows) * cellHeight + bottomAnchorHeight + bottomInset
    }
}

/// Where the terminal's scroll view should sit when content and viewport do not
/// match exactly.
enum TerminalScrollAnchor {
    /// True when the view must pin to the TOP rather than follow the tail.
    ///
    /// On the alternate screen the remote owns the whole viewport: a TUI like
    /// Herdr repaints a fixed frame and keeps its own scrollback, so there is no
    /// app-side tail to follow. Pinning to the bottom there is not merely
    /// pointless -- if the content is even slightly taller than the viewport it
    /// silently hides the FIRST rows, which is exactly where Herdr draws its tab
    /// bar and pane labels. Anchoring to the top means any mismatch costs the
    /// last row instead, which is far less destructive.
    static func pinsToTop(isAltScreen: Bool) -> Bool { isAltScreen }

    /// Whether following the tail is appropriate at all.
    static func followsTail(isAltScreen: Bool, userIsFollowing: Bool) -> Bool {
        !isAltScreen && userIsFollowing
    }
}

extension TerminalScrollAnchor {
    /// Whether the view should bounce when there is nothing to scroll to.
    ///
    /// Bounce is what lets a finger drag a view whose content already fits. On
    /// the alternate screen that only ever drags the remote's first rows off the
    /// top edge, so it is disabled there.
    static func bounces(isAltScreen: Bool) -> Bool { !isAltScreen }

    /// Whether the scroll view has genuinely scrollable content.
    ///
    /// `adjustedContentInset` is deliberately NOT added here. UIKit's
    /// `.automatic` inset adjustment injects the safe-area inset, which made a
    /// perfectly-fitting terminal report itself as scrollable by the height of
    /// the home indicator -- the reason the terminal now opts out of that
    /// adjustment entirely.
    static func hasScrollableContent(contentHeight: CGFloat, viewportHeight: CGFloat) -> Bool {
        contentHeight > viewportHeight + 2
    }
}
