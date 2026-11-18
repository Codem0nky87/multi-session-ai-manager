import Foundation

/// Herdr's "new" under its list of spaces.
///
/// Herdr draws its sidebar inside the terminal, so the app can only know the
/// label by what the row says: the sidebar's part of the row, up to its
/// border, reads `new` … `menu` and nothing else. When no row reads like that
/// (a collapsed sidebar, a Herdr that words it differently) nothing matches
/// and a tap goes to Herdr as it always did.
enum TerminalNewSpaceButton {
    static func isHit(column: Int, row cells: [Character]) -> Bool {
        guard let border = cells.firstIndex(of: "│") else { return false }
        let sidebar = cells[..<border]
        let words = String(sidebar).split(separator: " ")
        guard words.count == 2, words[0] == "new", words[1] == "menu",
              let start = sidebar.firstIndex(where: { $0 != " " }) else { return false }
        // The word and one cell either side: a finger is not a pointer.
        return (start - 1...start + 3).contains(column)
    }
}
