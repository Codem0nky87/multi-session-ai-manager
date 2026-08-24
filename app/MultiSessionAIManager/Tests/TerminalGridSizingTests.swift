import CoreGraphics
import Foundation
import Testing
@testable import MultiSessionAIManager

/// The scroll view follows the bottom, so content even a fraction of a point
/// taller than the viewport scrolls down and shaves the TOP row — where Herdr
/// draws its pane labels. That is the bug these pin.
@Suite struct TerminalGridSizingTests {

    @Test func contentNeverExceedsTheViewportAtANYHeight() {
        // The property, not an example: the old arithmetic failed only when the
        // height happened to divide almost exactly, so a single case would have
        // passed while the bug was live.
        for cellHeight in stride(from: 8.0, through: 30.0, by: 0.5) {
            for viewportHeight in stride(from: 100.0, through: 1400.0, by: 0.25) {
                for bottomInset in [0.0, 12.0, 34.0] {
                    let rows = TerminalGridSizing.rows(
                        viewportHeight: viewportHeight,
                        bottomInset: bottomInset,
                        cellHeight: cellHeight
                    )
                    let content = TerminalGridSizing.contentHeight(
                        rows: rows, cellHeight: cellHeight, bottomInset: bottomInset
                    )
                    #expect(
                        content <= viewportHeight,
                        "content \(content) > viewport \(viewportHeight) (cell \(cellHeight), inset \(bottomInset))"
                    )
                }
            }
        }
    }

    @Test func theAnchorIsAccountedForNotIgnored() {
        // A viewport that is an EXACT multiple of the cell height is the case
        // that used to overflow: floor() gave a full row count, then the anchor
        // pushed the content one point past the bottom.
        let cell: CGFloat = 20
        let rows = TerminalGridSizing.rows(viewportHeight: 400, bottomInset: 0, cellHeight: cell)
        #expect(rows == 18)   // 20 rows fit on paper; one is anchor, one reserved
        #expect(TerminalGridSizing.contentHeight(rows: rows, cellHeight: cell, bottomInset: 0) <= 400)
    }

    @Test func aRowIsHeldBackSoAStaleViewportCannotOverflow() {
        // The viewport height is sampled from the scroll view and can be
        // momentarily stale during a resize or first layout. Held high, the
        // remote would draw rows that do not fit -- and on the alternate screen,
        // which is pinned to the top, those rows are unreachable.
        let cell: CGFloat = 20
        let rows = TerminalGridSizing.rows(viewportHeight: 1000, bottomInset: 0, cellHeight: cell)
        let content = TerminalGridSizing.contentHeight(rows: rows, cellHeight: cell, bottomInset: 0)
        #expect(content <= 1000 - cell)
    }

    @Test func aTallViewportStillGetsTheRowsItCanHold() {
        // Guarding against overcorrection: exactly one row of slack, not more.
        let rows = TerminalGridSizing.rows(viewportHeight: 1000, bottomInset: 0, cellHeight: 20)
        #expect(rows == 48)
    }

    @Test func aViewportSmallerThanOneCellStillReportsOneRow() {
        // A zero-row grid would make the emulator's resize meaningless and can
        // divide by zero downstream.
        #expect(TerminalGridSizing.rows(viewportHeight: 5, bottomInset: 0, cellHeight: 20) == 1)
        #expect(TerminalGridSizing.rows(viewportHeight: 0, bottomInset: 0, cellHeight: 20) == 1)
    }

    @Test func aZeroCellHeightNeverDividesByZero() {
        #expect(TerminalGridSizing.rows(viewportHeight: 400, bottomInset: 0, cellHeight: 0) == 1)
        #expect(TerminalGridSizing.columns(viewportWidth: 400, cellWidth: 0) == 1)
    }

    @Test func columnsFloorSoGlyphsAreNeverHalfDrawnAtTheRightEdge() {
        #expect(TerminalGridSizing.columns(viewportWidth: 100, cellWidth: 9) == 11)
        #expect(TerminalGridSizing.columns(viewportWidth: 99, cellWidth: 9) == 11)
        #expect(TerminalGridSizing.columns(viewportWidth: 5, cellWidth: 9) == 1)
    }
}

/// Herdr repaints a fixed frame and owns its own scrollback, so the app has no
/// tail to follow on the alternate screen — and following one there is what hid
/// Herdr's tab bar.
@Suite struct TerminalScrollAnchorTests {

