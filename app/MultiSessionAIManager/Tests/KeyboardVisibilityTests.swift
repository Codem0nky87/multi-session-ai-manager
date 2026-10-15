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
        #expect(overlap == 768 * 0.6)
    }

    @Test func ipadDoubleReportedOverlapIsHalved() {
        // Measured on the owner's iPad (TestFlight 202610150907): the
        // notification frame reports ~2.1x the real docked-keyboard overlap.
        // Landscape: window 1024 tall, real keyboard ~429pt, reported ~922pt.
        let reported = CGRect(x: 0, y: 1024 - 922, width: 1366, height: 922)
        let overlap = KeyboardVisibilityModel.dockedOverlap(
            bottom: 1024, keyboardEnd: reported, isiPad: true)
        #expect(overlap == 461)  // 922/2 — within ~7% of the real 429
    }

    @Test func ipadHonestOverlapIsUntouched() {
        // A normal iPad overlap (below 45% of the window) must not be halved.
        let overlap = KeyboardVisibilityModel.dockedOverlap(
            bottom: 1024, keyboardEnd: CGRect(x: 0, y: 1024 - 300, width: 1366, height: 300),
            isiPad: true)
        #expect(overlap == 300)
    }

    @Test func iPhoneLargeOverlapIsNotHalved() {
        // Phone landscape legitimately covers ~53% of the window; the
        // correction is iPad-idiom only.
        let overlap = KeyboardVisibilityModel.dockedOverlap(
            bottom: 440, keyboardEnd: CGRect(x: 0, y: 440 - 233, width: 956, height: 233),
            isiPad: false)
        #expect(overlap == 233)
    }

    @Test func zeroHeightFrameIsIgnored() {
        #expect(KeyboardVisibilityModel.dockedOverlap(
            bottom: 768, keyboardEnd: .zero) == 0)
    }
}
