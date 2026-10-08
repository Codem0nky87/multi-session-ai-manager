//
//  TerminalQuickKeyBar.swift
//  MultiSessionAIManager
//
//  The phone (compact-width) quick-key strip pinned above the software
//  keyboard. A phone terminal without Esc / arrows / Ctrl / Tab is barely a
//  terminal at all, and the iOS keyboard offers none of them, so the app
//  supplies its own row. It also carries the keyboard hide/reveal control:
//  dismissing the keyboard returns the terminal to full height so history can
//  be scrolled with a plain swipe.
//
//  Page up / down send scroll-wheel notches at the grid centre while the
//  remote is on its alternate screen (a TUI has no app-side scrollback), and
//  fall back to the xterm page keys otherwise.
//

import SwiftUI

struct TerminalQuickKeyBar: View {
    let emulator: TerminalEmulator
    let controller: KeyInputController
    let keyboard: KeyboardVisibilityModel
    /// Routes bytes to the live PTY (the session's terminal feed).
    let onInputBytes: ([UInt8]) -> Void

    /// Wheel notches per page-key press. Matches roughly a half-page of a
    /// phone-height Herdr pane without flying past the prompt.
    private let pageNotches = 3

    var body: some View {
        HStack(spacing: 4) {
            textKey("esc", id: "esc") { send(EscapeSequences.meta) }
            textKey("tab", id: "tab") { send(EscapeSequences.tab) }
            textKey("ctrl", id: "ctrl", active: controller.isCtrlArmed) {
                controller.toggleCtrl()
            }
            symbolKey("arrow.left", id: "left") {
                send(emulator.applicationCursor ? EscapeSequences.leftApp : EscapeSequences.left)
            }
            symbolKey("arrow.up", id: "up") {
                send(emulator.applicationCursor ? EscapeSequences.upApp : EscapeSequences.up)
            }
            symbolKey("arrow.down", id: "down") {
                send(emulator.applicationCursor ? EscapeSequences.downApp : EscapeSequences.down)
            }
            symbolKey("arrow.right", id: "right") {
                send(emulator.applicationCursor ? EscapeSequences.rightApp : EscapeSequences.right)
            }
            symbolKey("chevron.compact.up", id: "pageup") { page(up: true) }
            symbolKey("chevron.compact.down", id: "pagedown") { page(up: false) }
            symbolKey(keyboard.isVisible ? "keyboard.chevron.compact.down" : "keyboard",
                      id: "keyboard",
                      active: false) {
                if keyboard.isVisible {
                    controller.blur()
                } else {
                    controller.focus()
                }
            }
        }
        .padding(.horizontal, 6)
        .frame(height: HerdrChromeMetrics.minimumHitTarget)
        .background(HerdrTheme.panel)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("msam.quickkeys")
    }

    private func send(_ bytes: [UInt8]) {
        onInputBytes(bytes)
    }

    /// Scroll a page of history. On the alternate screen the remote owns the
    /// scrollback, so send wheel notches at the grid centre (wherever the
    /// remote's pointer routing will accept them). Otherwise fall back to the
    /// xterm page keys, which line-editors and pagers understand.
    private func page(up: Bool) {
        if emulator.isAlternateScreen {
            let col = max(emulator.cols / 2, 0)
            let row = max(emulator.rows / 2, 0)
            var bytes: [UInt8] = []
            bytes.reserveCapacity(pageNotches * 12)
            for _ in 0..<pageNotches {
                bytes += TerminalMouse.wheel(up: up, col: col, row: row)
            }
            send(bytes)
        } else {
            send(up ? EscapeSequences.pageUp : EscapeSequences.pageDown)
        }
    }

    private func textKey(_ label: String, id: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(HerdrTheme.mono(.footnote, weight: .semibold))
                .foregroundStyle(active ? HerdrTheme.background : HerdrTheme.subtext)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(active ? HerdrTheme.accent : HerdrTheme.selection,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityIdentifier("msam.quickkey.\(id)")
    }

    private func symbolKey(_ symbol: String, id: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(active ? HerdrTheme.background : HerdrTheme.subtext)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(active ? HerdrTheme.accent : HerdrTheme.selection,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("msam.quickkey.\(id)")
    }
}
