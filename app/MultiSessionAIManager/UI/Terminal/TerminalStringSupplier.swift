//
//  TerminalStringSupplier.swift
//  MultiSessionAIManager
//
//  Turns one core-`Terminal` buffer row into stable value runs. SwiftUI styling
//  happens separately in `TerminalRenderedRowView`, so unchanged terminal rows
//  remain equatable across render frames.
//

import Foundation
import SwiftTerm
import SwiftUI

// SwiftTerm 1.13 does not annotate `Attribute` as Sendable, although it contains
// only value fields. These immutable render snapshots are safe to compare from
// Equatable's nonisolated requirement.
struct TerminalRenderedRun: Identifiable, Equatable, @unchecked Sendable {
    let id: Int
    let text: String
    let attribute: Attribute
    let isCursor: Bool
    let columns: Int
    let isPadding: Bool
}

struct TerminalRenderedRow: Identifiable, Equatable, @unchecked Sendable {
    let id: Int
    let runs: [TerminalRenderedRun]

    /// The retained row text without blank cells used only to pad the terminal
    /// grid. It is derived from runs so the renderer stores no duplicate string.
    var plainText: String {
        guard let lastContent = runs.lastIndex(where: { !$0.isPadding }) else {
            return ""
        }
        return runs[...lastContent].map(\.text).joined()
    }
}

extension TerminalRenderedRow {
    init(
        id: Int,
        cells: [(char: Character, attribute: Attribute, isCursor: Bool)]
    ) {
        self.init(
            id: id,
            cells: cells.map { cell in
                (
                    char: cell.char,
                    attribute: cell.attribute,
                    isCursor: cell.isCursor,
                    columns: cell.char.unicodeScalars.reduce(0) {
                        $0 + UnicodeUtil.columnWidth(rune: $1)
                    },
                    isPadding: false
                )
            }
        )
    }

    init(
        id: Int,
        cells: [(
            char: Character,
            attribute: Attribute,
            isCursor: Bool,
            columns: Int,
            isPadding: Bool
        )]
    ) {
        self.id = id
        self.runs = TerminalRunSplitter.sizedRuns(cells: cells).enumerated().map { index, run in
            TerminalRenderedRun(
                id: index,
                text: run.text,
                attribute: run.attribute,
                isCursor: run.isCursor,
                columns: run.columns,
                isPadding: run.isPadding
            )
        }
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
        sizedRuns(cells: cells.map { cell in
            (
                char: cell.char,
                attribute: cell.attribute,
                isCursor: cell.isCursor,
                columns: cell.char.unicodeScalars.reduce(0) {
                    $0 + UnicodeUtil.columnWidth(rune: $1)
                },
                isPadding: false
            )
        }).map { (text: $0.text, attribute: $0.attribute, isCursor: $0.isCursor) }
    }

    static func sizedRuns<A: Equatable>(
        cells: [(
            char: Character,
            attribute: A,
            isCursor: Bool,
            columns: Int,
            isPadding: Bool
        )]
    ) -> [(
        text: String,
        attribute: A,
        isCursor: Bool,
        columns: Int,
        isPadding: Bool
    )] {
        var result = [(
            text: String,
            attribute: A,
            isCursor: Bool,
            columns: Int,
            isPadding: Bool
        )]()
        var buffer = ""
        var bufferAttribute: A?
        var bufferColumns = 0
        var bufferIsPadding = false

        func flush() {
            if let attribute = bufferAttribute, !buffer.isEmpty {
                result.append((
                    text: buffer,
                    attribute: attribute,
                    isCursor: false,
                    columns: bufferColumns,
                    isPadding: bufferIsPadding
                ))
            }
            buffer = ""
            bufferAttribute = nil
            bufferColumns = 0
            bufferIsPadding = false
        }

        for cell in cells {
            guard cell.columns > 0 else { continue }
            if cell.isCursor || Self.isolates(cell.char) {
                flush()
                result.append((
                    text: String(cell.char),
                    attribute: cell.attribute,
                    isCursor: cell.isCursor,
                    columns: cell.columns,
                    isPadding: cell.isPadding
                ))
                continue
            }
            if bufferAttribute != cell.attribute || bufferIsPadding != cell.isPadding {
                flush()
                bufferAttribute = cell.attribute
                bufferIsPadding = cell.isPadding
            }
            buffer.append(cell.char)
            bufferColumns += cell.columns
        }
        flush()
        return result
    }
}

