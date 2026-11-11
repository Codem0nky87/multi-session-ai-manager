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
    var isLive: Bool = true
    /// Routes bytes to the live PTY (the session's terminal feed).
    let onInputBytes: ([UInt8]) -> Void

    @ObservedObject var voiceEngine: VoiceDictationEngine = .shared
    @Environment(ToastCenter.self) private var toasts: ToastCenter?
    @State private var isVoicePressed = false

    /// Wheel notches per page-key press. Matches roughly a half-page of a
    /// phone-height Herdr pane without flying past the prompt.
    private let pageNotches = 3

    /// Sticky Shift. Neither the phone software keyboard nor the iPad
    /// hardware shift reaches the PTY as a modifier for these keys, yet TUIs
    /// bind real actions to Shift+arrows (Codex opens its queued-message
    /// drawer on Shift+Left). Arming this latches the xterm Shift codings onto
    /// the next arrow/tab press, then disarms.
    @State private var isShiftArmed = false
    @State private var showingFunctionKeys = false

    /// One key of the bar, in canonical left-to-right order. `voice` sits 2nd from the
    /// left (after `esc`) so it avoids both the iPadOS bottom-left corner gesture zone
    /// and the centered Home Indicator bar; `fn` sits 2nd from the right, next to the
    /// keyboard key.
    ///
    /// There is no key for a single chord such as Ctrl-C or Ctrl-/: sticky `ctrl`
    /// followed by the key, on either keyboard, sends any of them.
    enum Key: String, CaseIterable {
        case esc, voice, tab, ctrl, alt
        case shift
        case left, up, down, right
        case pageUp = "pageup"
        case pageDown = "pagedown"
        case functionKeys = "function-keys"
        case keyboard

        var identifier: String {
            self == .functionKeys ? "msam.function-keys" : "msam.quickkey.\(rawValue)"
        }
    }

    static let orderedKeyIdentifiers: [String] = Key.allCases.map(\.identifier)

    // MARK: - Layout

    static let keySpacing: CGFloat = 4
    static let horizontalPadding: CGFloat = 6
    /// The narrowest a key may get. Any narrower and its label ("ctrl", in the bar's
    /// font) no longer fits on one line and the key is too small to hit reliably.
    static let minimumKeyWidth: CGFloat = 36
    /// Height of each row once the keys wrap onto more than one.
    static let wrappedRowHeight: CGFloat = 40

    /// Width the bar needs to show every key on a single row.
    nonisolated static var singleRowMinimumWidth: CGFloat {
        let count = CGFloat(Key.allCases.count)
        return count * minimumKeyWidth + (count - 1) * keySpacing + 2 * horizontalPadding
    }

    /// Rows the keys need in `width` points. A phone held upright cannot give every
    /// key a usable width on one row (they shrank to ~20pt and their labels broke in
    /// two), so there they wrap onto two equal rows. An iPad, or a phone on its side,
    /// keeps the single row and the terminal keeps the height.
    nonisolated static func rowCount(forWidth width: CGFloat) -> Int {
        width >= singleRowMinimumWidth ? 1 : 2
    }

    /// The keys of each row: canonical order, split evenly.
    nonisolated static func keyRows(_ count: Int) -> [[Key]] {
        let keys = Key.allCases
        guard count > 1 else { return [Array(keys)] }
        let perRow = (keys.count + count - 1) / count
        return stride(from: 0, to: keys.count, by: perRow).map {
            Array(keys[$0..<min($0 + perRow, keys.count)])
        }
    }

    /// Total height of the bar for a row count. The terminal above gives up exactly this.
    nonisolated static func height(rows: Int) -> CGFloat {
        rows <= 1
            ? HerdrChromeMetrics.minimumHitTarget
            : CGFloat(rows) * wrappedRowHeight + CGFloat(rows - 1) * keySpacing
    }

    private var isRecordingVoice: Bool {
        if case .listening = voiceEngine.state { return true }
        if case .processing = voiceEngine.state { return true }
        return isVoicePressed
    }

    var body: some View {
        // Decided inside the layout pass, from the width actually offered: the first
        // arrangement whose keys all keep `minimumKeyWidth` wins.
        ViewThatFits(in: .horizontal) {
            keyGrid(rows: 1).frame(minWidth: Self.singleRowMinimumWidth)
            keyGrid(rows: 2)
        }
        .background(HerdrTheme.panel)
        .overlay(alignment: .top) {
            // Floats just above the bar, whatever its height.
            VoiceTranscriptionHUD(engine: voiceEngine)
                .alignmentGuide(.top) { $0[.bottom] + 10 }
        }
        .onChange(of: voiceEngine.state) { _, newState in
            if case .error(let msg) = newState {
                toasts?.error(msg)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("msam.quickkeys")
    }

    private func keyGrid(rows count: Int) -> some View {
        let rows = Self.keyRows(count)
        return VStack(spacing: Self.keySpacing) {
            ForEach(rows.indices, id: \.self) { index in
                HStack(spacing: Self.keySpacing) {
                    ForEach(rows[index], id: \.self) { key in
                        keyView(key)
                    }
                }
                .frame(height: count > 1 ? Self.wrappedRowHeight : HerdrChromeMetrics.minimumHitTarget)
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
    }

    @ViewBuilder
    private func keyView(_ key: Key) -> some View {
        switch key {
        case .esc:
            textKey("esc", id: "esc") {
                isShiftArmed = false
                controller.disarmAlt()
                send(EscapeSequences.meta)
            }
        case .voice:
            voiceKey
        case .tab:
            textKey("tab", id: "tab") {
                if isShiftArmed {
                    isShiftArmed = false
                    send(EscapeSequences.backtab)
                } else if controller.isAltArmed {
                    controller.disarmAlt()
                    send(EscapeSequences.meta + EscapeSequences.tab)
                } else {
                    send(EscapeSequences.tab)
                }
            }
        case .ctrl:
            textKey("ctrl", id: "ctrl", active: controller.isCtrlArmed) {
                controller.toggleCtrl()
            }
        case .alt:
            textKey("alt", id: "alt", active: controller.isAltArmed) {
                controller.toggleAlt()
            }
        case .shift:
            symbolKey("shift", id: "shift", active: isShiftArmed) {
                isShiftArmed.toggle()
            }
            .accessibilityLabel("shift")
        case .left:
            symbolKey("arrow.left", id: "left") {
                if controller.isAltArmed {
                    controller.disarmAlt()
                    send(EscapeSequences.meta + EscapeSequences.leftMeta)
                } else {
                    send(shifted(emulator.applicationCursor ? EscapeSequences.leftShiftApp : EscapeSequences.leftShift,
                                 plain: emulator.applicationCursor ? EscapeSequences.leftApp : EscapeSequences.left))
                }
            }
        case .up:
            symbolKey("arrow.up", id: "up") {
                if controller.isAltArmed {
                    controller.disarmAlt()
                    send(EscapeSequences.meta + (emulator.applicationCursor ? EscapeSequences.upApp : EscapeSequences.up))
                } else {
                    send(shifted(emulator.applicationCursor ? EscapeSequences.upShiftApp : EscapeSequences.upShift,
                                 plain: emulator.applicationCursor ? EscapeSequences.upApp : EscapeSequences.up))
                }
            }
        case .down:
            symbolKey("arrow.down", id: "down") {
                if controller.isAltArmed {
                    controller.disarmAlt()
                    send(EscapeSequences.meta + (emulator.applicationCursor ? EscapeSequences.downApp : EscapeSequences.down))
                } else {
                    send(shifted(emulator.applicationCursor ? EscapeSequences.downShiftApp : EscapeSequences.downShift,
                                 plain: emulator.applicationCursor ? EscapeSequences.downApp : EscapeSequences.down))
                }
            }
        case .right:
            symbolKey("arrow.right", id: "right") {
                if controller.isAltArmed {
                    controller.disarmAlt()
                    send(EscapeSequences.meta + EscapeSequences.rightMeta)
                } else {
                    send(shifted(emulator.applicationCursor ? EscapeSequences.rightShiftApp : EscapeSequences.rightShift,
                                 plain: emulator.applicationCursor ? EscapeSequences.rightApp : EscapeSequences.right))
                }
            }
        case .pageUp:
            symbolKey("chevron.compact.up", id: "pageup") { page(up: true) }
        case .pageDown:
            symbolKey("chevron.compact.down", id: "pagedown") { page(up: false) }
        case .functionKeys:
            textKey("fn", id: "msam.function-keys", active: showingFunctionKeys, disabled: !isLive) {
                showingFunctionKeys.toggle()
            }
            .popover(isPresented: $showingFunctionKeys) {
                FunctionKeyPalette { number in
                    if let bytes = TerminalFunctionKey.bytes(for: number) {
                        send(bytes)
                    }
                    showingFunctionKeys = false
                }
                .presentationCompactAdaptation(.popover)
            }
        case .keyboard:
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
    }

    private var voiceKey: some View {
        Button(action: {}) {
            Image(systemName: "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isRecordingVoice ? Color.white : (isLive ? HerdrTheme.subtext : HerdrTheme.muted))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    isRecordingVoice ? Color.red.opacity(0.85) : HerdrTheme.selection,
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isLive)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard isLive else { return }
                    if !isVoicePressed {
                        isVoicePressed = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        Task {
                            await voiceEngine.startRecording()
                        }
                    }
                }
                .onEnded { value in
                    guard isLive, isVoicePressed else { return }
                    isVoicePressed = false

                    if abs(value.translation.height) > 50 || abs(value.translation.width) > 50 {
                        UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        voiceEngine.cancelRecording()
                    } else {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        Task {
                            if let text = await voiceEngine.stopRecording() {
                                let bytes = VoiceDictationEngine.convertTextToTerminalBytes(text)
                                send(bytes)
                            }
                        }
                    }
                }
        )
        .accessibilityLabel("Push-to-talk voice input")
        .accessibilityIdentifier("msam.quickkey.voice")
    }

    private func send(_ bytes: [UInt8]) {
        onInputBytes(bytes)
    }

    /// If sticky Shift is armed, send the Shift coding and disarm; otherwise
    /// the plain sequence.
    private func shifted(_ shift: [UInt8], plain: [UInt8]) -> [UInt8] {
        if isShiftArmed {
            isShiftArmed = false
            return shift
        }
        return plain
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

    private func textKey(_ label: String, id: String, active: Bool = false, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(HerdrTheme.mono(.footnote, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(disabled ? HerdrTheme.muted : (active ? HerdrTheme.background : HerdrTheme.subtext))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(active ? HerdrTheme.accent : HerdrTheme.selection,
                            in: RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id.contains(".") ? id : "msam.quickkey.\(id)")
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
