import Testing
import CoreGraphics
@testable import MultiSessionAIManager

@Suite struct KeyboardVisibilityTests {
    @Test func dockedKeyboardReportsItsOverlap() {
        // iPad landscape: window 1024x768, docked keyboard 265pt tall.
        let overlap = KeyboardVisibilityModel.dockedOverlap(
            bottom: 768, keyboardEnd: CGRect(x: 0, y: 503, width: 1024, height: 265))
        #expect(overlap == 265)
    }

    @Test func floatingKeyboardCostsNothing() {
        // A floating keyboard does not reach the bottom edge.
        let overlap = KeyboardVisibilityModel.dockedOverlap(
            bottom: 768, keyboardEnd: CGRect(x: 300, y: 400, width: 424, height: 300))
        #expect(overlap == 0)
    }

    @Test func bogusOversizedFrameIsClamped() {
        // Observed on iPad around rotation: a frame taller than the window
        // itself. Unclamped it pads the quick-key bar past the whole window,
        // stranding it at the top (the 07:24 screenshot bug).
        let overlap = KeyboardVisibilityModel.dockedOverlap(
            bottom: 768, keyboardEnd: CGRect(x: 0, y: -256, width: 1024, height: 1024))
        #expect(overlap == 768 * 0.55)
    }

    @Test func zeroHeightFrameIsIgnored() {
        #expect(KeyboardVisibilityModel.dockedOverlap(
            bottom: 768, keyboardEnd: .zero) == 0)
    }
}
