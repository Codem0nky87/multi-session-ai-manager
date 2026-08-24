import Testing
import UIKit
@testable import MultiSessionAIManager

@Suite struct TerminalTouchPolicyTests {
    @Test func oneFingerDragIsReservedForScrollback() {
        #expect(TerminalTouchPolicy.inlineTextSelectionGestureEnabled == false)
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
