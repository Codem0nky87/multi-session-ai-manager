//
//  TerminalColorMap.swift
//  MultiSessionAIManager
//
//  Maps SwiftTerm `Attribute.Color` values to `UIColor`. Adapted from NewTerm's
//  `ColorMap` with a fixed dark theme matching the app (near-black background,
//  light foreground). The 256-color cube and true-color paths are unchanged.
//
//  Note: this SwiftTerm version spells the indexed case `ansi256(code:)`, so the
//  pattern match differs slightly from the NewTerm reference.
//

import UIKit
import SwiftTerm

enum AnsiColorCode: Int, CaseIterable {
    case black, red, green, yellow, blue, purple, cyan, white
    case brightBlack, brightRed, brightGreen, brightYellow
    case brightBlue, brightPurple, brightCyan, brightWhite
}

final class TerminalColorMap {
    // Per-theme colours. The 256-cube + truecolor paths below are theme-independent;
    // only the 16 ANSI colours and bg/fg/cursor come from the `TerminalTheme`.
    let background: UIColor
    let foreground: UIColor
    let foregroundBold: UIColor
    let foregroundCursor: UIColor
    let backgroundCursor: UIColor

    private let ansiColors: [AnsiColorCode: UIColor]
    private var colorCache = [Attribute.Color: UIColor]()

    /// Build a colour map for `theme`. Defaults to the Dark preset so existing call
    /// sites (`TerminalColorMap()`) keep their original appearance unchanged.
    init(theme: TerminalTheme = .dark) {
        background = theme.background
        foreground = theme.foreground
        foregroundBold = theme.foregroundBold
        foregroundCursor = theme.foregroundCursor
        backgroundCursor = theme.backgroundCursor
        ansiColors = theme.ansi
    }

    func color(for termColor: Attribute.Color, isForeground: Bool, isBold: Bool = false, isCursor: Bool = false) -> UIColor {
        if isCursor {
            if isForeground {
                switch termColor {
                case .defaultColor, .defaultInvertedColor: return background
                default: break
                }
            } else {
                return backgroundCursor
            }
        }

        switch termColor {
        case .defaultColor:
            return isForeground ? foreground : background

        case .defaultInvertedColor:
            return isForeground ? background : foreground

        case .ansi256(let ansi):
            let index = Int(ansi) + (isBold && ansi < 248 ? 8 : 0)
            if index < 16 {
                return ansiColors[AnsiColorCode.allCases[index]]!
            }

            if let cachedColor = colorCache[termColor] {
                return cachedColor
            }

            let color: UIColor
            if index < 232 {
                // 256-color cube (16-231)
                let tableIndex = index - 16
                let r = tableIndex / 36 == 0 ? 0 : ((tableIndex / 36) * 40 + 55)
                let g = tableIndex % 36 / 6 == 0 ? 0 : ((tableIndex % 36 / 6) * 40 + 55)
                let b = tableIndex % 6 == 0 ? 0 : (tableIndex % 6 * 40 + 55)
                color = UIColor(red: CGFloat(r) / 255,
                                green: CGFloat(g) / 255,
                                blue: CGFloat(b) / 255,
                                alpha: 1)
            } else if index < 256 {
                // Greys (232-255)
                color = UIColor(white: ((CGFloat(index) - 232) * 10 + 8) / 255, alpha: 1)
            } else {
                color = foreground
            }
            colorCache[termColor] = color
            return color

        case .trueColor(let r, let g, let b):
            if let cachedColor = colorCache[termColor] {
                return cachedColor
            }
            let color = UIColor(red: CGFloat(r) / 255,
                                green: CGFloat(g) / 255,
                                blue: CGFloat(b) / 255,
                                alpha: 1)
            colorCache[termColor] = color
            return color
        }
    }
}
