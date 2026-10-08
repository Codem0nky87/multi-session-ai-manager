//
//  KeyboardVisibilityModel.swift
//  MultiSessionAIManager
//
//  Publishes how much of the screen the software keyboard currently covers.
//  SwiftUI does NOT extend a view's safe area for the keyboard, and the app
//  has no text fields for it to auto-avoid, so the phone layout observes the
//  UIKit keyboard notifications directly and lifts the quick-key bar above
//  the keyboard with an explicit bottom inset. The terminal's frame shrinks
//  with it, which re-derives cols/rows and SIGWINCHes the remote — the
//  intended behaviour: fewer visible rows while typing, full height again
//  once the keyboard is dismissed for scrolling history.
//

import Observation
import UIKit

@MainActor
@Observable
final class KeyboardVisibilityModel: NSObject {
    /// Points of screen height the keyboard currently overlaps at the bottom.
    /// 0 while hidden (including the floating iPad keyboard, which floats
    /// above the bottom edge and must not resize the grid).
    private(set) var height: CGFloat = 0

    var isVisible: Bool { height > 0 }

    override init() {
        super.init()
        let center = NotificationCenter.default
        for name in [
            UIResponder.keyboardWillShowNotification,
            UIResponder.keyboardWillChangeFrameNotification,
            UIResponder.keyboardWillHideNotification,
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
        if note.name == UIResponder.keyboardWillHideNotification {
            height = 0
            return
        }
        updateHeight(from: note)
    }

    private func updateHeight(from note: Notification) {
        guard let end = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect,
              end.height > 0 else {
            height = 0
            return
        }
        // The end frame is in screen coordinates. A floating (non-docked)
        // keyboard does not reach the bottom edge, so it costs no rows and
        // reports zero overlap.
        let bottom = UIScreen.main.bounds.maxY
        guard end.maxY >= bottom - 1 else {
            height = 0
            return
        }
        height = max(0, bottom - end.minY)
    }
}
