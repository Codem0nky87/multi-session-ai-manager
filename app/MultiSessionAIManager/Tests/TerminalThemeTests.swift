import Testing
import UIKit
@testable import MultiSessionAIManager

@Suite struct TerminalThemeTests {

    private var readabilityPresets: [(id: String, theme: TerminalTheme)] {
        [
            ("highContrastDark", .highContrastDark),
            ("highContrastLight", .highContrastLight),
            ("midnight", .midnight),
            ("amber", .amber),
            ("ice", .ice),
            ("colorBlindSafe", .colorBlindSafe)
        ]
    }

    /// All the documented presets are present with stable ids.
    @Test func presetsArePresent() {
        let ids = TerminalTheme.all.map(\.id)
        #expect(ids.contains("dark"))
        #expect(ids.contains("light"))
        #expect(ids.contains("solarizedDark"))
        #expect(ids.contains("solarizedLight"))
    }

    @Test func themeIDsAreUniqueAndPalettesAreComplete() {
        let ids = TerminalTheme.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for theme in TerminalTheme.all {
            #expect(theme.ansi.count == AnsiColorCode.allCases.count)
        }
    }

    @Test func everyThemeProvidesFivePreviewColors() {
        for theme in TerminalTheme.all {
            let expected = [
                theme.background,
                theme.foreground,
                theme.ansi[.red] ?? theme.foreground,
                theme.ansi[.green] ?? theme.foreground,
                theme.ansi[.blue] ?? theme.foreground
            ]
            #expect(theme.previewColors == expected)
        }
    }

    @Test func readabilityPresetsAreRegisteredAndResolvable() {
        for (id, _) in readabilityPresets {
            #expect(TerminalTheme.all.contains { $0.id == id })
            #expect(TerminalTheme.byID(id).id == id)
        }
    }

    @Test func readabilityPresetsMeetForegroundContrastTarget() {
        for (_, theme) in readabilityPresets {
            #expect(contrastRatio(theme.foreground, theme.background) >= 7.0,
                    "Insufficient foreground contrast for \(theme.name)")
            #expect(contrastRatio(theme.foregroundBold, theme.background) >= 7.0,
                    "Insufficient bold contrast for \(theme.name)")
            #expect(contrastRatio(theme.backgroundCursor, theme.background) >= 3.0,
                    "Cursor is not visible for \(theme.name)")
        }
    }

    @Test func colorBlindSafeUsesBlueOrangeWithLuminanceSeparation() throws {
        let theme = try #require(
            readabilityPresets.first { $0.id == "colorBlindSafe" }?.theme
        )
        let red = try #require(theme.ansi[AnsiColorCode.red])
        let green = try #require(theme.ansi[AnsiColorCode.green])
        let brightRed = try #require(theme.ansi[AnsiColorCode.brightRed])
        let brightGreen = try #require(theme.ansi[AnsiColorCode.brightGreen])

        #expect(red == color(0xE69F00))
        #expect(green == color(0x0072B2))
        #expect(brightRed == color(0xFFB733))
        #expect(brightGreen == color(0x4AA8D8))
        #expect(abs(relativeLuminance(red) - relativeLuminance(green)) >= 0.20)
        #expect(abs(relativeLuminance(brightRed) - relativeLuminance(brightGreen)) >= 0.20)
    }

    /// `byID` returns the matching preset and falls back to dark for unknown ids.
    @Test func byIDLooksUpOrFallsBackToDark() {
        #expect(TerminalTheme.byID("light").id == "light")
        #expect(TerminalTheme.byID("solarizedDark").id == "solarizedDark")
        #expect(TerminalTheme.byID("does-not-exist").id == "dark")
    }

    /// Dark must look IDENTICAL to the original fixed `TerminalColorMap` values.
    @Test func darkMatchesOriginalColorMapValues() {
        let dark = TerminalTheme.dark
        #expect(dark.background == UIColor(white: 0.07, alpha: 1))
        #expect(dark.foreground == UIColor(white: 0.90, alpha: 1))
        #expect(dark.foregroundBold == UIColor(white: 1.00, alpha: 1))
        // The default colour map (no theme) and the dark-theme map agree on background.
        #expect(TerminalColorMap().background == TerminalColorMap(theme: .dark).background)
    }

    /// Light's background is clearly lighter than dark's (sanity that the palette differs).
    @Test func lightBackgroundIsLighterThanDark() {
        var lw: CGFloat = 0, dw: CGFloat = 0, a: CGFloat = 0
        TerminalTheme.light.background.getWhite(&lw, alpha: &a)
        TerminalTheme.dark.background.getWhite(&dw, alpha: &a)
        #expect(lw > dw)
    }
}

private func rgba(_ color: UIColor) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    #expect(color.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
    return (red, green, blue, alpha)
}

private func color(_ hex: UInt32) -> UIColor {
    UIColor(
        red: CGFloat((hex >> 16) & 0xff) / 255,
        green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255,
        alpha: 1
    )
}

private func relativeLuminance(_ color: UIColor) -> CGFloat {
    let (red, green, blue, _) = rgba(color)
    func linear(_ component: CGFloat) -> CGFloat {
        component <= 0.04045
            ? component / 12.92
            : pow((component + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
}

private func contrastRatio(_ first: UIColor, _ second: UIColor) -> CGFloat {
    let lighter = max(relativeLuminance(first), relativeLuminance(second))
    let darker = min(relativeLuminance(first), relativeLuminance(second))
    return (lighter + 0.05) / (darker + 0.05)
}
