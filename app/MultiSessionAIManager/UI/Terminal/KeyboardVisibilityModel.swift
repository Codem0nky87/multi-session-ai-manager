//
//  KeyboardVisibilityModel.swift
//  MultiSessionAIManager
//
//  Publishes how much of the app window the docked keyboard currently covers.
//  RootView opts out of SwiftUI keyboard avoidance on both iPhone and iPad;
//  this model supplies the single explicit inset beneath the quick-key bar.
//  The terminal's frame shrinks with it, re-deriving cols/rows and sending
//  SIGWINCH to the remote: fewer visible rows while typing, full height again
//  once the keyboard is dismissed for scrolling history.
//

import Observation
import UIKit

@MainActor
@Observable
final class KeyboardVisibilityModel: NSObject {
    /// Points of window height the keyboard currently overlaps at the bottom.
    /// 0 while hidden (including the floating iPad keyboard, which floats
    /// above the bottom edge and must not resize the grid).
    private(set) var height: CGFloat = 0

    /// A floating keyboard is visible and dismissible, but reserves no rows.
    private(set) var isVisible = false

    override init() {
        super.init()
        let center = NotificationCenter.default
        // Settled (did*) frames, not will*: on iPad the will* frames during
        // presentation/rotation can report an inflated or transient rect, and
        // the last value wins — an inflated one shoves the quick-key bar to
        // the top of the terminal.
        for name in [
            UIResponder.keyboardDidShowNotification,
            UIResponder.keyboardDidChangeFrameNotification,
            UIResponder.keyboardDidHideNotification,
        ] {
            center.addObserver(
                self, selector: #selector(keyboardFrameChanged(_:)), name: name, object: nil
            )
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func keyboardFrameChanged(_ note: Notification) {
        guard let window = Self.keyWindow else { return }
        let screen = note.object as? UIScreen ?? window.screen
        guard screen == window.screen else { return }
        if note.name == UIResponder.keyboardDidHideNotification {
            height = 0
            isVisible = false
            return
        }
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        // Notifications use SCREEN coordinates. A window in Split View or Stage
        // Manager can have a different origin/size, so intersect only after conversion.
        let frameInWindow = window.convert(frame, from: screen.coordinateSpace)
        isVisible = !window.bounds.intersection(frameInWindow).isEmpty
        height = Self.dockedOverlap(in: window.bounds, keyboardEnd: frameInWindow)
    }

    /// The key window's bottom safe-area inset: the home-indicator strip. Unlike a
    /// SwiftUI view's own reading, it does not drop to zero for a view that ignores
    /// the safe area, and it does not include the keyboard.
    @MainActor
    static var windowBottomSafeAreaInset: CGFloat {
        keyWindow?.safeAreaInsets.bottom ?? 0
    }

    @MainActor
    private static var keyWindow: UIWindow? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        return scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
    }

    /// Space the quick-key bar keeps beneath it: the docked keyboard while it is up
    /// (it covers the home indicator, so the larger figure wins), the home-indicator
    /// strip otherwise.
    ///
    /// `measuredHomeInset` is what the terminal view reads from its own geometry. That
    /// view ignores the bottom safe area, so the reading is 0: on a phone, whose bar
    /// wraps onto two rows, that left the whole bottom row of keys inside the
    /// swipe-up strip. A phone therefore uses the window's inset. iPad keeps the
    /// measured figure and its existing flush-to-the-edge bar.
    nonisolated static func barBottomInset(keyboardOverlap: CGFloat,
                                           measuredHomeInset: CGFloat,
                                           windowHomeInset: CGFloat,
                                           isPhone: Bool) -> CGFloat {
        max(isPhone ? windowHomeInset : measuredHomeInset, keyboardOverlap)
    }

    /// Both rectangles must be in window coordinates. A docked keyboard spans
    /// the window's bottom edge; floating keyboards don't reserve terminal rows.
    /// Use the actual intersection, without guessing a maximum keyboard percentage
    /// or halving tall iPad keyboards (which are legitimate in smaller windows).
    nonisolated static func dockedOverlap(in bounds: CGRect, keyboardEnd: CGRect) -> CGFloat {
        guard !bounds.isEmpty, !keyboardEnd.isEmpty,
              !bounds.isInfinite, !keyboardEnd.isInfinite,
              keyboardEnd.maxY >= bounds.maxY - 1,
              keyboardEnd.minX <= bounds.minX + 1,
              keyboardEnd.maxX >= bounds.maxX - 1 else { return 0 }
        let intersection = bounds.intersection(keyboardEnd)
        return intersection.isNull ? 0 : intersection.height
    }
}
