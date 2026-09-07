import SwiftUI

/// Shared terminal font size and theme, persisted and predictable across every display.
@MainActor @Observable
final class TerminalSettings {
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "terminal.fontSize"
    private static let themeKey = "terminal.theme"
    static let minSize: CGFloat = 7
    static let maxSize: CGFloat = 26
    static let defaultSize: CGFloat = 11
    static let defaultThemeID: String = "dark"

    private(set) var fontSize: CGFloat
    private(set) var themeID: String

    var theme: TerminalTheme {
        TerminalTheme.byID(themeID)
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = CGFloat(defaults.double(forKey: Self.key))   // 0 when unset
        self.fontSize = saved > 0 ? min(max(saved, Self.minSize), Self.maxSize) : Self.defaultSize
        let savedTheme = defaults.string(forKey: Self.themeKey)
        self.themeID = (savedTheme?.isEmpty == false) ? savedTheme! : Self.defaultThemeID
    }

    /// Set the size (clamped). `persist:false` during a live pinch; commit on end.
    func setFontSize(_ size: CGFloat, persist: Bool = true) {
        let clamped = min(max(size, Self.minSize), Self.maxSize)
        if clamped != fontSize { fontSize = clamped }
        if persist { defaults.set(Double(fontSize), forKey: Self.key) }
    }

    /// Set the active colour theme.
    func setThemeID(_ id: String, persist: Bool = true) {
        let resolved = TerminalTheme.byID(id).id
        if resolved != themeID { themeID = resolved }
        if persist { defaults.set(themeID, forKey: Self.themeKey) }
    }

    /// Step by whole points.
    func step(_ points: CGFloat) { setFontSize(fontSize + points) }
}
