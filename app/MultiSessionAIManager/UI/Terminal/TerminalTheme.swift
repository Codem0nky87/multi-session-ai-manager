//
//  TerminalTheme.swift
//  MultiSessionAIManager
//
//  A selectable terminal colour palette: background / foreground / cursor + the 16
//  ANSI colours. `TerminalColorMap` is parameterized by one of these for native
//  Herdr terminal panes. Presets have a stable string `id` and display `name`.
//
//  The `dark` preset's values are a verbatim copy of the original fixed
//  `TerminalColorMap` palette, so the default appearance is unchanged.
//

import UIKit

/// A value type describing a full terminal colour palette. ANSI entries are keyed by
/// `AnsiColorCode` so the colour map can look them up by index (0...15).
struct TerminalTheme: Identifiable, Equatable {
    /// Stable identifier used by `byID(_:)`.
    let id: String
    /// Human-readable name for the picker menu.
    let name: String

    let background: UIColor
    let foreground: UIColor
    let foregroundBold: UIColor
    let foregroundCursor: UIColor
    let backgroundCursor: UIColor
    let ansi: [AnsiColorCode: UIColor]

    var previewColors: [UIColor] {
        [
            background,
            foreground,
            ansi[.red] ?? foreground,
            ansi[.green] ?? foreground,
            ansi[.blue] ?? foreground
        ]
    }

    static func == (lhs: TerminalTheme, rhs: TerminalTheme) -> Bool { lhs.id == rhs.id }

    /// Build an `[AnsiColorCode: UIColor]` from 16 hex strings in the canonical order
    /// (black, red, green, yellow, blue, purple/magenta, cyan, white, then the 8 bright
    /// variants). Mirrors `AnsiColorCode.allCases`.
    private static func ansiPalette(_ hexes: [UInt32]) -> [AnsiColorCode: UIColor] {
        assert(hexes.count == AnsiColorCode.allCases.count,
               "Terminal themes require exactly 16 ANSI colors")
        var out = [AnsiColorCode: UIColor]()
        for (code, hex) in zip(AnsiColorCode.allCases, hexes) {
            out[code] = rgb(hex)
        }
        return out
    }

