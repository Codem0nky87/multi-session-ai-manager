import CoreGraphics
import Foundation

/// One browser pane as the terminal shows it: where its placeholder is and how
/// big the placeholder says its pane is.
struct BrowserSpaceRegion: Equatable, Identifiable, Sendable {
    /// The id its space was opened with.
    let id: String
    /// Top left cell.
    let column: Int
    let row: Int
    /// Size in cells, as the placeholder measured its own pane.
    let columns: Int
    let rows: Int
}

/// What the placeholder paints (`Resources/msam-browser-space.sh`).
enum BrowserSpaceMarker {
    static let prefix = "[[AIM-BROWSER "
    static let fill: Character = "░"

    static func text(id: String, columns: Int, rows: Int) -> String {
        "\(prefix)\(id) \(columns)x\(rows)]]"
    }

    /// Reads a whole marker that starts at `start` of a row.
    static func parse(_ cells: [Character], at start: Int) -> (id: String, columns: Int, rows: Int, length: Int)? {
        let opening = Array(prefix)
        let bodyStart = start + opening.count
        guard start >= 0, bodyStart < cells.count, Array(cells[start..<bodyStart]) == opening else { return nil }
        // An id of at most twelve characters and two numbers of at most five digits.
        let limit = min(cells.count - 1, bodyStart + 26)
        guard bodyStart < limit,
              let close = (bodyStart..<limit).first(where: { cells[$0] == "]" && cells[$0 + 1] == "]" }) else {
            return nil
        }
        let parts = String(cells[bodyStart..<close]).split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let size = parts[1].split(separator: "x", omittingEmptySubsequences: false)
        guard !parts[0].isEmpty, parts[0].count <= 12, parts[0].allSatisfy(\.isHexDigit),
              size.count == 2, let columns = Int(size[0]), let rows = Int(size[1]),
              columns > 0, rows > 0 else { return nil }
        return (String(parts[0]), columns, rows, close + 2 - start)
    }
}

enum BrowserSpaceLocator {
    /// The browser panes that are wholly visible, in a grid of one array of
    /// cells per row.
    ///
    /// A pane counts only when every cell of the rectangle its marker claims is
    /// the fill, the marker apart. Anything else there (a Herdr menu over the
    /// pane, half of a repaint, a rectangle that runs off the screen) means the
    /// pane is not all there to be covered.
    static func regions(in grid: [[Character]]) -> [BrowserSpaceRegion] {
        let opening = Array(BrowserSpaceMarker.prefix)
        var found: [BrowserSpaceRegion] = []
        for (row, cells) in grid.enumerated() {
            var from = 0
            while let start = firstIndex(of: opening, in: cells, from: from) {
                from = start + 1
                guard let marker = BrowserSpaceMarker.parse(cells, at: start) else { continue }
                let region = BrowserSpaceRegion(id: marker.id, column: start, row: row,
                                                columns: marker.columns, rows: marker.rows)
                guard isWhollyFill(region, markerLength: marker.length, in: grid) else { continue }
                found.append(region)
                from = start + marker.columns
            }
        }
        return found
    }

    /// The same for the terminal's rendered rows. A screen without a browser
    /// costs one search per row.
    static func regions(in rows: [TerminalRenderedRow]) -> [BrowserSpaceRegion] {
        guard rows.contains(where: { $0.plainText.contains(BrowserSpaceMarker.prefix) }) else { return [] }
        return regions(in: rows.map(\.cells))
    }

    private static func firstIndex(of pattern: [Character], in cells: [Character], from: Int) -> Int? {
        guard !pattern.isEmpty, cells.count >= pattern.count, from <= cells.count - pattern.count else { return nil }
        return (from...cells.count - pattern.count).first { start in
            cells[start] == pattern[0] && Array(cells[start..<start + pattern.count]) == pattern
        }
    }

    private static func isWhollyFill(_ region: BrowserSpaceRegion, markerLength: Int, in grid: [[Character]]) -> Bool {
        guard markerLength <= region.columns, region.row + region.rows <= grid.count else { return false }
        for row in region.row..<region.row + region.rows {
            let cells = grid[row]
            guard region.column + region.columns <= cells.count else { return false }
            let first = row == region.row ? region.column + markerLength : region.column
            for column in first..<region.column + region.columns where cells[column] != BrowserSpaceMarker.fill {
                return false
            }
        }
        return true
    }
}

enum BrowserSpaceGeometry {
    /// Where a region is on screen. Herdr runs on the alternate screen, which the
    /// terminal view pins to its top left with no inset, so cells map straight
    /// to points.
    static func frame(of region: BrowserSpaceRegion, cell: CGSize) -> CGRect {
        CGRect(x: CGFloat(region.column) * cell.width, y: CGFloat(region.row) * cell.height,
               width: CGFloat(region.columns) * cell.width, height: CGFloat(region.rows) * cell.height)
    }
}

extension TerminalRenderedRow {
    /// One character per column, the way `character(atColumn:)` counts them.
    var cells: [Character] {
        var cells: [Character] = []
        for run in runs {
            let text = run.isPadding ? [] : Array(run.text.prefix(run.columns))
            cells.append(contentsOf: text)
            if text.count < run.columns {
                cells.append(contentsOf: repeatElement(" ", count: run.columns - text.count))
            }
        }
        return cells
    }
}
