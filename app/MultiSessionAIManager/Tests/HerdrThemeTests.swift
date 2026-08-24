import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct HerdrThemeTests {
    @Test func paletteMatchesThePinnedHerdrDefaultClientTheme() {
        #expect(HerdrTheme.hexTokens == [
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
        ])
    }

    @Test func essentialChromeColorsMeetNormalTextContrast() throws {
        let tokens = HerdrTheme.hexTokens
        for background in ["background", "panel"] {
            for foreground in ["text", "subtext", "accent", "green", "yellow", "red", "teal"] {
                let ratio = contrast(
                    try #require(tokens[foreground]),
                    try #require(tokens[background])
                )
                #expect(ratio >= 4.5, "\(foreground) on \(background) has contrast \(ratio)")
            }
        }
    }

    @Test func chromeMetricsPreserveHerdrDensityWithIPadHitTargets() {
        #expect(HerdrChromeMetrics.sidebarWidth == 238)
        #expect(HerdrChromeMetrics.accessibilitySidebarWidth == 340)
        #expect(HerdrChromeMetrics.headerHeight == 48)
        #expect(HerdrChromeMetrics.minimumHitTarget == 44)
        #expect(HerdrChromeMetrics.tabBarHeight == 44)
        #expect(HerdrChromeMetrics.paneBorderWidth == 1)
        #expect(HerdrChromeMetrics.focusedPaneBorderWidth == 2)
    }

    private func contrast(_ foreground: UInt32, _ background: UInt32) -> Double {
        let lighter = max(luminance(foreground), luminance(background))
        let darker = min(luminance(foreground), luminance(background))
        return (lighter + 0.05) / (darker + 0.05)
    }

    private func luminance(_ hex: UInt32) -> Double {
        let components = [16, 8, 0].map { shift -> Double in
            let channel = Double((hex >> UInt32(shift)) & 0xFF) / 255
            return channel <= 0.04045
                ? channel / 12.92
                : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * components[0] + 0.7152 * components[1] + 0.0722 * components[2]
    }
}
