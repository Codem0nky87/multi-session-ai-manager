import Testing
import UIKit
@testable import MultiSessionAIManager

@Suite struct TerminalTouchPolicyTests {
    @Test func oneFingerDragIsReservedForScrollback() {
        #expect(TerminalTouchPolicy.inlineTextSelectionGestureEnabled == false)
    }

    @Test func theWheelRecognizerNeverClaimsTouches() {
        // The wheel pan accepts SCROLL events only (via allowedScrollTypesMask).
        // Any touch type here would let it claim finger drags or the pixel of
        // movement in a mouse click -- the exact bug panAcceptsTouchType exists
        // to prevent.
        #expect(TerminalTouchPolicy.wheelAllowedTouchTypes.isEmpty)
    }

    @Test func physicalBackspaceRepeatsWithoutCommandModifier() {
        #expect(TerminalHardwareKeyRepeatPolicy.shouldRepeat(
            keyCode: .keyboardDeleteOrBackspace,
            modifiers: []
        ))
    }

    @Test func commandBackspaceDoesNotStartTerminalRepeat() {
        #expect(!TerminalHardwareKeyRepeatPolicy.shouldRepeat(
            keyCode: .keyboardDeleteOrBackspace,
            modifiers: .command
        ))
    }
}