    private static func rgb(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1)
    }

    // MARK: - Presets

    /// The app's original fixed dark theme — values copied verbatim from the previous
    /// `TerminalColorMap` so Dark looks IDENTICAL to before themes existed.
    static let dark = TerminalTheme(
        id: "dark", name: "Dark",
        background: UIColor(white: 0.07, alpha: 1),
        foreground: UIColor(white: 0.90, alpha: 1),
        foregroundBold: UIColor(white: 1.00, alpha: 1),
        foregroundCursor: rgb(0x66D973),   // soft green (0.40, 0.85, 0.45)
        backgroundCursor: rgb(0x66D973),
        ansi: [
            .black:        rgb(0x282A2E),
            .red:          rgb(0xE5534B),
            .green:        rgb(0x7AC263),
            .yellow:       rgb(0xDEB354),
            .blue:         rgb(0x5594E6),
            .purple:       rgb(0xB87CDB),
            .cyan:         rgb(0x50BFC4),
            .white:        rgb(0xC8C8CD),
            .brightBlack:  rgb(0x5F6368),
            .brightRed:    rgb(0xF07169),
            .brightGreen:  rgb(0x92D77C),
            .brightYellow: rgb(0xEEC66E),
            .brightBlue:   rgb(0x78ADF0),
            .brightPurple: rgb(0xCE99EA),
            .brightCyan:   rgb(0x70D4D9),
            .brightWhite:  rgb(0xF5F5F8)
        ])

    /// A light theme: off-white background, near-black foreground, light-appropriate
    /// (slightly darker) ANSI so colours read on a pale background.
    static let light = TerminalTheme(
        id: "light", name: "Light",
        background: rgb(0xFBFBFA),
        foreground: rgb(0x1B1B1B),
        foregroundBold: rgb(0x000000),
        foregroundCursor: rgb(0xFBFBFA),
        backgroundCursor: rgb(0x2A7D2E),
        ansi: ansiPalette([
            0x2E2E2E, 0xC0392B, 0x2E8B2E, 0xB8860B, 0x2667C9, 0x8E44AD, 0x148F8F, 0x5A5A5A,
            0x555555, 0xE74C3C, 0x3DA63D, 0xCF9B17, 0x3A7FE0, 0xA259D4, 0x1FB3B3, 0x2B2B2B
        ]))

    static let highContrastDark = TerminalTheme(
        id: "highContrastDark", name: "High Contrast Dark",
        background: rgb(0x050505),
        foreground: rgb(0xF2F2F2),
        foregroundBold: rgb(0xFFFFFF),
        foregroundCursor: rgb(0x050505),
        backgroundCursor: rgb(0xFFD400),
        ansi: ansiPalette([
            0x111111, 0xFF5A5F, 0x55D66B, 0xFFD166, 0x5AA9FF, 0xD783FF, 0x49D6D1, 0xE6E6E6,
            0x6B6B6B, 0xFF7B7F, 0x7BE38C, 0xFFE08A, 0x82BFFF, 0xE4A6FF, 0x75E5E1, 0xFFFFFF
        ]))

    static let highContrastLight = TerminalTheme(
        id: "highContrastLight", name: "High Contrast Light",
        background: rgb(0xFFFFFF),
        foreground: rgb(0x111111),
        foregroundBold: rgb(0x000000),
        foregroundCursor: rgb(0xFFFFFF),
        backgroundCursor: rgb(0x003B80),
        ansi: ansiPalette([
            0x111111, 0xA40000, 0x006B2D, 0x7A5200, 0x0047A8, 0x6E2383, 0x006B70, 0x4A4A4A,
            0x5C5C5C, 0xC71919, 0x008A3A, 0x9B6800, 0x155FC0, 0x8D3AA3, 0x008A91, 0x000000
        ]))

    static let midnight = TerminalTheme(
        id: "midnight", name: "Midnight",
        background: rgb(0x07111F),
        foreground: rgb(0xDCE8F5),
        foregroundBold: rgb(0xFFFFFF),
        foregroundCursor: rgb(0x07111F),
        backgroundCursor: rgb(0x63E6BE),
        ansi: ansiPalette([
            0x101B2B, 0xFF6B7A, 0x5DE4A8, 0xFFD166, 0x63A8FF, 0xC792EA, 0x56D4DD, 0xDCE8F5,
            0x627087, 0xFF8792, 0x7DEAB8, 0xFFE08A, 0x86BCFF, 0xD9AEF2, 0x7CE1E7, 0xFFFFFF
        ]))

    static let amber = TerminalTheme(
        id: "amber", name: "Amber",
        background: rgb(0x120E08),
        foreground: rgb(0xFFE8B3),
        foregroundBold: rgb(0xFFF7E3),
        foregroundCursor: rgb(0x120E08),
        backgroundCursor: rgb(0xFFB000),
        ansi: ansiPalette([
            0x211A10, 0xFF675C, 0x8FD14F, 0xFFB000, 0x72A7FF, 0xD58CFF, 0x58D6C7, 0xE8D2A2,
            0x75664D, 0xFF8A80, 0xAAE06F, 0xFFC84D, 0x99BEFF, 0xE1ACFF, 0x82E2D6, 0xFFF7E3
        ]))

    static let ice = TerminalTheme(
        id: "ice", name: "Ice",
        background: rgb(0x061318),
        foreground: rgb(0xDDF7F5),
        foregroundBold: rgb(0xFFFFFF),
        foregroundCursor: rgb(0x061318),
        backgroundCursor: rgb(0x72F1E1),
        ansi: ansiPalette([
            0x102329, 0xFF7185, 0x6FE7B2, 0xE8D675, 0x69B7FF, 0xBFA3FF, 0x66E0E5, 0xDDF7F5,
            0x607A80, 0xFF91A0, 0x91EDC4, 0xF2E398, 0x91CAFF, 0xD0BDFF, 0x8DE9EC, 0xFFFFFF
        ]))

    static let colorBlindSafe = TerminalTheme(
        id: "colorBlindSafe", name: "Color-Blind Safe",
        background: rgb(0x080B10),
        foreground: rgb(0xF1F3F5),
        foregroundBold: rgb(0xFFFFFF),
        foregroundCursor: rgb(0x080B10),
        backgroundCursor: rgb(0xF0E442),
        ansi: ansiPalette([
            0x151A21, 0xE69F00, 0x0072B2, 0xF0E442, 0x56B4E9, 0xCC79A7, 0x00BFC4, 0xE5E7EB,
            0x68707C, 0xFFB733, 0x4AA8D8, 0xFFF06A, 0x86C9F0, 0xE3A1C4, 0x55DDE0, 0xFFFFFF
        ]))

    /// Solarized Dark (Ethan Schoonover). base03 background, base0 foreground.
    static let solarizedDark = TerminalTheme(
        id: "solarizedDark", name: "Solarized Dark",
        background: rgb(0x002B36),   // base03
        foreground: rgb(0x839496),   // base0
        foregroundBold: rgb(0x93A1A1), // base1
        foregroundCursor: rgb(0x002B36),
        backgroundCursor: rgb(0x839496),
        ansi: ansiPalette([
            0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
            0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3
        ]))

    /// Solarized Light. base3 background, base00 foreground.
    static let solarizedLight = TerminalTheme(
        id: "solarizedLight", name: "Solarized Light",
        background: rgb(0xFDF6E3),   // base3
        foreground: rgb(0x657B83),   // base00
        foregroundBold: rgb(0x586E75), // base01
        foregroundCursor: rgb(0xFDF6E3),
        backgroundCursor: rgb(0x657B83),
        ansi: ansiPalette([
            0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
            0x002B36, 0xCB4B16, 0x586E75, 0x657B83, 0x839496, 0x6C71C4, 0x93A1A1, 0xFDF6E3
        ]))

    /// Dracula (draculatheme.com).
    static let dracula = TerminalTheme(
        id: "dracula", name: "Dracula",
        background: rgb(0x282A36),
        foreground: rgb(0xF8F8F2),
        foregroundBold: rgb(0xFFFFFF),
        foregroundCursor: rgb(0x282A36),
        backgroundCursor: rgb(0xF8F8F2),
        ansi: ansiPalette([
            0x21222C, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
            0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF
        ]))

    /// Nord (nordtheme.com).
    static let nord = TerminalTheme(
        id: "nord", name: "Nord",
        background: rgb(0x2E3440),
        foreground: rgb(0xD8DEE9),
        foregroundBold: rgb(0xECEFF4),
        foregroundCursor: rgb(0x2E3440),
        backgroundCursor: rgb(0xD8DEE9),
        ansi: ansiPalette([
            0x3B4252, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x88C0D0, 0xE5E9F0,
            0x4C566A, 0xBF616A, 0xA3BE8C, 0xEBCB8B, 0x81A1C1, 0xB48EAD, 0x8FBCBB, 0xECEFF4
        ]))

    /// All selectable presets, in picker order.
    static let all: [TerminalTheme] = [
        dark,
        light,
        solarizedDark,
        solarizedLight,
        dracula,
        nord,
        highContrastDark,
        highContrastLight,
        midnight,
        amber,
        ice,
        colorBlindSafe
    ]

    /// Look up a preset by its stable `id`. Unknown ids fall back to `dark` so a
    /// persisted-but-removed theme never crashes or blanks the terminal.
    static func byID(_ id: String) -> TerminalTheme {
        all.first { $0.id == id } ?? dark
    }
}
