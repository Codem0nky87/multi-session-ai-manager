import Testing
import UIKit
@testable import MultiSessionAIManager

/// The terminal's keyboard and another field's: who has it after the app was away.
@Suite(.serialized) @MainActor struct TerminalKeyboardYieldTests {
    private struct Screen {
        let window: UIWindow
        let terminal: TerminalKeyInputView
        let field: UITextField
        let controller: KeyInputController
    }

    private func screen() throws -> Screen {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        let terminal = TerminalKeyInputView(frame: CGRect(x: 0, y: 0, width: 400, height: 200))
        let field = UITextField(frame: CGRect(x: 0, y: 220, width: 400, height: 40))
        root.view.addSubview(terminal)
        root.view.addSubview(field)
        let controller = KeyInputController()
        controller.view = terminal
        return Screen(window: window, terminal: terminal, field: field, controller: controller)
    }

    @Test func theTerminalDoesNotTakeTheKeyboardFromAFieldThatTookItSince() throws {
        // Typed in the terminal, then in the page of a browser space; then the
        // app was away for a moment (another app, a password prompt).
        let screen = try screen()
        defer { screen.window.isHidden = true }
        screen.controller.focus()
        try #require(screen.terminal.isFirstResponder)
        try #require(screen.field.becomeFirstResponder())

        screen.controller.suspendForDeactivation()
        screen.controller.restoreAfterActivation()

        #expect(screen.field.isFirstResponder, "What is typed next belongs to the field")
        #expect(!screen.terminal.isFirstResponder)
        #expect(!screen.controller.isFocusRequested)
    }

    @Test func theTerminalGetsItsKeyboardBackWhenItHadIt() throws {
        let screen = try screen()
        defer { screen.window.isHidden = true }
        screen.controller.focus()
        try #require(screen.terminal.isFirstResponder)

        screen.controller.suspendForDeactivation()
        #expect(!screen.terminal.isFirstResponder)
        screen.controller.restoreAfterActivation()

        #expect(screen.terminal.isFirstResponder)
    }

    @Test func aFieldThatTookTheKeyboardWhileTheAppWasAwayKeepsIt() throws {
        let screen = try screen()
        defer { screen.window.isHidden = true }
        screen.controller.focus()
        try #require(screen.terminal.isFirstResponder)

        screen.controller.suspendForDeactivation()
        try #require(screen.field.becomeFirstResponder())
        screen.controller.restoreAfterActivation()

        #expect(screen.field.isFirstResponder)
    }
}
