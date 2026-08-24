import Foundation
import Testing
@testable import MultiSessionAIManager

/// Selection is MODAL: one-finger drag is scrollback, so a selection recognizer
/// competing with the scroll view's pan is what made the old inline long-press
/// unusable. Entering the mode disables scrolling and stops forwarding touches to
/// the remote pane, which removes the arbitration problem instead of trying to
/// win it. These pin the policy that decides that.
@Suite struct TerminalSelectionModeTests {
    @Test func selectionIsModalNotInline() {
        // the inline long-press recognizer stays off -- it lost to the scroll pan
        #expect(!TerminalTouchPolicy.inlineTextSelectionGestureEnabled)
        // ...and is replaced by an explicit mode
        #expect(TerminalTouchPolicy.modalTextSelectionEnabled)
    }

    @Test func scrollingIsDisabledOnlyWhileSelecting() {
        #expect(TerminalTouchPolicy.scrollEnabled(isSelecting: false))
        #expect(!TerminalTouchPolicy.scrollEnabled(isSelecting: true))
    }

    @Test func touchesReachTheRemotePaneOnlyWhenNotSelecting() {
        // forwarding a drag to Herdr while the user is dragging to select would
        // both scrub the remote selection and fight the local one
        #expect(TerminalTouchPolicy.forwardsTouchesToRemote(isSelecting: false, inputEnabled: true))
        #expect(!TerminalTouchPolicy.forwardsTouchesToRemote(isSelecting: true, inputEnabled: true))
    }

    @Test func aDisconnectedPaneNeverReceivesTouchesRegardlessOfMode() {
        #expect(!TerminalTouchPolicy.forwardsTouchesToRemote(isSelecting: false, inputEnabled: false))
        #expect(!TerminalTouchPolicy.forwardsTouchesToRemote(isSelecting: true, inputEnabled: false))
    }

    @Test func keyboardIsNotFocusedWhileSelecting() {
        // raising the keyboard mid-selection resizes the grid (SIGWINCH) and
        // reflows the very text being selected
        #expect(!TerminalTouchPolicy.focusesKeyboard(isSelecting: true, inputEnabled: true))
        #expect(TerminalTouchPolicy.focusesKeyboard(isSelecting: false, inputEnabled: true))
    }
}

@Suite @MainActor struct TerminalMultiLineSelectionTests {
    /// The mode exists to copy across lines; this pins that the underlying
    /// selection actually spans rows rather than clipping to one.
    @Test func selectionSpansMultipleRows() {
        let emulator = TerminalEmulator(cols: 40, rows: 6)
        emulator.feed(Data("alpha\r\nbravo\r\ncharlie\r\n".utf8))
        emulator.tick()

        let text = emulator.selectedText(fromRow: 0, fromCol: 0, toRow: 2, toCol: 6)

        #expect(text.contains("alpha"))
        #expect(text.contains("bravo"))
        #expect(text.contains("charlie"))
        #expect(text.components(separatedBy: "\n").count >= 3)
    }
}

@Suite @MainActor struct TerminalSelectionModelTests {
    @Test func copyIsInertUntilARangeExists() {
        let model = TerminalSelectionModel()
        model.isSelecting = true

        model.requestCopy()
        #expect(model.copyRequest == 0)   // nothing to copy, nothing requested

        model.setHasSelection(true)
        model.requestCopy()
        #expect(model.copyRequest == 1)
    }

    @Test func twoCopiesInARowAreTwoDistinctEvents() {
        let model = TerminalSelectionModel()
        model.setHasSelection(true)

        model.requestCopy()
        model.requestCopy()

        // a Bool flag would collapse these into one and drop the second copy
        #expect(model.copyRequest == 2)
    }

    @Test func exitingClearsBothModeAndRange() {
        let model = TerminalSelectionModel()
        model.isSelecting = true
        model.setHasSelection(true)

        model.exit()

        #expect(!model.isSelecting)
        #expect(!model.hasSelection)
        // and Copy goes inert again
        model.requestCopy()
        #expect(model.copyRequest == 0)
    }
}

#if canImport(UIKit)
import UIKit

/// Herdr's sidebar-collapse control could not be clicked with a mouse — worst on
/// an external display, where a pointer is the only input.
@Suite struct TerminalPointerClickTests {

    @Test func panRecognizersIgnoreIndirectPointerInput() {
        // A mouse click carries a pixel or two of movement. A pan that accepts
        // indirect input claims it, the tap never fires, and the click reaches
        // the remote as a WHEEL event rather than a click.
        #expect(!TerminalTouchPolicy.panAcceptsTouchType(.indirectPointer))
        #expect(!TerminalTouchPolicy.panAcceptsTouchType(.indirect))
    }

    @Test func fingerDragsStillPanAndScroll() {
        // Guarding against overcorrection: touch scrolling must keep working.
        #expect(TerminalTouchPolicy.panAcceptsTouchType(.direct))
    }

    @Test func theAllowedTouchTypesValueMatchesThePolicy() {
        let allowed = TerminalTouchPolicy.panAllowedTouchTypes.map(\.intValue)
        #expect(allowed == [UITouch.TouchType.direct.rawValue])
        #expect(!allowed.contains(UITouch.TouchType.indirectPointer.rawValue))
    }
}
#endif

/// Every tap was raising the remote's context menu.
@Suite struct TerminalSecondaryClickTouchTypeTests {

    @Test func onlyAPointerCanRaiseASecondaryClick() {
        // `buttonMaskRequired = .secondary` filters POINTER events. A finger
        // carries no buttons, so UIKit does not apply the mask to direct
        // touches and the recognizer fires on an ordinary tap. Restricting the
        // touch type is what actually confines it to a real right-click.
        let allowed = TerminalTouchPolicy.secondaryClickAllowedTouchTypes.map(\.intValue)
        #expect(allowed == [UITouch.TouchType.indirectPointer.rawValue])
        #expect(!allowed.contains(UITouch.TouchType.direct.rawValue))
    }

    @Test func theSecondaryAndPanRestrictionsAreNotTheSame() {
        // Easy to conflate: pans want DIRECT only (a mouse drag must not scroll),
        // secondary click wants POINTER only (a finger must not right-click).
        // They are opposites, so a single shared constant would be wrong.
        let pan = TerminalTouchPolicy.panAllowedTouchTypes.map(\.intValue)
        let secondary = TerminalTouchPolicy.secondaryClickAllowedTouchTypes.map(\.intValue)
        #expect(pan != secondary)
    }
}
