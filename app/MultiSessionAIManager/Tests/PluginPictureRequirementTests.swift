import Foundation
import Testing
@testable import MultiSessionAIManager

/// A plugin's manifest does not say whether it draws pictures, so its own words
/// are read for it. The sentences below are the plugins' own, from the five in
/// Herdr's marketplace that do (of the 120 most starred, 2026-11-18).
@Suite struct PluginPictureRequirementTests {

    @Test(arguments: [
        // zenbu-labs/terminal-browser
        "Terminals that support the kitty graphics protocol, including ghostty, kitty, iTerm2, allow a program to display pixels",
        // zenbu-labs/terminal-code
        "terminal-code depends on a modern terminal feature ([the kitty graphics protocol](https://sw.kovidgoyal.net/kitty/graphics-protocol/))",
        // StructuPath/herdr-browser
        "- **Adaptive rendering** — Kitty graphics when available, ANSI symbols through",
        // plannotator/herdr-plannotator
        "- Herdr's experimental Kitty graphics support",
        // nikok6/herdr-pet, in its manifest
        "# host terminal that speaks the kitty graphics protocol (Ghostty, kitty, WezTerm).",
    ])
    func aPluginThatSaysItDrawsPicturesIsRecognised(sentence: String) {
        #expect(PluginPictureRequirement.phrase(in: sentence) == "kitty graphics")
    }

    @Test func theOtherNamesForTerminalPicturesCountToo() {
        #expect(PluginPictureRequirement.phrase(in: "Renders previews with Sixel.") == "sixel")
        #expect(PluginPictureRequirement.phrase(in: "needs a terminal graphics protocol") == "graphics protocol")
        #expect(PluginPictureRequirement.phrase(in: "enable kitty-graphics in your config") == "kitty-graphics")
    }

    @Test(arguments: [
        "A git-aware, read-only file viewer: a keyboard-driven TUI in a herdr split pane.",
        "Works in kitty, Ghostty and WezTerm. Install with `herdr plugin install owner/repo`.",
        "Shows an image of your build status as coloured text. No graphics card required.",
        "Send files and images between the host and your device.",
        "",
    ])
    func aPluginThatOnlyMentionsTerminalsOrImagesIsNot(text: String) {
        #expect(PluginPictureRequirement.phrase(in: text) == nil)
    }
}