    @Test func theAlternateScreenPinsToTheTop() {
        #expect(TerminalScrollAnchor.pinsToTop(isAltScreen: true))
        #expect(!TerminalScrollAnchor.pinsToTop(isAltScreen: false))
    }

    @Test func theAlternateScreenNeverFollowsTheTail() {
        // Even when the user is "at the bottom": a mismatch of a single row
        // between content and viewport silently eats the FIRST rows, which is
        // exactly where the tab bar and pane labels live.
        #expect(!TerminalScrollAnchor.followsTail(isAltScreen: true, userIsFollowing: true))
        #expect(!TerminalScrollAnchor.followsTail(isAltScreen: true, userIsFollowing: false))
    }

    @Test func anOrdinaryShellStillFollowsItsOutput() {
        // Guarding against overcorrection: a normal scrollback session must keep
        // scrolling as output arrives.
        #expect(TerminalScrollAnchor.followsTail(isAltScreen: false, userIsFollowing: true))
        #expect(!TerminalScrollAnchor.followsTail(isAltScreen: false, userIsFollowing: false))
    }
}

@Suite struct TerminalScrollInsetTests {

    @Test func aTerminalThatFitsExactlyIsNotScrollable() {
        #expect(!TerminalScrollAnchor.hasScrollableContent(contentHeight: 1000, viewportHeight: 1000))
    }

    @Test func aHomeIndicatorSizedInsetDoesNotMakeItScrollable() {
        // THE bug: UIKit's `.automatic` inset adjustment added the safe-area
        // inset to the content, so a terminal filling the screen exactly
        // reported itself scrollable by ~20pt and the tail-follow then dragged
        // Herdr's tab bar off the top.
        #expect(!TerminalScrollAnchor.hasScrollableContent(contentHeight: 1000, viewportHeight: 1000))
        #expect(!TerminalScrollAnchor.hasScrollableContent(contentHeight: 1001, viewportHeight: 1000))
    }

    @Test func realScrollbackIsStillScrollable() {
        #expect(TerminalScrollAnchor.hasScrollableContent(contentHeight: 5000, viewportHeight: 1000))
    }

    @Test func theAlternateScreenDoesNotBounce() {
        #expect(!TerminalScrollAnchor.bounces(isAltScreen: true))
        #expect(TerminalScrollAnchor.bounces(isAltScreen: false))
    }
}

/// The window-resize grip in the bottom corners swallows clicks before the app
/// sees them, so anything the remote draws on its last row is unclickable.
@Suite struct TerminalResizeGripClearanceTests {

    @Test func theClearanceIsSubtractedFromTheUsableHeight() {
        // Otherwise the remote is handed rows that sit under the grip.
        let withoutInset = TerminalGridSizing.rows(
            viewportHeight: 1000, bottomInset: 0, cellHeight: 20
        )
        let withInset = TerminalGridSizing.rows(
            viewportHeight: 1000, bottomInset: HerdrChromeMetrics.resizeGripClearance, cellHeight: 20
        )
        #expect(withInset < withoutInset)
    }

    @Test func contentPlusTheClearanceStillFitsTheViewport() {
        // The clearance is dead space BELOW the last row, so it has to be part
        // of the fit calculation, not added afterwards.
        for cellHeight in stride(from: 8.0, through: 24.0, by: 1.0) {
            for viewportHeight in stride(from: 200.0, through: 1400.0, by: 7.0) {
                let inset = HerdrChromeMetrics.resizeGripClearance
                let rows = TerminalGridSizing.rows(
                    viewportHeight: viewportHeight, bottomInset: inset, cellHeight: cellHeight
                )
                let content = TerminalGridSizing.contentHeight(
                    rows: rows, cellHeight: cellHeight, bottomInset: inset
                )
                #expect(content <= viewportHeight,
                        "content \(content) > viewport \(viewportHeight) at cell \(cellHeight)")
            }
        }
    }

    @Test func theClearanceIsBigEnoughToActuallyClearTheGrip() {
        // A grip is roughly 16-20pt; anything smaller is cosmetic and leaves the
        // control just as unclickable.
        #expect(HerdrChromeMetrics.resizeGripClearance >= 16)
        // ...and small enough not to cost more than a couple of rows.
        #expect(HerdrChromeMetrics.resizeGripClearance <= 32)
    }
}
