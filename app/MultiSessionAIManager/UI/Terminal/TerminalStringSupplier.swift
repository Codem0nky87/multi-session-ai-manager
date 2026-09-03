//
//  TerminalStringSupplier.swift
//  MultiSessionAIManager
//
//  Turns one core-`Terminal` buffer row into a SwiftUI `Text`-run view. Adapted
//  from NewTerm's `StringSupplier`: it coalesces adjacent cells with the same
//  attribute into a single `Text`, sizes each run by display columns, and draws
//  the cursor cell inverted. This is the heart of the "render the buffer each
//  frame" approach — erases/clears are always reflected because we rebuild from
//  the live buffer rather than diffing a UIKit draw tree.
//

import Foundation
import SwiftTerm
import SwiftUI

/// The live SwiftTerm row consumed by the production renderer. UI row indices are
/// buffer-relative and bounded; the supplier resolves SwiftTerm's differing row
/// spaces before constructing this value.
struct TerminalRowSource {
    fileprivate let columnCount: Int
    fileprivate let cellAtColumn: (Int) -> CharData
    fileprivate let cursorColumn: Int?

    let uiRow: Int

    var plainText: String {
        var cells = ""
        var trimmedCellCount = 0
        for column in 0..<columnCount {
            let cell = cellAtColumn(column)
            let character = cell.getCharacter()
            cells.append(character)
            if character != "\0" {
                trimmedCellCount = min(column + Int(cell.width), columnCount)
            }
        }
        return String(cells.prefix(trimmedCellCount))
    }

    fileprivate func cell(at column: Int) -> CharData {
        cellAtColumn(column)
    }
}

/// Splits a row of cells into coalesced `Text` runs.
///
/// Coalescing is what keeps the view count sane, but it is only safe for
/// glyphs whose advance is exactly one cell. ASCII in the monospaced font is;
/// anything that can resolve to a FALLBACK font is not (a nerd-font icon
/// renders ~6pt wider than its cell, `⧉` +2.3pt, `❯` −0.2pt — measured). Inside
/// a coalesced run that drift shifts every glyph after it, which is how the
/// last typed character slid underneath the cursor block. Isolating each
/// non-ASCII cell into its own exact-width run stops the accumulation at one
/// cell.
enum TerminalRunSplitter {
    /// True when the glyph's advance cannot be trusted to be exactly one cell.
    ///
    /// Safe: ASCII, and box drawing + block elements (U+2500–U+259F) — every
    /// glyph in that range measures exactly one cell in the system monospaced
    /// font, and borders/progress bars repeat them for whole rows, so isolating
    /// them would multiply the view count enough to matter (render storms are
    /// this app's documented watchdog-crash mode). Braille spinners drift
    /// (+0.85pt) and stay out.
    static func isolates(_ char: Character) -> Bool {
        !char.unicodeScalars.allSatisfy {
            ($0.value >= 0x20 && $0.value < 0x7F)
                || ($0.value >= 0x2500 && $0.value <= 0x259F)
        }
    }

    static func runs<A: Equatable>(
        cells: [(char: Character, attribute: A, isCursor: Bool)]
    ) -> [(text: String, attribute: A, isCursor: Bool)] {
        var result = [(text: String, attribute: A, isCursor: Bool)]()
        var buffer = ""
        var bufferAttribute: A?

        func flush() {
            if let attribute = bufferAttribute, !buffer.isEmpty {
                result.append((text: buffer, attribute: attribute, isCursor: false))
            }
            buffer = ""
            bufferAttribute = nil
        }

        for cell in cells {
            if cell.isCursor || Self.isolates(cell.char) {
                flush()
                result.append((text: String(cell.char), attribute: cell.attribute,
                               isCursor: cell.isCursor))
                continue
            }
            if bufferAttribute != cell.attribute {
                flush()
                bufferAttribute = cell.attribute
            }
            buffer.append(cell.char)
        }
        flush()
        return result
    }
}

final class TerminalStringSupplier {
    var terminal: Terminal!
    var colorMap: TerminalColorMap!
    var fontMetrics: TerminalFontMetrics!
    var cursorVisible = true

