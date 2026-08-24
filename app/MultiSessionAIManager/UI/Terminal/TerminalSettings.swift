import SwiftUI

/// Shared terminal font size, persisted and predictable across every display.
@MainActor @Observable
final class TerminalSettings {
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "terminal.fontSize"
    static let minSize: CGFloat = 7
    static let maxSize: CGFloat = 26
    static let defaultSize: CGFloat = 11
    private(set) var fontSize: CGFloat

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = CGFloat(defaults.double(forKey: Self.key))   // 0 when unset
        self.fontSize = saved > 0 ? min(max(saved, Self.minSize), Self.maxSize) : Self.defaultSize
    }

    /// Set the size (clamped). `persist:false` during a live pinch; commit on end.
    func setFontSize(_ size: CGFloat, persist: Bool = true) {
        let clamped = min(max(size, Self.minSize), Self.maxSize)
        if clamped != fontSize { fontSize = clamped }
        if persist { defaults.set(Double(fontSize), forKey: Self.key) }
    }

    /// Step by whole points.
    func step(_ points: CGFloat) { setFontSize(fontSize + points) }
}
