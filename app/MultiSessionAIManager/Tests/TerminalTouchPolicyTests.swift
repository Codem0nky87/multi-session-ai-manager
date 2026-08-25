import Testing
import UIKit
@testable import MultiSessionAIManager

@Suite struct TerminalTouchPolicyTests {
    @Test func oneFingerDragIsReservedForScrollback() {
        #expect(TerminalTouchPolicy.inlineTextSelectionGestureEnabled == false)
    }

    @Test func theWheelRecognizerAcceptsOnlyIndirectPointers() {
        // Scroll events arrive as touches of type indirectPointer, so the type
        // must be admitted or the recognizer never fires at all (an empty list
        // silently killed pointer scrolling). Direct stays out so finger drags
        // belong to scrollback alone; click protection comes from the
        // recognizer NOT cancelling touches, never from this list.
        #expect(TerminalTouchPolicy.wheelAllowedTouchTypes ==
                [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)])
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
