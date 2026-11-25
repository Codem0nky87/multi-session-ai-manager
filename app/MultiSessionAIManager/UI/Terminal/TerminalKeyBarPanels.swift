//
//  TerminalKeyBarPanels.swift
//  MultiSessionAIManager
//
//  What the bar's buttons open above it: the clipboard actions, the shortcuts,
//  and the form that saves a host's password.
//

import SwiftUI

/// Select, copy and paste, within reach of the thumb that types.
struct TerminalClipboardPanel: View {
    let selection: TerminalSelectionModel?
    /// Pasting types into the terminal, so it needs a live one.
    let canPaste: Bool
    let paste: ([UInt8]) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Clipboard").font(.headline)
            if let selection {
                row(selection.isSelecting ? "Exit text selection" : "Select text",
                    symbol: selection.isSelecting ? "selection.pin.in.out" : "square.dashed",
                    id: "terminal.clipboard.select") {
                    if selection.isSelecting { selection.exit() } else { selection.isSelecting = true }
                    close()
                }
                row("Copy selection", symbol: "doc.on.doc", id: "terminal.clipboard.copy") {
                    selection.requestCopy()
                    close()
                }
                .disabled(!selection.hasSelection)
                .opacity(selection.hasSelection ? 1 : 0.45)
            }
            // The system's own paste button: it reads the clipboard without the
            // "allow paste" question a plain button would raise every time.
            PasteButton(payloadType: String.self) { strings in
                if let bytes = TerminalClipboard.bytes(pasting: strings) {
                    paste(bytes)
                }
                close()
            }
            .labelStyle(.titleAndIcon)
            .buttonBorderShape(.roundedRectangle(radius: 8))
            .tint(HerdrTheme.selection)
            .disabled(!canPaste)
            .accessibilityIdentifier("terminal.clipboard.paste")
        }
        .padding(16)
        .frame(width: 240, alignment: .leading)
        .foregroundStyle(HerdrTheme.text)
        .background(HerdrTheme.background)
    }

    private func row(_ title: String, symbol: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
                .background(HerdrTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// The chords that mean the same in every shell, one tap each.
struct TerminalShortcutPalette: View {
    let send: (TerminalShortcut) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shortcuts").font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 8) {
                ForEach(TerminalShortcut.all) { shortcut in
                    Button { send(shortcut) } label: {
                        VStack(spacing: 2) {
                            Text(shortcut.label)
                                .font(.system(.callout, design: .monospaced, weight: .semibold))
                            Text(shortcut.meaning)
                                .font(.caption2)
                                .foregroundStyle(HerdrTheme.subtext)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background(HerdrTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Send \(shortcut.label), \(shortcut.meaning)")
                    .accessibilityIdentifier("terminal.shortcut.\(shortcut.label)")
                }
            }
            Text("For any other chord, tap Control and then the key.")
                .font(.caption).foregroundStyle(HerdrTheme.subtext)
        }
        .padding(16)
        .frame(width: 320)
        .foregroundStyle(HerdrTheme.text)
        .background(HerdrTheme.background)
    }
}

/// Saves the password the key button types for this host.
struct HostTerminalPasswordForm: View {
    let hostName: String
    let isReplacing: Bool
    /// Returns what went wrong, or nil once it is saved.
    let save: (String) -> String?
    let cancel: () -> Void

    @State private var password = ""
    @State private var failure: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isReplacing ? "Replace the password for \(hostName)" : "Save a password for \(hostName)")
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text("The key button types it into this host's terminal, at a sudo prompt for one, after Face ID or your passcode. Nothing is typed after it: press Return yourself. It is kept on this device only and cannot be shown again.")
                .font(.caption).foregroundStyle(HerdrTheme.subtext)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("Password", text: $password)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isFocused)
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(HerdrTheme.panel, in: RoundedRectangle(cornerRadius: 8))
                .onSubmit(submit)
                .accessibilityIdentifier("terminal.password.field")
            if let failure {
                Text(failure)
                    .font(.caption).foregroundStyle(HerdrTheme.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("terminal.password.failure")
            }
            HStack {
                Button("Cancel", action: cancel)
                    .accessibilityIdentifier("terminal.password.cancel")
                Spacer()
                Button("Save", action: submit)
                    .fontWeight(.semibold)
                    .disabled(password.isEmpty)
                    .accessibilityIdentifier("terminal.password.save")
            }
            .tint(HerdrTheme.accent)
        }
        .padding(16)
        .frame(width: 320)
        .foregroundStyle(HerdrTheme.text)
        .background(HerdrTheme.background)
        .onAppear { isFocused = true }
    }

    private func submit() {
        failure = save(password)
        if failure == nil { password = "" }
    }
}
