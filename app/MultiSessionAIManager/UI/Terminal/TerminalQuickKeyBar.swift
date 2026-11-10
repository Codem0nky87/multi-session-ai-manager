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
    @ObservedObject private var dictationSettings: VoiceDictationSettings = .shared
    @ObservedObject private var whisperManager: WhisperModelManager = .shared
    @Environment(ToastCenter.self) private var toasts: ToastCenter?
    @State private var isVoicePressed = false
    @State private var showingSpeechModelPrompt = false

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

    /// Canonical left-to-right key order. `voice` sits 2nd from the left (after `esc`)
    /// so it avoids both the iPadOS bottom-left corner gesture zone and the centered Home Indicator bar.
    static let orderedKeyIdentifiers: [String] = [
        "msam.quickkey.esc",
        "msam.quickkey.voice",
        "msam.quickkey.tab",
        "msam.quickkey.ctrl",
        "msam.quickkey.alt",
        "msam.quickkey.ctrl-slash",
        "msam.quickkey.ctrl-c",
        "msam.quickkey.shift",
        "msam.function-keys",
        "msam.quickkey.left",
        "msam.quickkey.up",
        "msam.quickkey.down",
        "msam.quickkey.right",
        "msam.quickkey.pageup",
        "msam.quickkey.pagedown",
        "msam.quickkey.keyboard",
    ]

    private var isRecordingVoice: Bool {
        if case .listening = voiceEngine.state { return true }
        if case .processing = voiceEngine.state { return true }
        return isVoicePressed
    }

    private var dictationAvailability: VoiceDictationAvailability {
        .resolve(languageMode: dictationSettings.languageMode, modelState: whisperManager.state)
    }

    /// True while the mic key cannot record because something the chosen language
    /// needs is not on the device yet. A recording already in flight wins: the model
    /// reports `.loading` while it transcribes, and that must not grey the key out.
    private var isDictationBlocked: Bool {
        !dictationAvailability.isReady && !isRecordingVoice
    }

    var body: some View {
        HStack(spacing: 4) {
            textKey("esc", id: "esc") {
                isShiftArmed = false
                controller.disarmAlt()
                send(EscapeSequences.meta)
            }

            voiceKey

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
            textKey("ctrl", id: "ctrl", active: controller.isCtrlArmed) {
                controller.toggleCtrl()
            }
            textKey("alt", id: "alt", active: controller.isAltArmed) {
                controller.toggleAlt()
            }
            textKey("^/", id: "ctrl-slash") {
                send(EscapeSequences.ctrlSlash)
            }
            textKey("^c", id: "ctrl-c") {
                send(EscapeSequences.ctrlC)
            }
            symbolKey("shift", id: "shift", active: isShiftArmed) {
                isShiftArmed.toggle()
            }
            .accessibilityLabel("shift")

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

            symbolKey("arrow.left", id: "left") {
                if controller.isAltArmed {
                    controller.disarmAlt()
                    send(EscapeSequences.meta + EscapeSequences.leftMeta)
                } else {
                    send(shifted(emulator.applicationCursor ? EscapeSequences.leftShiftApp : EscapeSequences.leftShift,
                                 plain: emulator.applicationCursor ? EscapeSequences.leftApp : EscapeSequences.left))
                }
            }
            symbolKey("arrow.up", id: "up") {
                if controller.isAltArmed {
                    controller.disarmAlt()
                    send(EscapeSequences.meta + (emulator.applicationCursor ? EscapeSequences.upApp : EscapeSequences.up))
                } else {
                    send(shifted(emulator.applicationCursor ? EscapeSequences.upShiftApp : EscapeSequences.upShift,
                                 plain: emulator.applicationCursor ? EscapeSequences.upApp : EscapeSequences.up))
                }
            }
            symbolKey("arrow.down", id: "down") {
                if controller.isAltArmed {
                    controller.disarmAlt()
                    send(EscapeSequences.meta + (emulator.applicationCursor ? EscapeSequences.downApp : EscapeSequences.down))
                } else {
                    send(shifted(emulator.applicationCursor ? EscapeSequences.downShiftApp : EscapeSequences.downShift,
                                 plain: emulator.applicationCursor ? EscapeSequences.downApp : EscapeSequences.down))
                }
            }
            symbolKey("arrow.right", id: "right") {
                if controller.isAltArmed {
                    controller.disarmAlt()
                    send(EscapeSequences.meta + EscapeSequences.rightMeta)
                } else {
                    send(shifted(emulator.applicationCursor ? EscapeSequences.rightShiftApp : EscapeSequences.rightShift,
                                 plain: emulator.applicationCursor ? EscapeSequences.rightApp : EscapeSequences.right))
                }
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
        .overlay(alignment: .bottom) {
            VoiceTranscriptionHUD(engine: voiceEngine)
                .offset(y: -HerdrChromeMetrics.minimumHitTarget - 10)
        }
        .onChange(of: voiceEngine.state) { _, newState in
            if case .error(let msg) = newState {
                toasts?.error(msg)
            }
        }
        .speechModelPrompt(isPresented: $showingSpeechModelPrompt)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("msam.quickkeys")
    }

    private var voiceKey: some View {
        let availability = dictationAvailability
        let isBlocked = isDictationBlocked
        return Button(action: {}) {
            Image(systemName: isBlocked ? availability.micKeySymbol : "mic.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isRecordingVoice ? Color.white : (isLive && !isBlocked ? HerdrTheme.subtext : HerdrTheme.muted))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    isRecordingVoice ? Color.red.opacity(0.85) : HerdrTheme.selection.opacity(isBlocked ? 0.45 : 1.0),
                    in: RoundedRectangle(cornerRadius: 6)
                )
                .overlay(alignment: .bottom) {
                    if isBlocked, let fraction = availability.downloadFraction {
                        ProgressView(value: fraction)
                            .progressViewStyle(.linear)
                            .tint(HerdrTheme.accent)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isLive)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard isLive, !isBlocked else { return }
                    if !isVoicePressed {
                        isVoicePressed = true
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        Task {
                            await voiceEngine.startRecording()
                        }
                    }
                }
                .onEnded { value in
                    guard isLive else { return }
                    guard isVoicePressed else {
                        // Nothing was recording, so this was a touch on an unavailable
                        // key: answer it instead of leaving the press unexplained.
                        if isBlocked, abs(value.translation.height) <= 50, abs(value.translation.width) <= 50 {
                            availability.explainUnavailableMicKey(showingPrompt: $showingSpeechModelPrompt, toasts: toasts)
                        }
                        return
                    }
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
        .accessibilityValue(isBlocked ? (availability.statusText ?? "") : "")
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
