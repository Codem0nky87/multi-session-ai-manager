import Foundation
import CoreGraphics

/// Encodes touch events as xterm SGR (1006) mouse sequences understood by remote
/// terminal applications: `ESC [ < b ; x ; y M` (press/drag) or `... m` (release).
/// `x`/`y` are 1-based terminal cells. We send left-button (button 0) events —
/// press, release, and drag (motion with button held) — for pane focus +
/// border-resize, right-button (button 2) clicks so remote context menus can be
/// raised, and scroll-wheel events (buttons 64/65).
enum TerminalMouse {
    enum Event { case press, release, drag }

    /// xterm button codes. A secondary (right) click is button 2, which is what
    /// TUIs listen for to raise a context menu.
    enum Button: Int {
        case left = 0
        case middle = 1
        case right = 2
    }

    /// SGR-1006 bytes for `event` at 0-based cell (`col`,`row`).
    static func sgr(_ event: Event, button: Button = .left, col: Int, row: Int) -> [UInt8] {
        // Motion adds 32 (the "drag" flag) on top of the button code.
        let code = button.rawValue + (event == .drag ? 32 : 0)
        let final: Character = (event == .release) ? "m" : "M"
        let x = max(col, 0) + 1   // protocol is 1-based
        let y = max(row, 0) + 1
        return Array("\u{1b}[<\(code);\(x);\(y)\(final)".utf8)
    }

    /// SGR-1006 bytes for a scroll-wheel notch at 0-based cell (`col`,`row`). xterm
    /// wheel buttons: 64 = up, 65 = down; reported as a press (final `M`).
    static func wheel(up: Bool, col: Int, row: Int) -> [UInt8] {
        let button = up ? 64 : 65
        let x = max(col, 0) + 1
        let y = max(row, 0) + 1
        return Array("\u{1b}[<\(button);\(x);\(y)M".utf8)
    }

    /// Map a touch point (points, relative to the terminal's top-left) to a 0-based
    /// terminal cell. Clamps at 0; callers send 1-based via `sgr(...)`.
    static func cell(x: CGFloat, y: CGFloat, cellWidth: CGFloat, cellHeight: CGFloat) -> (col: Int, row: Int) {
        guard cellWidth > 0, cellHeight > 0 else { return (0, 0) }
        let col = max(Int((x / cellWidth).rounded(.down)), 0)
        let row = max(Int((y / cellHeight).rounded(.down)), 0)
        return (col, row)
    }
}