final class TerminalStringSupplier {
    var terminal: Terminal!
    var cursorVisible = true

    /// Render a host-owned row directly from SwiftTerm's visible viewport.
    func renderedViewportRow(_ row: Int) -> TerminalRenderedRow? {
        guard let terminal,
              row >= 0,
              row < terminal.rows,
              let line = terminal.getLine(row: row)
        else { return nil }
        let cursor = terminal.getCursorLocation()
        return renderedRow(
            row: row,
            cursorColumn: cursorVisible && row == cursor.y ? cursor.x : nil,
            cellAtColumn: { line[$0] }
        )
    }

    /// Render a bounded UI row directly in the buffer-relative coordinate space
    /// shared by SwiftTerm's selection and text-extraction APIs.
    func renderedBufferRow(_ row: Int, rowCount: Int) -> TerminalRenderedRow? {
        guard let terminal, row >= 0, row < rowCount else { return nil }
        let buffer = terminal.buffer
        let cursor = terminal.getCursorLocation()
        let cursorRow = terminal.getTopVisibleRow() + cursor.y
        return renderedRow(
            row: row,
            cursorColumn: cursorVisible && row == cursorRow ? cursor.x : nil,
            cellAtColumn: { column in
                buffer.getChar(
                    atBufferRelative: Position(col: column, row: row)
                )
            }
        )
    }

    private func renderedRow(
        row: Int,
        cursorColumn: Int?,
        cellAtColumn: (Int) -> CharData
    ) -> TerminalRenderedRow? {
        guard let terminal else { return nil }
        let cells = (0..<terminal.cols).map { j in
            let data = cellAtColumn(j)
            let character = terminal.getCharacter(for: data)
            let isPadding = character == "\0"
            return (
                char: isPadding ? " " : character,
                attribute: data.attribute,
                isCursor: j == cursorColumn,
                columns: Int(data.width),
                isPadding: isPadding
            )
        }
        return TerminalRenderedRow(id: row, cells: cells)
    }
}

struct TerminalRenderedRowView: View, Equatable {
    nonisolated let row: TerminalRenderedRow
    let colorMap: TerminalColorMap
    let fontMetrics: TerminalFontMetrics
    nonisolated let styleGeneration: Int

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.styleGeneration == rhs.styleGeneration
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            ForEach(row.runs) { run in
                text(run)
            }
        }
    }

    private func text(_ run: TerminalRenderedRun) -> some View {
        let attribute = run.attribute
        var fgColor = attribute.fg
        var bgColor = attribute.bg

        if attribute.style.contains(.inverse) {
            swap(&bgColor, &fgColor)
            if fgColor == .defaultColor { fgColor = .defaultInvertedColor }
            if bgColor == .defaultColor { bgColor = .defaultInvertedColor }
        }

        let foreground = colorMap.color(for: fgColor,
                                        isForeground: true,
                                        isBold: attribute.style.contains(.bold),
                                        isCursor: run.isCursor)
        let background = colorMap.color(for: bgColor,
                                        isForeground: false,
                                        isCursor: run.isCursor)

        let font: UIFont
        if attribute.style.contains(.bold) || attribute.style.contains(.blink) {
            font = attribute.style.contains(.italic)
                ? fontMetrics.boldItalicFont : fontMetrics.boldFont
        } else if attribute.style.contains(.dim) {
            font = attribute.style.contains(.italic)
                ? fontMetrics.lightItalicFont : fontMetrics.lightFont
        } else {
            font = attribute.style.contains(.italic)
                ? fontMetrics.italicFont : fontMetrics.regularFont
        }

        let width = CGFloat(run.columns) * fontMetrics.width

        return Text(run.text)
            .foregroundColor(Color(foreground))
            .font(Font(font))
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
            .background(Color(background))
    }
}
