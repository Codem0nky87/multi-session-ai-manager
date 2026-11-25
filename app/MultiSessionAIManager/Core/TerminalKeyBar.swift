//
//  TerminalKeyBar.swift
//  MultiSessionAIManager
//
//  What is on the bar under the terminal, and what each button types. The bar
//  itself (`TerminalQuickKeyBar`) only draws this and wires it to the session.
//

import CoreGraphics
import Foundation

/// One button of the bar under the terminal.
enum TerminalBarKey: String, CaseIterable, Sendable {
    case keyboard, voice, esc, tab
    case enter = "return"
    case shift, ctrl, alt
    case up, down, left, right, home, end
    case pageUp = "pageup"
    case pageDown = "pagedown"
    case clipboard, shortcuts
    case functionKeys = "function-keys"
    case password

    /// What UI tests find the button by.
    var identifier: String {
        self == .functionKeys ? "msam.function-keys" : "msam.quickkey.\(rawValue)"
    }

    /// What VoiceOver says and what the list of buttons calls it. The icons
    /// carry no text, and Tab and End are drawn with the same arrow.
    var name: String {
        switch self {
        case .keyboard: "Keyboard"
        case .voice: "Voice input"
        case .esc: "Escape"
        case .tab: "Tab"
        case .enter: "Return"
        case .shift: "Shift"
        case .ctrl: "Control"
        case .alt: "Alt"
        case .up: "Up"
        case .down: "Down"
        case .left: "Left"
        case .right: "Right"
        case .home: "Home"
        case .end: "End"
        case .pageUp: "Page up"
        case .pageDown: "Page down"
        case .clipboard: "Clipboard"
        case .shortcuts: "Shortcuts"
        case .functionKeys: "Function keys"
        case .password: "Send password"
        }
    }

    /// The system symbol the button is drawn with. Shortcuts and function keys
    /// carry an arrow badge on top, and function keys a key cap in place of the
    /// symbol: `TerminalBarKeyIcon` draws those.
    var symbol: String {
        switch self {
        case .keyboard, .shortcuts: "keyboard"
        case .voice: "mic"
        case .esc: "escape"
        case .tab, .end: "arrow.right.to.line"
        case .enter: "return"
        case .shift: "shift"
        case .ctrl: "control"
        case .alt: "option"
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .left: "arrow.left"
        case .right: "arrow.right"
        case .home: "arrow.left.to.line"
        case .pageUp: "arrow.up.doc"
        case .pageDown: "arrow.down.doc"
        case .clipboard: "scissors"
        case .functionKeys: "square"
        case .password: "key.radiowaves.forward"
        }
    }
}

enum TerminalKeyBar {
    /// Where the device keeps which buttons are hidden, and whether the bar is collapsed.
    static let hiddenKey = "msam.keybar.hidden"
    static let collapsedKey = "msam.keybar.collapsed"

    /// Left to right as drawn. A wider gap separates one group from the next.
    static let groups: [[TerminalBarKey]] = [
        [.keyboard, .voice, .esc, .tab, .enter],
        [.shift, .ctrl, .alt],
        [.up, .down, .left, .right, .home, .end, .pageUp, .pageDown],
        [.clipboard, .shortcuts, .functionKeys, .password],
    ]

    /// The groups without the hidden buttons. A group with nothing left is
    /// dropped, so it leaves no gap behind.
    static func groups(hiding hidden: Set<TerminalBarKey>) -> [[TerminalBarKey]] {
        groups
            .map { $0.filter { !hidden.contains($0) } }
            .filter { !$0.isEmpty }
    }

    /// The hidden buttons as one line of text, in the bar's own order.
    static func stored(_ hidden: Set<TerminalBarKey>) -> String {
        groups.flatMap { $0 }
            .filter(hidden.contains)
            .map(\.rawValue)
            .joined(separator: ",")
    }

    /// Reads `stored(_:)` back. A name this build does not know is ignored.
    static func hidden(from stored: String) -> Set<TerminalBarKey> {
        Set(stored.split(separator: ",").compactMap {
            TerminalBarKey(rawValue: $0.trimmingCharacters(in: .whitespaces))
        })
    }
}

/// What pressing a button types, given the bar's sticky Shift and Alt.
struct TerminalBarKeyPress: Equatable {
    var bytes: [UInt8]
    /// The press used sticky Shift up, so it disarms.
    var clearsShift = false
    var clearsAlt = false

