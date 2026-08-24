//
//  TerminalFontMetrics.swift
//  MultiSessionAIManager
//
//  Font metrics for the terminal renderer. Adapted from NewTerm's `FontMetrics`,
//  trimmed to the system monospaced font (the app ships no custom terminal fonts).
//  Computes the per-cell bounding box (`width` x `height`) from a single glyph so
//  the SwiftUI view can derive cols/rows from its frame.
//

import UIKit
import CoreText

struct TerminalFontMetrics: Hashable {
    let regularFont: UIFont
    let boldFont: UIFont
    let italicFont: UIFont
    let boldItalicFont: UIFont
    let lightFont: UIFont
    let lightItalicFont: UIFont

    /// Width of one monospaced cell, in points.
    let width: CGFloat
    /// Height of one row, in points.
    let height: CGFloat

    var boundingBox: CGSize { CGSize(width: width, height: height) }

    init(fontSize: CGFloat) {
        let regular: UIFont = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let bold: UIFont = .monospacedSystemFont(ofSize: fontSize, weight: .bold)
        let light: UIFont = .monospacedSystemFont(ofSize: fontSize, weight: .light)

        func italic(_ font: UIFont) -> UIFont {
            if let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) {
                return UIFont(descriptor: descriptor, size: fontSize)
            }
            return font
        }

        self.regularFont = regular
        self.boldFont = bold
        self.lightFont = light
        self.italicFont = italic(regular)
        self.boldItalicFont = italic(bold)
        self.lightItalicFont = italic(light)

        // Determine the bounding box of a single letter. Assumes all glyphs in the
        // font are the same width (true for monospaced fonts).
        let attributedString = NSAttributedString(string: "A", attributes: [.font: regular])
        let line = CTLineCreateWithAttributedString(attributedString)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        self.width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        // Round the row height UP to a whole point. The raw ascent+descent+leading is
        // fractional, so at small font sizes the per-row tiles don't land on the device
        // pixel grid and the `drawingGroup(opaque:)` rasterized rows leave ~1px seams
        // between them (faint horizontal lines). Whole points → integer device pixels at
        // any @2x/@3x scale → pixel-aligned, gap-free rows.
        self.height = (ascent + descent + leading).rounded(.up)
    }
}