    /// Resolve a host-owned row directly from SwiftTerm's visible viewport.
    func sourceForViewportRow(_ row: Int) -> TerminalRowSource? {
        guard let terminal, let line = terminal.getLine(row: row) else { return nil }
        let cursor = terminal.getCursorLocation()
        return TerminalRowSource(
            columnCount: terminal.cols,
            cellAtColumn: { line[$0] },
            cursorColumn: cursorVisible && row == cursor.y ? cursor.x : nil,
            uiRow: row
        )
    }

    /// Resolve a bounded UI row directly in the buffer-relative coordinate space
    /// shared by SwiftTerm's selection and text-extraction APIs.
    func sourceForBufferRow(_ row: Int, rowCount: Int) -> TerminalRowSource? {
        guard let terminal, row >= 0, row < rowCount else { return nil }
        let buffer = terminal.buffer
        let cursor = terminal.getCursorLocation()
        let cursorRow = terminal.getTopVisibleRow() + cursor.y
        return TerminalRowSource(
            columnCount: terminal.cols,
            cellAtColumn: { column in
                buffer.getChar(
                    atBufferRelative: Position(col: column, row: row)
                )
            },
            cursorColumn: cursorVisible && row == cursorRow ? cursor.x : nil,
            uiRow: row
        )
    }

    func attributedString(for source: TerminalRowSource) -> AnyView {
        let cells = (0..<terminal.cols).map { j in
            let data = source.cell(at: j)
            let character = data.getCharacter()
            return (char: character == "\0" ? " " : character,
                    attribute: data.attribute,
                    isCursor: j == source.cursorColumn)
        }
        let views = TerminalRunSplitter.runs(cells: cells).enumerated().map { index, run in
            IdentifiedRun(index: index,
                          view: text(run.text, attribute: run.attribute, isCursor: run.isCursor))
        }

        return AnyView(HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(views) { $0.view }
        })
    }

    /// A single attributed run within a row, identified by position so SwiftUI can
    /// diff the `HStack` cheaply.
    private struct IdentifiedRun: Identifiable {
        let index: Int
        let view: AnyView
        var id: Int { index }
    }

    private func text(_ run: String, attribute: Attribute, isCursor: Bool = false) -> AnyView {
        var fgColor = attribute.fg
        var bgColor = attribute.bg

        if attribute.style.contains(.inverse) {
            swap(&bgColor, &fgColor)
            if fgColor == .defaultColor { fgColor = .defaultInvertedColor }
            if bgColor == .defaultColor { bgColor = .defaultInvertedColor }
        }

        let foreground = colorMap?.color(for: fgColor,
                                         isForeground: true,
                                         isBold: attribute.style.contains(.bold),
                                         isCursor: isCursor)
        let background = colorMap?.color(for: bgColor,
                                         isForeground: false,
                                         isCursor: isCursor)

        let font: UIFont?
        if attribute.style.contains(.bold) || attribute.style.contains(.blink) {
            font = attribute.style.contains(.italic) ? fontMetrics?.boldItalicFont : fontMetrics?.boldFont
        } else if attribute.style.contains(.dim) {
            font = attribute.style.contains(.italic) ? fontMetrics?.lightItalicFont : fontMetrics?.lightFont
        } else {
            font = attribute.style.contains(.italic) ? fontMetrics?.italicFont : fontMetrics?.regularFont
        }

        let width = CGFloat(run.unicodeScalars.reduce(0, { $0 + UnicodeUtil.columnWidth(rune: $1) })) * (fontMetrics?.width ?? 0)

        return AnyView(
            Text(run)
                .foregroundColor(Color(foreground ?? .white))
                .font(Font(font ?? .monospacedSystemFont(ofSize: 12, weight: .regular)))
                .underline(attribute.style.contains(.underline))
                .strikethrough(attribute.style.contains(.crossedOut))
                .tracking(0)
                .allowsTightening(false)
                .lineLimit(1)
                // `fixedSize` keeps the Text at its natural size so it never
                // ellipsizes to "…", while the EXACT-width frame pins the run to
                // its grid allocation. A run whose fallback glyphs render wider
                // than `columns x cellWidth` overdraws its right neighbour (as
                // real terminals do) instead of pushing the rest of the row
                // sideways -- drawn cells must coincide with the cells reported
                // by TerminalMouse, or taps land beside their visual target.
                .fixedSize(horizontal: true, vertical: true)
                .frame(width: width, alignment: .leading)
                .background(Color(background ?? .black))
        )
    }
}
