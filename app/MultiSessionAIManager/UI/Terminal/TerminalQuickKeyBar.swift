//
//  TerminalQuickKeyBar.swift
//  MultiSessionAIManager
//
//  The bar under the terminal: one floating pill of icon buttons. A terminal
//  without Esc / arrows / Ctrl / Tab is barely a terminal at all, and the iOS
//  keyboard offers none of them, so the app supplies its own. What is on the
//  bar and what each button types is `TerminalKeyBar`; this file draws it.
//
//  The buttons scroll sideways where they do not fit (a phone, a narrow
//  window). The two at the right end stay put: the sliders open the app's
//  settings, where the buttons to show are chosen, and the arrow collapses the
//  bar to a small pill in the corner, which gives its rows back to the terminal.
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
    /// The terminal's modal text selection, for the clipboard button.
    var selection: TerminalSelectionModel? = nil
    /// The host this terminal belongs to, for the password button.
    var hostID: UUID? = nil
    var hostName: String = ""
    /// What is already kept clear below the bar: the keyboard, or a phone's home strip.
    var clearedInset: CGFloat = 0
    var windowHomeInset: CGFloat = 0
    /// The app's own actions, which used to be buttons in the top bar.
    var app = TerminalBarAppActions()
    /// Routes bytes to the live PTY (the session's terminal feed).
    let onInputBytes: ([UInt8]) -> Void

    @ObservedObject var voiceEngine: VoiceDictationEngine = .shared
    @Environment(ToastCenter.self) private var toasts: ToastCenter?
    @AppStorage(TerminalKeyBar.collapsedKey) private var isCollapsed = false
    @AppStorage(TerminalKeyBar.hiddenKey) private var hiddenStored = ""
    @State private var passwordKey = HostTerminalPasswordKey()
    @State private var isVoicePressed = false
    /// Falls back to false by itself when the touch is taken away (the row
    /// scrolled under the finger), which `onEnded` is not told about.
    @GestureState private var isVoiceTouched = false

    /// Wheel notches per page-key press. Matches roughly a half-page of a
    /// phone-height Herdr pane without flying past the prompt.
    private let pageNotches = 3

    /// Sticky Shift. Neither the phone software keyboard nor the iPad
    /// hardware shift reaches the PTY as a modifier for these keys, yet TUIs
    /// bind real actions to Shift+arrows (Codex opens its queued-message
    /// drawer on Shift+Left). Arming this latches the xterm Shift codings onto
    /// the next arrow/tab press, then disarms.
    @State private var isShiftArmed = false

    /// What a button has opened above the bar.
    private enum Panel: Equatable {
        case clipboard, shortcuts, functionKeys, password
    }
    @State private var panel: Panel?

    private var isPhone: Bool { UIDevice.current.userInterfaceIdiom == .phone }
    private var keyWidth: CGFloat { TerminalKeyBarMetrics.keyWidth(isPhone: isPhone) }
    private var pillShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: TerminalKeyBarMetrics.pillHeight / 2, style: .continuous)
    }

    private var isRecordingVoice: Bool {
        if case .listening = voiceEngine.state { return true }
        if case .processing = voiceEngine.state { return true }
        return isVoicePressed
    }

    var body: some View {
        Group {
            if isCollapsed {
                collapsedPill
            } else {
                openPill
            }
        }
        .padding(.horizontal, TerminalKeyBarMetrics.sideMargin(isPhone: isPhone))
        .padding(.top, TerminalKeyBarMetrics.topGap)
        .padding(.bottom, TerminalKeyBarMetrics.bottomGap(clearedInset: clearedInset,
                                                         windowHomeInset: windowHomeInset))
        .frame(maxWidth: isCollapsed ? nil : .infinity, alignment: .leading)
        .overlay(alignment: isCollapsed ? .topLeading : .top) {
            // Floats just above the bar. Over a collapsed bar it starts where
            // the small pill does, so what is being said is not pushed off the
            // side of the screen.
            VoiceTranscriptionHUD(engine: voiceEngine)
                .padding(.leading, isCollapsed ? TerminalKeyBarMetrics.sideMargin(isPhone: isPhone) : 0)
                .alignmentGuide(.top) { $0[.bottom] + 10 }
        }
        .onChange(of: voiceEngine.state) { _, newState in
            if case .error(let msg) = newState {
                toasts?.error(msg)
            }
        }
        .onChange(of: isVoiceTouched) { _, touched in
            // The touch went away without ending: nothing was said on purpose.
            if !touched, isVoicePressed {
                isVoicePressed = false
                voiceEngine.cancelRecording()
            }
        }
        .task(id: hostID) {
            if let hostID { passwordKey.refresh(for: hostID) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("msam.quickkeys")
    }

    // MARK: - The pill

    private var openPill: some View {
        let groups = TerminalKeyBar.groups(
            hiding: TerminalKeyBar.hidden(from: hiddenStored)
                .union(TerminalKeyBar.unavailable(canSendFile: app.sendFile != nil,
                                                  hasIntelligence: app.toggleIntelligence != nil)))
        return HStack(spacing: 0) {
            // Where every button fits (an iPad) the row is a plain row: nothing
            // competes with a held button for the touch. Where it does not, it
            // scrolls sideways.
            ViewThatFits(in: .horizontal) {
                keyRow(groups)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ScrollView(.horizontal, showsIndicators: false) {
                    keyRow(groups)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                // Buttons that do not fit fade out at the edge instead of being
                // cut in half: it says there are more that way.
                .mask(
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: 16)
                    }
                )
            }

            // The app's settings, which is also where the buttons to show are
            // chosen. Always here, so nothing hidden is ever out of reach. It
            // keeps the sliders icon the bar has had from the start.
            if let openSettings = app.openSettings {
                iconButton(TerminalKeyBar.settingsSymbol, name: "MSAM settings", id: "msam.settings",
                           action: openSettings)
                    .frame(width: keyWidth, height: TerminalKeyBarMetrics.pillHeight)
            }

            iconButton("chevron.compact.left", name: "Collapse the bar", id: "msam.quickkey.collapse") {
                withAnimation(.easeInOut(duration: 0.2)) { isCollapsed = true }
            }
            .frame(width: 34, height: TerminalKeyBarMetrics.pillHeight)
            .padding(.trailing, 8)
        }
        .frame(height: TerminalKeyBarMetrics.pillHeight)
        .background(pillShape.fill(TerminalKeyBarStyle.fill))
        .clipShape(pillShape)
        .overlay(pillShape.strokeBorder(TerminalKeyBarStyle.edge, lineWidth: 1))
    }

    /// The buttons in their groups, a wider gap between one group and the next.
    private func keyRow(_ groups: [[TerminalBarKey]]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                if index > 0 {
                    Color.clear.frame(width: TerminalKeyBarMetrics.groupGap)
                }
                ForEach(group, id: \.self) { key in
                    keyView(key)
                        .frame(width: keyWidth, height: TerminalKeyBarMetrics.pillHeight)
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 4)
    }

    /// What is left of a collapsed bar: the keyboard, the microphone, and the way back.
    private var collapsedPill: some View {
        HStack(spacing: 0) {
            ForEach(TerminalKeyBar.collapsedKeys(hiding: TerminalKeyBar.hidden(from: hiddenStored)),
                    id: \.self) { key in
                keyView(key)
                    .frame(width: keyWidth, height: TerminalKeyBarMetrics.pillHeight)
            }
            iconButton("chevron.compact.right", name: "Show the bar", id: "msam.quickkey.expand") {
                withAnimation(.easeInOut(duration: 0.2)) { isCollapsed = false }
            }
            .frame(width: 34, height: TerminalKeyBarMetrics.pillHeight)
        }
        .padding(.leading, 6)
        .padding(.trailing, 8)
        .background(pillShape.fill(TerminalKeyBarStyle.fill))
        .clipShape(pillShape)
        .overlay(pillShape.strokeBorder(TerminalKeyBarStyle.edge, lineWidth: 1))
    }

    // MARK: - The buttons

    @ViewBuilder
    private func keyView(_ key: TerminalBarKey) -> some View {
        switch key {
        case .keyboard:
            keyButton(key, symbol: keyboard.isVisible ? "keyboard.chevron.compact.down" : "keyboard") {
                if keyboard.isVisible {
                    controller.blur()
                } else {
                    controller.focus()
                }
            }
        case .voice:
            voiceKey
        case .esc, .tab, .enter, .up, .down, .left, .right, .home, .end:
            keyButton(key) { press(key) }
        case .shift:
            keyButton(key, symbol: isShiftArmed ? "shift.fill" : key.symbol, active: isShiftArmed) {
                isShiftArmed.toggle()
            }
        case .ctrl:
            keyButton(key, active: controller.isCtrlArmed) { controller.toggleCtrl() }
        case .alt:
            keyButton(key, active: controller.isAltArmed) { controller.toggleAlt() }
        case .pageUp:
            keyButton(key) { page(up: true) }
        case .pageDown:
            keyButton(key) { page(up: false) }
        case .clipboard:
            keyButton(key, active: panel == .clipboard || selection?.isSelecting == true) {
                panel = .clipboard
            }
            .popover(isPresented: showing(.clipboard)) {
                TerminalClipboardPanel(selection: selection, canPaste: isLive) { bytes in
                    send(bytes)
                } close: {
                    panel = nil
                }
                .presentationCompactAdaptation(.popover)
            }
        case .shortcuts:
            keyButton(key, active: panel == .shortcuts, disabled: !isLive) {
                panel = .shortcuts
            }
            .popover(isPresented: showing(.shortcuts)) {
                TerminalShortcutPalette { shortcut in
                    send(shortcut.bytes)
                    panel = nil
                }
                .presentationCompactAdaptation(.popover)
            }
        case .functionKeys:
            keyButton(key, active: panel == .functionKeys, disabled: !isLive) {
                panel = .functionKeys
            }
            .popover(isPresented: showing(.functionKeys)) {
                FunctionKeyPalette { number in
                    if let bytes = TerminalFunctionKey.bytes(for: number) {
                        send(bytes)
                    }
                    panel = nil
                }
                .presentationCompactAdaptation(.popover)
            }
        case .password:
            passwordButton
        case .attach:
            // Live sessions only: the upload rides the session's own SSH
            // connection, and the path is typed into its terminal.
            keyButton(key, disabled: !isLive) { app.sendFile?() }
        case .intelligence:
            keyButton(key, active: app.isIntelligenceShown) { app.toggleIntelligence?() }
        }
    }

    /// Types the host's saved password after the device owner has been asked, or
    /// offers to save one. Press and hold to replace or forget it.
    private var passwordButton: some View {
        let saved = hostID.map(passwordKey.isSaved(for:)) ?? false
        return keyButton(.password, active: panel == .password, disabled: !isLive || hostID == nil) {
            guard let hostID else { return }
            if saved {
                typePassword(for: hostID)
            } else {
                panel = .password
            }
        }
        .contextMenu {
            if saved, let hostID {
                Button("Replace saved password…") { panel = .password }
                Button("Forget saved password", role: .destructive) {
                    passwordKey.forget(for: hostID)
                    toasts?.info("The saved password for \(hostName) is forgotten.")
                }
            }
        }
        .popover(isPresented: showing(.password)) {
            HostTerminalPasswordForm(hostName: hostName, isReplacing: saved) { password in
                guard let hostID else { return "There is no host to save it for." }
                let failure = passwordKey.save(password, for: hostID)
                if failure == nil {
                    panel = nil
                    toasts?.success("Saved. Tap the key button to type it.")
                }
                return failure
            } cancel: {
                panel = nil
            }
            .presentationCompactAdaptation(.popover)
        }
    }

    private func typePassword(for hostID: UUID) {
        Task {
            let outcome = await passwordKey.type(for: hostID, named: hostName) { send($0) }
            if case .failed(let text) = outcome {
                toasts?.error(text)
            }
        }
    }

    private var voiceKey: some View {
        Button(action: {}) {
            Image(systemName: isRecordingVoice ? "mic.fill" : "mic")
                .font(.system(size: TerminalKeyBarStyle.symbolSize, weight: .regular))
                .foregroundStyle(isRecordingVoice ? Color.white : (isLive ? HerdrTheme.text : HerdrTheme.muted))
        }
        .buttonStyle(TerminalKeyBarButtonStyle(highlight: isRecordingVoice ? Color.red.opacity(0.85) : nil))
        .disabled(!isLive)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .updating($isVoiceTouched) { _, touched, _ in touched = true }
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
        .accessibilityIdentifier(TerminalBarKey.voice.identifier)
    }

    // MARK: - What the buttons do

    private func send(_ bytes: [UInt8]) {
        onInputBytes(bytes)
    }

    /// A button that types: with sticky Shift or Alt where one is armed.
    private func press(_ key: TerminalBarKey) {
        guard let press = TerminalBarKeyPress.of(key, shift: isShiftArmed, alt: controller.isAltArmed,
                                                 applicationCursor: emulator.applicationCursor) else { return }
        if press.clearsShift { isShiftArmed = false }
        if press.clearsAlt { controller.disarmAlt() }
        send(press.bytes)
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

    private func showing(_ which: Panel) -> Binding<Bool> {
        Binding(get: { panel == which },
                set: { isShown in
                    if isShown { panel = which } else if panel == which { panel = nil }
                })
    }

    // MARK: - Drawing a button

    private func keyButton(_ key: TerminalBarKey, symbol: String? = nil, active: Bool = false,
                           disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            TerminalBarKeyIcon(key: key, symbol: symbol)
                .foregroundStyle(disabled ? HerdrTheme.muted : (active ? HerdrTheme.accent : HerdrTheme.text))
        }
        .buttonStyle(TerminalKeyBarButtonStyle(highlight: active ? HerdrTheme.selection : nil))
        .disabled(disabled)
        .accessibilityLabel(key.name)
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier(key.identifier)
    }

    /// One of the bar's own two buttons at its right end.
    private func iconButton(_ symbol: String, name: String, id: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: TerminalKeyBarStyle.symbolSize, weight: .regular))
                .foregroundStyle(active ? HerdrTheme.accent : HerdrTheme.text)
        }
        .buttonStyle(TerminalKeyBarButtonStyle(highlight: active ? HerdrTheme.selection : nil))
        .accessibilityLabel(name)
        .accessibilityIdentifier(id)
    }
}

