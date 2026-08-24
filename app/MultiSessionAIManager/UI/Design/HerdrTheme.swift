import SwiftUI

enum HerdrTheme {
    static let hexTokens: [String: UInt32] = [
        "background": 0x11111B,
        "panel": 0x181825,
        "activeRow": 0x1E1E2E,
        "selection": 0x313244,
        "muted": 0x6C7086,
        "text": 0xCDD6F4,
        "subtext": 0xA6ADC8,
        "accent": 0x89B4FA,
        "green": 0xA6E3A1,
        "yellow": 0xF9E2AF,
        "red": 0xF38BA8,
        "teal": 0x94E2D5
    ]

    static let background = Color(hex: 0x11111B)
    static let panel = Color(hex: 0x181825)
    static let activeRow = Color(hex: 0x1E1E2E)
    static let selection = Color(hex: 0x313244)
    static let muted = Color(hex: 0x6C7086)
    static let text = Color(hex: 0xCDD6F4)
    static let subtext = Color(hex: 0xA6ADC8)
    static let accent = Color(hex: 0x89B4FA)
    static let green = Color(hex: 0xA6E3A1)
    static let yellow = Color(hex: 0xF9E2AF)
    static let red = Color(hex: 0xF38BA8)
    static let teal = Color(hex: 0x94E2D5)

    static func mono(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .monospaced, weight: weight)
    }
}

enum HerdrChromeMetrics {
    static let sidebarWidth: CGFloat = 238
    static let accessibilitySidebarWidth: CGFloat = 340
    static let headerHeight: CGFloat = 48
    static let minimumHitTarget: CGFloat = 44
    static let tabBarHeight: CGFloat = 44
    /// The app's own host tab strip. Deliberately below `minimumHitTarget`:
    /// this is a low-frequency control on a large screen, and every point it
    /// gives back goes to the remote Herdr TUI below it.
    static let hostTabBarHeight: CGFloat = 32
    /// Hairline breathing room down each side of the terminal, so glyphs at the
    /// first and last column are not flush against the bezel.
    static let terminalEdgeInset: CGFloat = 1

    /// Lifts the terminal's last row clear of the window-resize grip iPadOS
    /// draws in the bottom corners.
    ///
    /// That grip consumes the click before the app sees it, so any control the
    /// remote puts on its bottom row -- Herdr's sidebar collapse, a status line
    /// -- is simply not clickable. There is no API to opt a corner out:
    /// `UIRequiresFullScreen` was the historical lever for refusing resizable
    /// windows and it is going away, which is why the grip appears even in full
    /// screen.
    ///
    /// Full width rather than just the two corners, because a character grid is
    /// uniform -- notching it would clip the glyphs in those cells. The strip is
    /// painted in the terminal's own background so it reads as margin, not gap.
    static let resizeGripClearance: CGFloat = 20

    static let paneBorderWidth: CGFloat = 1
    static let focusedPaneBorderWidth: CGFloat = 2
}
