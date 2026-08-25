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

final class TerminalStringSupplier {
    var terminal: Terminal!
    var colorMap: TerminalColorMap!
    var fontMetrics: TerminalFontMetrics!
    var cursorVisible = true

    func attributedString(forScrollInvariantRow row: Int) -> AnyView {
        guard let terminal = terminal else {
            return AnyView(EmptyView())
        }
        guard let line = terminal.getScrollInvariantLine(row: row) else {
            return AnyView(EmptyView())
        }

        let cursorPosition = terminal.getCursorLocation()
        let scrollbackRows = terminal.getTopVisibleRow()

        var lastAttribute = Attribute.empty
        var views = [IdentifiedRun]()
        var buffer = ""
        for j in 0..<terminal.cols {
            let data = line[j]
            let isCursor = cursorVisible && row - scrollbackRows == cursorPosition.y && j == cursorPosition.x

            if isCursor || lastAttribute != data.attribute {
                // Finish the previous run.
                views.append(IdentifiedRun(index: views.count, view: text(buffer, attribute: lastAttribute)))
                lastAttribute = data.attribute
                buffer.removeAll()
            }

            let character = data.getCharacter()
            buffer.append(character == "\0" ? " " : character)

            if isCursor {
                if buffer.isEmpty {
                    buffer.append(" ")
                }
                views.append(IdentifiedRun(index: views.count, view: text(buffer, attribute: lastAttribute, isCursor: true)))
                buffer.removeAll()
            }
        }

        // Final run.
        views.append(IdentifiedRun(index: views.count, view: text(buffer, attribute: lastAttribute)))

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
