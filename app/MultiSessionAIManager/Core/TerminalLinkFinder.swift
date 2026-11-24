import Foundation

/// Finds the web address under a cell of the terminal's screen, whole, when it
/// is drawn over several rows.
///
/// A row of the screen is not always one line of one program. Herdr draws its
/// sidebar to the left and its panes side by side, each behind a vertical
/// line, and a link that is too long for its pane goes on in the next row of
/// that pane: after the same line, not at the start of the row, where the
/// sidebar's text is. So the search stays inside the pane the cell is in, and
/// treats that pane as the terminal the link was written to.
enum TerminalLinkFinder {
    private static let schemes: [[Character]] = ["https://", "http://", "mailto:", "file:", "ssh://", "git://"].map { Array($0) }
    private static let linkCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~:/?#[]@!$&'()*+,;=%")
    /// Lines a program draws around or between its text.
    private static let drawnLines = Set("│┃║┆┊╎╏╽╿|")
    /// The lines Herdr, and programs that draw boxes, put down the side of a pane.
    private static let sides: Set<Character> = ["│", "┃", "║"]
    private static let topCorners: Set<Character> = ["┌", "┐", "╭", "╮", "┏", "┓", "╔", "╗"]
    /// How far up a link is looked for: a sign-in link on a phone can take
    /// that many rows.
    private static let rowsLookedBack = 16

    /// - Parameters:
    ///   - screen: what is on the screen, one character per column.
    ///   - isSoftWrapped: whether the terminal itself ran that row on into the
    ///     next one. Only a row no pane divides can be.
    static func link(in screen: [[Character]], atRow row: Int, column: Int,
                     isSoftWrapped: (Int) -> Bool = { _ in false }) -> URL? {
        guard screen.indices.contains(row), column >= 0, column < screen[row].count else { return nil }

        // The pane the cell is in begins after the nearest side to its left.
        let leftSide = stride(from: column - 1, through: 0, by: -1).first { isSideOfAPane(screen, row: row, column: $0) }
        func cells(_ line: Int) -> (start: Int, cells: [Character])? {
            screen.indices.contains(line) ? rowOfPane(screen, row: line, leftSide: leftSide) : nil
        }
        guard let tapped = cells(row), column - tapped.start < tapped.cells.count else { return nil }
        let target = column - tapped.start
        let isUndivided = leftSide == nil && tapped.cells.count == screen[row].count

        // A link can have begun some rows up; a blank row, or the end of the
        // pane, is as far as it can reach.
        var first = row
        while row - first < rowsLookedBack, let above = cells(first - 1), !above.cells.allSatisfy(\.isWhitespace) {
            first -= 1
        }

        for start in first...row {
            guard let startRow = cells(start) else { continue }
            for range in links(in: startRow.cells) {
                var text = String(startRow.cells[range])
                var parts: [(row: Int, range: Range<Int>)] = [(start, range)]
                var current = startRow.cells

                while let next = cells(parts[parts.count - 1].row + 1)?.cells {
                    let end = parts[parts.count - 1].range.upperBound
                    // Anything else after it on its row, and the link ended there.
                    guard current[end...].allSatisfy(isBlankOrDrawn) else { break }

                    // A link goes on below when its row is full to the edge of
                    // the pane, when the terminal says it ran the row on, or
                    // when it stops after a separator, where programs that
                    // break lines themselves break a link. Its length alone
                    // says nothing: a link that ends its line would take the
                    // first word of the next line with it.
                    let width = current.count
                    let fillsItsRow = width - end <= max(2, min(6, width / 10))
                    let ranOn = isUndivided && isSoftWrapped(parts[parts.count - 1].row)
                    let stopsAtASeparator = text.last.map { "-/&=?#_".contains($0) } ?? false
                    guard fillsItsRow || ranOn || stopsAtASeparator else { break }

                    // A row that starts with a link of its own is not the rest of this one.
                    if let another = links(in: next).first, another.lowerBound < 10 { break }
                    guard let lead = next.firstIndex(where: { !isBlankOrDrawn($0) }) else { break }
                    let stop = next[lead...].firstIndex { !linkCharacters.contains($0) } ?? next.count
                    guard stop > lead else { break }
                    let longer = text + String(next[lead..<stop])
                    guard clean(longer) != nil else { break }

                    text = longer
                    parts.append((parts[parts.count - 1].row + 1, lead..<stop))
                    current = next
                }

                for (index, part) in parts.enumerated() where part.row == row {
                    // A finger is not exact: a little to either side counts,
                    // and so does the rest of a row the link fills.
                    let goesOn = index < parts.count - 1
                    let last = goesOn ? tapped.cells.count - 1 : min(tapped.cells.count - 1, part.range.upperBound + 3)
                    if target >= max(0, part.range.lowerBound - 3), target <= last {
                        return clean(text)
                    }
                }
            }
        }
        return nil
    }

    /// A link without what prose puts after one, if it is one the app opens.
    static func clean(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        while let last = text.last, ".,:;!?'\">]".contains(last) {
            if last == "]" {
                guard text.filter({ $0 == "]" }).count > text.filter({ $0 == "[" }).count else { break }
            }
            text.removeLast()
        }

        guard let url = URL(string: text) ?? URL(string: text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "file", "ssh", "git"].contains(scheme) else { return nil }
        return url
    }

    private static func isBlankOrDrawn(_ character: Character) -> Bool {
        character.isWhitespace || drawnLines.contains(character)
    }

    /// Where the links of one row begin and end.
    private static func links(in cells: [Character]) -> [Range<Int>] {
        var found: [Range<Int>] = []
        var index = 0
        while index < cells.count {
            if let scheme = schemes.first(where: { cells[index...].starts(with: $0) }) {
                let begins = index + scheme.count
                let ends = cells[begins...].firstIndex { !linkCharacters.contains($0) } ?? cells.count
                if ends > begins {
                    found.append(index..<ends)
                    index = ends
                    continue
                }
            }
            index += 1
        }
        return found
    }

    /// Whether the vertical line in this cell is the side of a pane or of a box.
    ///
    /// Such a line runs down from a corner, or from the top of the screen. The
    /// lines between the columns of a table run down from a ┬: they divide one
    /// pane's text and are no side of anything.
    private static func isSideOfAPane(_ screen: [[Character]], row: Int, column: Int) -> Bool {
        guard column < screen[row].count, sides.contains(screen[row][column]) else { return false }
        var above = row - 1
        while above >= 0, column < screen[above].count, sides.contains(screen[above][column]) {
            above -= 1
        }
        return above < 0 || (column < screen[above].count && topCorners.contains(screen[above][column]))
    }

    /// The cells of a row that lie in the pane whose left side is at
    /// `leftSide`, up to that pane's right side on this row. Nil when the
    /// pane does not reach this row.
    private static func rowOfPane(_ screen: [[Character]], row: Int, leftSide: Int?) -> (start: Int, cells: [Character])? {
        let cells = screen[row]
        var start = 0
        if let leftSide {
            guard leftSide < cells.count, sides.contains(cells[leftSide]) else { return nil }
            start = leftSide + 1
        }
        let end = (start..<cells.count).first { isSideOfAPane(screen, row: row, column: $0) } ?? cells.count
        return (start, Array(cells[start..<end]))
    }
}
