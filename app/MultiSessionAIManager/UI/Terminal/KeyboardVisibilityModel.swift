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
        if note.name == UIResponder.keyboardDidHideNotification {
            height = 0
            return
        }
        height = Self.dockedOverlap(bottom: Self.windowHeight,
                                    keyboardEnd: note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero)
    }

    /// Height of the app's key window in the CURRENT orientation. The
    /// keyboard notification frames share this coordinate space;
    /// `UIScreen.main.bounds` can lag a rotation and produce a mismatch,
    /// which previously padded the quick-key bar past the whole window.
    @MainActor
    static var windowHeight: CGFloat {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        let window = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        return window?.bounds.maxY ?? UIScreen.main.bounds.maxY
    }

    /// Points of bottom-edge screen the docked keyboard covers, or 0 when it
    /// floats. Pure so it can be unit-tested without notifications.
    /// - A floating (non-docked) keyboard does not reach the bottom edge, so
    ///   it costs no rows and reports zero overlap.
    /// - Clamped: a bogus frame (observed on iPad around rotation) reports an
    ///   overlap far taller than any real keyboard; unclamped it pads the
    ///   quick-key bar past the whole window, stranding it at the top. No
    ///   docked keyboard covers more than ~55% of the window (worst case:
    ///   a small phone in landscape).
    nonisolated static func dockedOverlap(bottom: CGFloat, keyboardEnd: CGRect) -> CGFloat {
        guard keyboardEnd.height > 0, keyboardEnd.maxY >= bottom - 1 else { return 0 }
        return min(max(0, bottom - keyboardEnd.minY), bottom * 0.55)
    }
}
