//
//  TerminalKeyInputView.swift
//  MultiSessionAIManager
//
//  A first-responder UIView that translates the software + hardware keyboard into
//  terminal byte sequences and hands them to a callback (wired to the emulator,
//  which forwards to the PTY). Adapted from NewTerm's `TerminalKeyInput`, trimmed
//  to `UIKeyInput` + `pressesBegan` (no password autofill / custom input toolbar;
//  the Herdr shell owns its surrounding controls).
//
//  `applicationCursor` is read from a provider closure so arrow keys send the
//  correct (normal vs application) escape sequence based on the live terminal mode.
//

import UIKit

final class TerminalKeyInputView: UIView, UIKeyInput {

    /// Sends translated key bytes onward (to the emulator -> PTY).
    var onInput: (([UInt8]) -> Void)?
    /// Reports whether the terminal is in application-cursor mode (DECCKM).
    var applicationCursorProvider: () -> Bool = { false }
    private let hardwareRepeater = RepeatKeyPressController()
    private var repeatingHardwareKey: UIKeyboardHIDUsage?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - First responder

    override var canBecomeFirstResponder: Bool { true }

    // The terminal view focuses this input programmatically. Direct touches should
    // pass through to the terminal scroll/tap layer underneath.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    // MARK: - Paste (clipboard → PTY)

    /// Enable the Paste edit-menu item / hardware Cmd-V when the clipboard holds text.
    /// `handleKey` returns false for `.command` combos, so UIKit
    /// routes Cmd-V to `paste(_:)` on this first responder.
    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)) {
            return TerminalClipboard.canPaste(from: UIPasteboard.general)
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        switch TerminalClipboard.payload(from: UIPasteboard.general) {
        case .text(let string):
            onInput?(Array(string.utf8))
        case nil:
            break
        }
    }

    // MARK: - Text input traits

    var keyboardType: UIKeyboardType = .asciiCapable
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    // MARK: - UIKeyInput (software keyboard)

    var hasText: Bool { true }

    func insertText(_ text: String) {
        let data = text.utf8.map { character -> UInt8 in
            // Convert newline to carriage return for the shell.
            character == 0x0A ? EscapeSequences.return.first! : character
        }
        onInput?(data)
    }

    func deleteBackward() {
        onInput?(EscapeSequences.backspace)
    }

    // MARK: - Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            if let key = press.key, handleKey(key) {
                continue
            }
            unhandled.insert(press)
        }
        if !unhandled.isEmpty {
            super.pressesBegan(unhandled, with: event)
        }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if stopRepeatingKey(for: presses) { return }
        super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if stopRepeatingKey(for: presses) { return }
        super.pressesCancelled(presses, with: event)
    }

    private func handleKey(_ key: UIKey) -> Bool {
        // Let UIKit handle cmd shortcuts.
        if key.modifierFlags.contains(.command) {
            return false
        }

        let appCursor = applicationCursorProvider()
        var keyData: [UInt8]
        switch key.keyCode {
        case .keyboardReturnOrEnter:     keyData = EscapeSequences.return
        case .keyboardEscape:            keyData = EscapeSequences.meta
        case .keyboardDeleteOrBackspace: keyData = EscapeSequences.backspace
        case .keyboardDeleteForward:     keyData = EscapeSequences.delete
        case .keyboardTab:               keyData = EscapeSequences.tab

        case .keyboardHome: keyData = appCursor ? EscapeSequences.homeApp : EscapeSequences.home
        case .keyboardEnd:  keyData = appCursor ? EscapeSequences.endApp : EscapeSequences.end

        case .keyboardUpArrow:   keyData = appCursor ? EscapeSequences.upApp : EscapeSequences.up
        case .keyboardDownArrow: keyData = appCursor ? EscapeSequences.downApp : EscapeSequences.down

        case .keyboardLeftArrow:
            if key.modifierFlags.contains(.alternate) {
                keyData = EscapeSequences.leftMeta
            } else {
                keyData = appCursor ? EscapeSequences.leftApp : EscapeSequences.left
            }
        case .keyboardRightArrow:
            if key.modifierFlags.contains(.alternate) {
                keyData = EscapeSequences.rightMeta
            } else {
                keyData = appCursor ? EscapeSequences.rightApp : EscapeSequences.right
            }

        case .keyboardPageUp:   keyData = EscapeSequences.pageUp
        case .keyboardPageDown: keyData = EscapeSequences.pageDown

        case .keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4, .keyboardF5, .keyboardF6,
             .keyboardF7, .keyboardF8, .keyboardF9, .keyboardF10, .keyboardF11, .keyboardF12:
            let index = key.keyCode.rawValue - UIKeyboardHIDUsage.keyboardF1.rawValue
            keyData = index >= 0 && index < EscapeSequences.fn.count ? EscapeSequences.fn[index] : []

        default:
            keyData = Array(key.characters.utf8)
        }

        if keyData.isEmpty {
            return false
        }

        // Ctrl: translate to control codes.
        if key.modifierFlags.contains(.control) {
            keyData = keyData.map(\.controlCharacter)
        }
        // Meta/Alt: prefix each byte with ESC.
        if key.modifierFlags.contains(.alternate) {
            keyData = keyData.reduce(into: [UInt8]()) { $0 += EscapeSequences.meta + [$1] }
        }

        if TerminalHardwareKeyRepeatPolicy.shouldRepeat(keyCode: key.keyCode,
                                                        modifiers: key.modifierFlags) {
            startRepeatingKey(key.keyCode, bytes: keyData)
        } else {
            onInput?(keyData)
        }
        return true
    }

    private func startRepeatingKey(_ keyCode: UIKeyboardHIDUsage, bytes: [UInt8]) {
        guard repeatingHardwareKey != keyCode else { return }
        hardwareRepeater.stop()
        repeatingHardwareKey = keyCode
        hardwareRepeater.start { [weak self] in
            self?.onInput?(bytes)
        }
    }

    private func stopRepeatingKey(for presses: Set<UIPress>) -> Bool {
        guard let repeatingHardwareKey else { return false }
        let containsRepeatingKey = presses.contains { $0.key?.keyCode == repeatingHardwareKey }
        guard containsRepeatingKey else { return false }
        hardwareRepeater.stop()
        self.repeatingHardwareKey = nil
        return true
    }
}
