import Testing
import Foundation
import CoreGraphics
@testable import MultiSessionAIManager

@MainActor
@Suite struct TerminalSettingsTests {

    /// A clean UserDefaults suite per test so persisted sizes don't bleed across cases.
    private func freshDefaults(_ function: String) -> UserDefaults {
        let suite = "msam.terminalsettings.\(function)"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    @Test func freshStoreUsesDefaultSize() {
        let s = TerminalSettings(defaults: freshDefaults(#function))
        #expect(s.fontSize == TerminalSettings.defaultSize)
        #expect(s.fontSize == 11)
    }

    @Test func setFontSizeClampsAtFloor() {
        let s = TerminalSettings(defaults: freshDefaults(#function))
        s.setFontSize(1)
        #expect(s.fontSize == TerminalSettings.minSize)
        #expect(s.fontSize == 7)
    }

    @Test func setFontSizeClampsAtCeiling() {
        let s = TerminalSettings(defaults: freshDefaults(#function))
        s.setFontSize(99)
        #expect(s.fontSize == TerminalSettings.maxSize)
        #expect(s.fontSize == 26)
    }

    @Test func setFontSizePersistTrueRoundTrips() {
        let defaults = freshDefaults(#function)
        let a = TerminalSettings(defaults: defaults)
        a.setFontSize(18, persist: true)
        #expect(a.fontSize == 18)

        let b = TerminalSettings(defaults: defaults)
        #expect(b.fontSize == 18)   // persisted size loaded by a new instance
    }

    @Test func setFontSizePersistFalseDoesNotWrite() {
        let defaults = freshDefaults(#function)
        let a = TerminalSettings(defaults: defaults)
        a.setFontSize(18, persist: false)   // live pinch — no write
        #expect(a.fontSize == 18)           // in-memory updated

        let b = TerminalSettings(defaults: defaults)
        #expect(b.fontSize == TerminalSettings.defaultSize)  // nothing persisted
    }

    @Test func stepAdjustsUp() {
        let s = TerminalSettings(defaults: freshDefaults(#function))
        s.step(2)
        #expect(s.fontSize == TerminalSettings.defaultSize + 2)  // 13
    }

    @Test func stepAdjustsDown() {
        let s = TerminalSettings(defaults: freshDefaults(#function))
        s.step(-3)
        #expect(s.fontSize == TerminalSettings.defaultSize - 3)  // 8
    }

    @Test func stepClampsAtBounds() {
        let s = TerminalSettings(defaults: freshDefaults(#function))
        s.step(-99)
        #expect(s.fontSize == TerminalSettings.minSize)   // 7
        s.step(99)
        #expect(s.fontSize == TerminalSettings.maxSize)   // 26
    }

    @Test func stepPersists() {
        let defaults = freshDefaults(#function)
        let a = TerminalSettings(defaults: defaults)
        a.step(2)
        let b = TerminalSettings(defaults: defaults)
        #expect(b.fontSize == TerminalSettings.defaultSize + 2)  // persisted
    }

    @Test func freshStoreUsesDefaultTheme() {
        let s = TerminalSettings(defaults: freshDefaults(#function))
        #expect(s.themeID == TerminalSettings.defaultThemeID)
        #expect(s.themeID == "dark")
        #expect(s.theme.id == "dark")
    }

    @Test func setThemeIDPersistTrueRoundTrips() {
        let defaults = freshDefaults(#function)
        let a = TerminalSettings(defaults: defaults)
        a.setThemeID("dracula", persist: true)
        #expect(a.themeID == "dracula")
        #expect(a.theme.id == "dracula")

        let b = TerminalSettings(defaults: defaults)
        #expect(b.themeID == "dracula")
        #expect(b.theme.id == "dracula")
    }

    @Test func setThemeIDPersistFalseDoesNotWrite() {
        let defaults = freshDefaults(#function)
        let a = TerminalSettings(defaults: defaults)
        a.setThemeID("catppuccin", persist: false)
        #expect(a.themeID == "catppuccin")

        let b = TerminalSettings(defaults: defaults)
        #expect(b.themeID == TerminalSettings.defaultThemeID)
    }

    @Test func setThemeIDResolvesUnknownFallback() {
        let defaults = freshDefaults(#function)
        let s = TerminalSettings(defaults: defaults)
        s.setThemeID("non-existent-theme")
        #expect(s.themeID == "dark")
    }

}
