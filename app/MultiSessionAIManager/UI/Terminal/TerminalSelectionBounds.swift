//
//  TerminalSelectionBounds.swift
//  MultiSessionAIManager
//
//  Computes pane and context area column bounds from terminal content so text
//  selection and copy stay within the active context area instead of spanning
//  across the sidebar or adjacent panes.
//

import Foundation

enum TerminalSelectionBounds {
    /// Vertical divider characters commonly used by TUIs (Herdr, multiplexers, ncurses)
    /// to separate sidebars and split panes.
    static func isVerticalDividerChar(_ char: Character) -> Bool {
        switch char {
        case "\u{2502}", // │ Light vertical
             "\u{2503}", // ┃ Heavy vertical
             "\u{2551}", // ║ Double vertical
             "\u{2504}", // ┆ Light triple dash vertical
             "\u{2505}", // ┊ Light quadruple dash vertical
             "\u{254E}", // ╎ Light double dash vertical
             "\u{254F}", // ╏ Heavy double dash vertical
             "\u{257D}", // ╽ Light down heavy up
             "\u{257F}", // ╿ Light up heavy down
             "\u{251C}", // ├ Light vertical and right
             "\u{2524}", // ┤ Light vertical and left
             "\u{252C}", // ┬ Light down and horizontal
             "\u{2534}", // ┴ Light up and horizontal
             "\u{253C}", // ┼ Light vertical and horizontal
             "\u{250C}", // ┌ Light down and right
             "\u{2510}", // ┐ Light down and left
             "\u{2514}", // └ Light up and right
             "\u{2518}", // ┘ Light up and left
             "\u{256D}", // ╭ Light arc down and right
             "\u{256E}", // ╮ Light arc down and left
             "\u{256F}", // ╯ Light arc up and left
             "\u{2570}": // ╰ Light arc up and right
            return true
        default:
            return false
        }
    }

    /// Finds all columns that act as vertical dividers (e.g. sidebar borders or pane splitters).
    /// A column is considered a divider if it contains divider characters on at least a minimum
    /// threshold of sampled rows.
    static func findVerticalDividers(
        in rows: [TerminalRenderedRow],
        cols: Int
    ) -> [Int] {
        guard !rows.isEmpty, cols > 1 else { return [] }
        let sampleRows = rows.suffix(min(rows.count, 60))
        let rowCount = sampleRows.count
        guard rowCount >= 2 else { return [] }

        let threshold = max(2, Int(Double(rowCount) * 0.15))
        var dividers: [Int] = []

        for c in 0..<cols {
            var count = 0
            for row in sampleRows {
                if let ch = row.character(atColumn: c), isVerticalDividerChar(ch) {
                    count += 1
                }
            }
            if count >= threshold {
                dividers.append(c)
            }
        }
        return dividers
    }

    /// Determines the column range `[minCol, maxCol]` for the context area / pane
    /// surrounding `targetCol`.
    ///
    /// - If `targetCol` falls inside or to the left of the leftmost (sidebar) divider,
    ///   selection is constrained to the main context area immediately to the right of that divider,
    ///   preventing sidebar selection.
    /// - If `targetCol` is inside a pane bounded by dividers, it returns that pane's column range.
    /// - If no dividers are present, returns the full terminal width `0...(cols - 1)`.
    static func columnBounds(
        forCol targetCol: Int,
        totalCols: Int,
        dividers: [Int]
    ) -> ClosedRange<Int> {
        let maxIndex = max(totalCols - 1, 0)
        guard !dividers.isEmpty else {
            return 0...maxIndex
        }

        let sorted = dividers.sorted()
        let leftmostDivider = sorted.first!

        // If targetCol is at or to the left of the leftmost divider (in the sidebar),
        // constrain selection to the primary context area to the right of that divider.
        if targetCol <= leftmostDivider {
            let leftBound = min(leftmostDivider + 1, maxIndex)
            let nextDivider = sorted.first(where: { $0 > leftmostDivider })
            let rightBound = nextDivider.map { max($0 - 1, leftBound) } ?? maxIndex
            return leftBound...rightBound
        }

        // TargetCol is to the right of leftmostDivider.
        // Find closest divider to the left:
        let leftDivider = sorted.filter { $0 < targetCol }.last ?? leftmostDivider
        let leftBound = min(leftDivider + 1, maxIndex)

        // Find closest divider to the right:
        let rightDivider = sorted.first(where: { $0 > targetCol })
        let rightBound = rightDivider.map { max($0 - 1, leftBound) } ?? maxIndex

        return leftBound...rightBound
    }
}