/// What the app's own buttons on the bar do. A button with nothing behind it
/// is not drawn.
struct TerminalBarAppActions {
    var sendFile: (() -> Void)?
    var toggleIntelligence: (() -> Void)?
    var isIntelligenceShown = false
    var openSettings: (() -> Void)?
}

/// The pill's colours.
enum TerminalKeyBarStyle {
    /// A shade above the terminal's background, so the pill reads as floating on it.
    static let fill = HerdrTheme.activeRow
    static let edge = Color.white.opacity(0.10)
    static let symbolSize: CGFloat = 19
}

/// A bare icon that fills its slot, lights up under a finger, and can carry a
/// standing highlight (an armed modifier, an open panel).
private struct TerminalKeyBarButtonStyle: ButtonStyle {
    var highlight: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(highlight ?? (configuration.isPressed ? Color.white.opacity(0.14) : Color.clear))
                    .padding(.horizontal, 3)
                    .padding(.vertical, 5)
            )
            .contentShape(Rectangle())
    }
}

/// A button's icon, as the bar and the list of buttons both draw it.
struct TerminalBarKeyIcon: View {
    let key: TerminalBarKey
    /// Another symbol for the same button: the keyboard button while the keyboard is up.
    var symbol: String? = nil
    /// What the icon stands on, for the cut-out behind a badge.
    var ground: Color = TerminalKeyBarStyle.fill

    var body: some View {
        Group {
            switch key {
            case .shortcuts:
                TerminalKeyBarBadge(ground: ground) { Image(systemName: key.symbol) }
            case .functionKeys:
                TerminalKeyBarBadge(ground: ground) { TerminalKeyBarFunctionIcon() }
            default:
                Image(systemName: symbol ?? key.symbol)
            }
        }
        .font(.system(size: TerminalKeyBarStyle.symbolSize, weight: .regular))
    }
}

/// An icon with the small "send" arrow at its corner: these buttons send keys
/// rather than being one.
private struct TerminalKeyBarBadge<Icon: View>: View {
    let ground: Color
    @ViewBuilder var icon: Icon

    var body: some View {
        icon.overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrowshape.turn.up.right.fill")
                .font(.system(size: 9, weight: .bold))
                .padding(1.5)
                // Cuts the icon away behind the arrow.
                .background(ground, in: Circle())
                .offset(x: 5, y: 4)
        }
    }
}

/// "F1" on a key cap. The system has no symbol for it.
private struct TerminalKeyBarFunctionIcon: View {
    var body: some View {
        Text("F1")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .frame(width: 21, height: 18)
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(lineWidth: 1.4))
    }
}
