import Foundation
import Testing
@testable import MultiSessionAIManager

/// Selection disables scrollback panning, so without this a drag can only ever
/// select what is already on screen -- dragging past the bottom edge does
/// nothing. These pin the edge-proximity ramp that reveals more rows mid-drag.
@Suite struct TerminalSelectionAutoScrollTests {
    private let height: CGFloat = 800

    @Test func noScrollWhileTheDragIsAwayFromBothEdges() {
        #expect(TerminalSelectionAutoScroll.velocity(atY: 400, viewportHeight: height) == 0)
        #expect(TerminalSelectionAutoScroll.velocity(atY: 200, viewportHeight: height) == 0)
        #expect(TerminalSelectionAutoScroll.velocity(atY: 600, viewportHeight: height) == 0)
    }

    @Test func draggingPastTheBottomEdgeScrollsDown() {
        // positive = toward the end of the content
        #expect(TerminalSelectionAutoScroll.velocity(atY: height - 5, viewportHeight: height) > 0)
    }

    @Test func draggingPastTheTopEdgeScrollsUp() {
        #expect(TerminalSelectionAutoScroll.velocity(atY: 5, viewportHeight: height) < 0)
    }

    @Test func speedRampsWithProximityToTheEdge() {
        let nearEdge = TerminalSelectionAutoScroll.velocity(atY: height - 2, viewportHeight: height)
        let justInside = TerminalSelectionAutoScroll.velocity(atY: height - 35, viewportHeight: height)
        #expect(nearEdge > justInside)
        #expect(justInside > 0)
    }

    @Test func aDragBeyondTheViewportClampsRatherThanRunningAway() {
        // a finger dragged off the bottom of the screen reports y past the height;
        // the ramp must saturate instead of scaling without bound
        let atEdge = TerminalSelectionAutoScroll.velocity(atY: height, viewportHeight: height)
        let wayPast = TerminalSelectionAutoScroll.velocity(atY: height + 500, viewportHeight: height)
        #expect(wayPast == atEdge)
        #expect(atEdge == TerminalSelectionAutoScroll.maximumPointsPerTick)
    }

    @Test func aDragAboveTheViewportClampsTheOtherWay() {
        let atEdge = TerminalSelectionAutoScroll.velocity(atY: 0, viewportHeight: height)
        let wayAbove = TerminalSelectionAutoScroll.velocity(atY: -500, viewportHeight: height)
        #expect(wayAbove == atEdge)
        #expect(atEdge == -TerminalSelectionAutoScroll.maximumPointsPerTick)
    }

    @Test func aViewportShorterThanTwoEdgeZonesStillBehaves() {
        // a very short pane must not make the two zones overlap into nonsense
        let tiny: CGFloat = 30
        let top = TerminalSelectionAutoScroll.velocity(atY: 1, viewportHeight: tiny)
        let bottom = TerminalSelectionAutoScroll.velocity(atY: tiny - 1, viewportHeight: tiny)
        #expect(top < 0)
        #expect(bottom > 0)
    }

    @Test func aZeroHeightViewportNeverScrolls() {
        #expect(TerminalSelectionAutoScroll.velocity(atY: 0, viewportHeight: 0) == 0)
    }

    // MARK: - Offset clamping

    @Test func scrollingStopsAtTheContentEnds() {
        // 0 = top, 400 = the furthest valid offset
        #expect(TerminalSelectionAutoScroll.clampedOffset(current: 390, delta: 40, maximum: 400) == 400)
        #expect(TerminalSelectionAutoScroll.clampedOffset(current: 10, delta: -40, maximum: 400) == 0)
        #expect(TerminalSelectionAutoScroll.clampedOffset(current: 100, delta: 25, maximum: 400) == 125)
    }

    @Test func contentShorterThanTheViewportNeverScrolls() {
        #expect(TerminalSelectionAutoScroll.clampedOffset(current: 0, delta: 40, maximum: 0) == 0)
        #expect(TerminalSelectionAutoScroll.clampedOffset(current: 0, delta: -40, maximum: -20) == 0)
    }
}