    /// `nil` for a button that types nothing by itself: one that holds a
    /// modifier, opens something, or (the page keys) depends on the screen.
    static func of(_ key: TerminalBarKey, shift: Bool, alt: Bool,
                   applicationCursor: Bool) -> TerminalBarKeyPress? {
        typealias E = EscapeSequences
        let app = applicationCursor

        /// Alt wins and leaves Shift armed; then Shift; then the plain key.
        func cursorKey(plain: [UInt8], shifted: [UInt8], alted: [UInt8]) -> TerminalBarKeyPress {
            if alt { return TerminalBarKeyPress(bytes: alted, clearsAlt: true) }
            if shift { return TerminalBarKeyPress(bytes: shifted, clearsShift: true) }
            return TerminalBarKeyPress(bytes: plain)
        }

        switch key {
        case .esc:
            return TerminalBarKeyPress(bytes: E.meta, clearsShift: true, clearsAlt: true)
        case .tab:
            if shift { return TerminalBarKeyPress(bytes: E.backtab, clearsShift: true) }
            if alt { return TerminalBarKeyPress(bytes: E.meta + E.tab, clearsAlt: true) }
            return TerminalBarKeyPress(bytes: E.tab)
        case .enter:
            // Escape then Return is what the agent TUIs take for "a new line,
            // do not send": the coding their own terminal setup asks a terminal
            // to send for Shift-Return.
            if shift || alt {
                return TerminalBarKeyPress(bytes: E.meta + E.return, clearsShift: shift, clearsAlt: alt)
            }
            return TerminalBarKeyPress(bytes: E.return)
        case .up:
            let plain = app ? E.upApp : E.up
            return cursorKey(plain: plain, shifted: app ? E.upShiftApp : E.upShift, alted: E.meta + plain)
        case .down:
            let plain = app ? E.downApp : E.down
            return cursorKey(plain: plain, shifted: app ? E.downShiftApp : E.downShift, alted: E.meta + plain)
        case .left:
            return cursorKey(plain: app ? E.leftApp : E.left,
                             shifted: app ? E.leftShiftApp : E.leftShift,
                             alted: E.meta + E.leftMeta)
        case .right:
            return cursorKey(plain: app ? E.rightApp : E.right,
                             shifted: app ? E.rightShiftApp : E.rightShift,
                             alted: E.meta + E.rightMeta)
        case .home:
            let plain = app ? E.homeApp : E.home
            return cursorKey(plain: plain, shifted: E.homeShift, alted: E.meta + plain)
        case .end:
            let plain = app ? E.endApp : E.end
            return cursorKey(plain: plain, shifted: E.endShift, alted: E.meta + plain)
        case .keyboard, .voice, .shift, .ctrl, .alt, .pageUp, .pageDown,
             .clipboard, .shortcuts, .functionKeys, .password:
            return nil
        }
    }
}

/// A chord sent with one tap from the shortcuts palette. Only the ones that mean
/// the same in every shell; sticky Control and a key sends any other.
struct TerminalShortcut: Equatable, Identifiable {
    let label: String
    let meaning: String
    let bytes: [UInt8]
    var id: String { label }

    private static func control(_ key: Character, _ meaning: String) -> TerminalShortcut {
        TerminalShortcut(label: "Ctrl-\(key)", meaning: meaning,
                         bytes: [(key.asciiValue ?? 0).controlCharacter])
    }

    static let all: [TerminalShortcut] = [
        control("C", "Interrupt"),
        control("D", "End of input"),
        control("Z", "Suspend"),
        control("L", "Clear screen"),
        control("R", "Search history"),
        control("A", "Start of line"),
        control("E", "End of line"),
        control("U", "Clear line"),
        control("K", "Cut to end"),
        control("W", "Delete word"),
        control("J", "New line"),
        control("\\", "Quit"),
    ]
}

extension TerminalClipboard {
    /// What the system's paste button hands over, as the bytes to type: the text
    /// as it is, the same as Cmd-V. Nothing for an empty clipboard.
    static func bytes(pasting strings: [String]) -> [UInt8]? {
        let text = strings.joined(separator: "\n")
        return text.isEmpty ? nil : Array(text.utf8)
    }
}

/// Where the bar sits and what it takes from the terminal.
enum TerminalKeyBarMetrics {
    static let pillHeight: CGFloat = 44
    /// Between the terminal's last row and the pill.
    static let topGap: CGFloat = 6
    /// The least the pill keeps under it.
    static let minimumBottomGap: CGFloat = 6
    /// How far the pill lifts off the bottom edge to clear the home indicator.
    static let homeIndicatorClearance: CGFloat = 16
    /// Extra room between one group of buttons and the next.
    static let groupGap: CGFloat = 12

    static func sideMargin(isPhone: Bool) -> CGFloat { isPhone ? 8 : 16 }
    static func keyWidth(isPhone: Bool) -> CGFloat { isPhone ? 40 : 46 }

    /// The gap under the pill, above whatever is already cleared below the bar
    /// (the keyboard, or a phone's home strip). An iPad clears nothing for the
    /// bar, so there the pill lifts itself off the home indicator.
    static func bottomGap(clearedInset: CGFloat, windowHomeInset: CGFloat) -> CGFloat {
        max(minimumBottomGap, min(windowHomeInset, homeIndicatorClearance) - clearedInset)
    }

    /// Height the terminal gives up to the bar. A collapsed bar floats over the
    /// terminal's corner and takes nothing.
    static func reservedHeight(isCollapsed: Bool, clearedInset: CGFloat,
                               windowHomeInset: CGFloat) -> CGFloat {
        isCollapsed ? 0 : topGap + pillHeight
            + bottomGap(clearedInset: clearedInset, windowHomeInset: windowHomeInset)
    }

    /// Margin under the terminal's last row. With the bar open the bar is that
    /// margin; collapsed, an iPad's last row has to stay out of the window-resize
    /// grip by itself (see `HerdrChromeMetrics.resizeGripClearance`).
    static func terminalClearance(isPhone: Bool, isCollapsed: Bool) -> CGFloat {
        isCollapsed ? HerdrChromeMetrics.terminalBottomClearance(isPhone: isPhone) : 0
    }
}
