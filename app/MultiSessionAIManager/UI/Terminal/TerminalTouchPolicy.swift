import UIKit

/// Touch policy for the terminal body.
///
/// One-finger vertical drag is reserved for terminal scrollback, so an inline
/// long-press-then-drag selection recognizer competes with the scroll view's pan
/// recognizer on iPad — which is why `inlineTextSelectionGestureEnabled` is off
/// and stays off.
///
/// Selection is **modal** instead. Entering the mode disables scrolling and stops
/// forwarding touches to the remote pane, so a plain drag selects with nothing
/// left to arbitrate against. That works identically for finger, mouse and
/// trackpad, because no competing recognizer is running rather than because the
/// competition was won.
enum TerminalTouchPolicy {
    /// Whether a DRAG recognizer may claim this touch type.
    ///
    /// Indirect pointer input (mouse, trackpad) must not be claimed by a pan.
    /// A mouse click carries a pixel or two of movement, so a pan recognizer
    /// that accepts indirect input wins the click, and the tap that would have
    /// been forwarded to the remote never fires -- the click is delivered as a
    /// wheel event instead. On a touchscreen a finger tap is cleaner, which is
    /// why this reads as "works on the iPad, never on an external display".
    ///
    /// Nothing is lost: scroll-wheel input arrives through a separate
    /// recognizer using `allowedScrollTypesMask`, which is unaffected.
    static func panAcceptsTouchType(_ type: UITouch.TouchType) -> Bool {
        type == .direct
    }

    /// Touch types that may raise a secondary (right) click.
    ///
    /// Indirect pointer ONLY, and this is load-bearing rather than tidiness:
    /// `buttonMaskRequired = .secondary` filters POINTER events, but a finger
    /// carries no buttons, so UIKit does not apply the mask to direct touches at
    /// all and the recognizer fires on an ordinary tap. Without this restriction
    /// every tap raised the remote's context menu.
    static var secondaryClickAllowedTouchTypes: [NSNumber] {
        [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
    }

    /// The value to assign to a pan recognizer's `allowedTouchTypes`.
    static var panAllowedTouchTypes: [NSNumber] {
        [NSNumber(value: UITouch.TouchType.direct.rawValue)]
    }

    /// The value to assign to the wheel pan's `allowedTouchTypes`: none.
    ///
    /// The wheel pan opts into SCROLL events with `allowedScrollTypesMask`,
    /// which is unaffected by this list. Admitting any touch type would let it
    /// claim finger drags (fighting scrollback) or the pixel of movement in a
    /// mouse click (the exact bug `panAcceptsTouchType` exists to prevent).
    static var wheelAllowedTouchTypes: [NSNumber] {
        []
    }

    /// The old inline recognizer. Kept false: see above.
    static let inlineTextSelectionGestureEnabled = false

    /// The replacement: an explicit Select mode toggled from the app's top bar.
    static let modalTextSelectionEnabled = true

    /// Scrollback panning, suspended while selecting so a drag means "select".
    static func scrollEnabled(isSelecting: Bool) -> Bool { !isSelecting }

    /// Whether taps and pointer clicks reach the remote pane. Suppressed while
    /// selecting: forwarding a drag to Herdr would scrub its own selection and
    /// fight the local one. A pane that is not live never receives touches.
    static func forwardsTouchesToRemote(isSelecting: Bool, inputEnabled: Bool) -> Bool {
        inputEnabled && !isSelecting
    }

    /// Whether a tap should raise the software keyboard. Suppressed while
    /// selecting: raising it resizes the grid (SIGWINCH) and reflows the very
    /// text being selected.
    static func focusesKeyboard(isSelecting: Bool, inputEnabled: Bool) -> Bool {
        inputEnabled && !isSelecting
    }
}

enum TerminalHardwareKeyRepeatPolicy {
    static func shouldRepeat(keyCode: UIKeyboardHIDUsage, modifiers: UIKeyModifierFlags) -> Bool {
        keyCode == .keyboardDeleteOrBackspace && !modifiers.contains(.command)
    }
}
