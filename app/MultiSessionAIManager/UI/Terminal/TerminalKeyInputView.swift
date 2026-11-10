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
    /// Sticky Ctrl from the quick-key bar: armed, the next key -- typed on the
    /// software keyboard OR pressed on a hardware one -- is sent as its control
    /// code and the latch disarms.
    var ctrlLatchArmed = false
    /// Sticky Alt/Meta from the quick-key bar: armed, the next key (software or
    /// hardware) is prefixed with ESC (`\u{1b}`) and the latch disarms.
    var altLatchArmed = false
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
        var data = text.utf8.map { character -> UInt8 in
            // Convert newline to carriage return for the shell.
            character == 0x0A ? EscapeSequences.return.first! : character
        }
        if ctrlLatchArmed {
            data = data.map(\.controlCharacter)
            ctrlLatchArmed = false
            onCtrlLatchChanged?(false)
        }
        if altLatchArmed {
            // One ESC for the whole insert: a multi-byte character is still one key.
            data = EscapeSequences.meta + data
            altLatchArmed = false
            onAltLatchChanged?(false)
        }
        onInput?(data)
    }

    func deleteBackward() {
        if ctrlLatchArmed || altLatchArmed {
            // Ctrl/Alt-Backspace: delete word backwards (readline convention).
            if ctrlLatchArmed {
                ctrlLatchArmed = false
                onCtrlLatchChanged?(false)
            }
            if altLatchArmed {
                altLatchArmed = false
                onAltLatchChanged?(false)
            }
            onInput?(EscapeSequences.meta + EscapeSequences.backspace)
            return
        }
        onInput?(EscapeSequences.backspace)
    }

    /// Reports sticky-Ctrl state changes so the quick-key bar can light up.
    var onCtrlLatchChanged: ((Bool) -> Void)?
    /// Reports sticky-Alt state changes so the quick-key bar can light up.
    var onAltLatchChanged: ((Bool) -> Void)?

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
        handleHardwareKey(keyCode: key.keyCode,
                          characters: key.characters,
                          modifierFlags: key.modifierFlags)
    }

    /// Translates one hardware key press into terminal bytes. Takes the `UIKey`
    /// fields rather than the `UIKey` (which has no public initialiser) so tests
    /// can drive it. Returns false when UIKit should handle the press instead.
    ///
    /// A hardware key never reaches `insertText`, so the quick-key bar's sticky
    /// Ctrl / Alt have to be honoured here as well: an armed latch counts as that
    /// modifier being held for exactly this one key.
    func handleHardwareKey(keyCode: UIKeyboardHIDUsage,
                           characters: String,
                           modifierFlags: UIKeyModifierFlags) -> Bool {
        // Let UIKit handle cmd shortcuts.
        if modifierFlags.contains(.command) {
            return false
        }

        let appCursor = applicationCursorProvider()
        let shiftHeld = modifierFlags.contains(.shift)
        let ctrlActive = modifierFlags.contains(.control) || ctrlLatchArmed
        let altActive = modifierFlags.contains(.alternate) || altLatchArmed
        // Only a character key has a control-code form; a special key's escape
        // sequence must reach the PTY intact.
        var isCharacterKey = false
        var keyData: [UInt8]
        switch keyCode {
        case .keyboardReturnOrEnter:     keyData = EscapeSequences.return
        case .keyboardEscape:            keyData = EscapeSequences.meta
        case .keyboardDeleteOrBackspace: keyData = EscapeSequences.backspace
        case .keyboardDeleteForward:     keyData = EscapeSequences.delete
        case .keyboardTab:               keyData = shiftHeld ? EscapeSequences.backtab : EscapeSequences.tab

        case .keyboardHome: keyData = appCursor ? EscapeSequences.homeApp : EscapeSequences.home
        case .keyboardEnd:  keyData = appCursor ? EscapeSequences.endApp : EscapeSequences.end

        case .keyboardUpArrow:
            keyData = shiftHeld
                ? (appCursor ? EscapeSequences.upShiftApp : EscapeSequences.upShift)
                : (appCursor ? EscapeSequences.upApp : EscapeSequences.up)
        case .keyboardDownArrow:
            keyData = shiftHeld
                ? (appCursor ? EscapeSequences.downShiftApp : EscapeSequences.downShift)
                : (appCursor ? EscapeSequences.downApp : EscapeSequences.down)

        case .keyboardLeftArrow:
            if altActive {
                keyData = EscapeSequences.leftMeta
            } else if shiftHeld {
                keyData = appCursor ? EscapeSequences.leftShiftApp : EscapeSequences.leftShift
            } else {
                keyData = appCursor ? EscapeSequences.leftApp : EscapeSequences.left
            }
        case .keyboardRightArrow:
            if altActive {
                keyData = EscapeSequences.rightMeta
            } else if shiftHeld {
                keyData = appCursor ? EscapeSequences.rightShiftApp : EscapeSequences.rightShift
            } else {
                keyData = appCursor ? EscapeSequences.rightApp : EscapeSequences.right
            }

        case .keyboardPageUp:   keyData = EscapeSequences.pageUp
        case .keyboardPageDown: keyData = EscapeSequences.pageDown

        case .keyboardF1, .keyboardF2, .keyboardF3, .keyboardF4, .keyboardF5, .keyboardF6,
             .keyboardF7, .keyboardF8, .keyboardF9, .keyboardF10, .keyboardF11, .keyboardF12:
            let index = keyCode.rawValue - UIKeyboardHIDUsage.keyboardF1.rawValue
            keyData = TerminalFunctionKey.bytes(for: index + 1) ?? []

        default:
            keyData = Array(characters.utf8)
            isCharacterKey = true
        }

        // A bare modifier going down (Shift, on its way to a capital) carries no
        // text. It is not "the next key", so it must leave an armed latch armed.
        if keyData.isEmpty {
            return false
        }

        if ctrlLatchArmed {
            ctrlLatchArmed = false
            onCtrlLatchChanged?(false)
        }
        if altLatchArmed {
            altLatchArmed = false
            onAltLatchChanged?(false)
        }

        if keyCode == .keyboardDeleteOrBackspace && (ctrlActive || altActive) {
            // Ctrl/Alt-Backspace: delete word backwards, as `deleteBackward` does.
            keyData = EscapeSequences.meta + EscapeSequences.backspace
        } else {
            // Ctrl: translate to control codes.
            if ctrlActive && isCharacterKey {
                keyData = keyData.map(\.controlCharacter)
            }
            // Meta/Alt: one ESC in front of the key's whole sequence.
            if altActive {
                keyData = EscapeSequences.meta + keyData
            }
        }

        if TerminalHardwareKeyRepeatPolicy.shouldRepeat(keyCode: keyCode,
                                                        modifiers: modifierFlags) {
            startRepeatingKey(keyCode, bytes: keyData)
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
