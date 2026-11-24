import Foundation
import Testing
@testable import MultiSessionAIManager

/// A link that is too long for its line is drawn over several rows, and a tap
/// on any of them has to give the whole link. On a Herdr screen the rows are
/// not the link's alone: the sidebar is to the left, another pane may be to
/// the right, each behind a vertical line. A sign-in link copied from such a
/// screen stopped where its first row ended (user report, 2026-11-24): the
/// rest was looked for at the start of the next row, where the sidebar's text
/// is.
///
/// The screens here are written by hand after what Herdr 0.9.5 draws.
@Suite struct TerminalLinkFinderTests {
    private static let signIn = "https://example.com/oauth/authorize?code=true&client_id=00000000-1111-2222-3333-444444444444"
        + "&response_type=code&redirect_uri=https%3A%2F%2Fplatform.example.com%2Foauth%2Fcode%2Fcallback"
        + "&scope=org%3Acreate_api_key+user%3Aprofile&code_challenge=AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_abcde&state=ZyXwVuTsRqPoNmLkJi"

    private static func padded(_ text: String, to width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - text.count))
    }

    /// What a terminal does with a line that is too long for its width.
    private static func wrapped(_ text: String, width: Int) -> [String] {
        var rows: [String] = []
        var rest = Substring(text)
        while !rest.isEmpty {
            rows.append(String(rest.prefix(width)))
            rest = rest.dropFirst(width)
        }
        return rows
    }

    private static func screen(_ rows: [String], columns: Int) -> [[Character]] {
        rows.map { Array(padded($0, to: columns)) }
    }

    private static let sidebarWidth = 25
    private static let sidebar = [
        " spaces", "", " ○ storefront", "   feat/search  ↑12", " ○ billing-api", "   main", " ○ data-migration", "   main",
        " ○ status-dashboard", "   main ↓8", " new                 menu", "─────────────────────────", " agents           grouped",
        " ○ storefront · agent", "   idle · session_01", " ○ billing-api · 1", "   idle",
    ]

    /// Herdr with one pane: the sidebar, a line, and the pane up to the right edge.
    private static func onePane(_ pane: [String], columns: Int = 100) -> [[Character]] {
        screen(pane.enumerated().map { index, text in
            padded(index < sidebar.count ? sidebar[index] : "", to: sidebarWidth) + "│" + text
        }, columns: columns)
    }

    /// Herdr with two panes side by side: each in a box of its own, the content
    /// one column short of the box's right side.
    private static func twoPanes(left: [String], right: [String], width: Int = 40) -> [[Character]] {
        let top = padded(sidebar[0], to: sidebarWidth) + "│" + String(repeating: "┌" + String(repeating: "─", count: width + 1) + "┐", count: 2)
        let rows = (0..<max(left.count, right.count)).map { index -> String in
            let beside = padded(index + 1 < sidebar.count ? sidebar[index + 1] : "", to: sidebarWidth) + "│"
            let leftText = padded(index < left.count ? left[index] : "", to: width)
            let rightText = padded(index < right.count ? right[index] : "", to: width)
            return beside + "│" + leftText + " │" + "│" + rightText + " │"
        }
        return screen([top] + rows, columns: sidebarWidth + 1 + 2 * (width + 3))
    }

    private static func link(_ screen: [[Character]], row: Int, column: Int) -> String? {
        TerminalLinkFinder.link(in: screen, atRow: row, column: column)?.absoluteString
    }

    // MARK: Beside the sidebar

    @Test func aLinkWrappedInAPaneBesideASidebarFullOfTextIsWhole() {
        let paneWidth = 100 - Self.sidebarWidth - 1
        let rows = ["   1      +", "  Browser didn't open? Use the URL below to sign in", ""]
            + Self.wrapped(Self.signIn, width: paneWidth)
            + ["", "  Paste code here if prompted"]
        let screen = Self.onePane(rows)
        let firstRow = 3
        let paneStart = Self.sidebarWidth + 1
        let rowsOfLink = Self.wrapped(Self.signIn, width: paneWidth).count
        #expect(rowsOfLink >= 4, "The link takes several rows here")

        // Every row of the link has sidebar text to its left.
        for row in firstRow..<(firstRow + rowsOfLink) {
            #expect(Self.link(screen, row: row, column: paneStart + 5) == Self.signIn, "tapped on row \(row)")
        }
        // The very last cell of a row that goes on below still belongs to it.
        #expect(Self.link(screen, row: firstRow, column: 99) == Self.signIn)
    }

    @Test func theSidebarIsNoPartOfALink() {
        let paneWidth = 100 - Self.sidebarWidth - 1
        let screen = Self.onePane(["", "", ""] + Self.wrapped(Self.signIn, width: paneWidth))

        // A tap on the sidebar's text, on a row of the link, is not a tap on the link.
        #expect(Self.link(screen, row: 4, column: 5) == nil)
    }

    @Test func aLinkThatStartsAfterOtherWordsIsWholeToo() {
        let paneWidth = 100 - Self.sidebarWidth - 1
        let line = "and then see " + Self.signIn + " for more"
        let screen = Self.onePane(["", "", ""] + Self.wrapped(line, width: paneWidth))

        #expect(Self.link(screen, row: 3, column: Self.sidebarWidth + 1 + 20) == Self.signIn)
        #expect(Self.link(screen, row: 5, column: Self.sidebarWidth + 1 + 3) == Self.signIn)
        // What follows the link on its last row is not part of it.
        let lastRow = 3 + Self.wrapped(line, width: paneWidth).count - 1
        #expect(Self.link(screen, row: lastRow, column: Self.sidebarWidth + 1 + 1) == Self.signIn)
    }

    // MARK: Beside another pane

    @Test func aLinkWrappedInTheLeftOfTwoPanesIsWhole() {
        let noise = (1...12).map { "right pane line \($0) with some words" }
        let left = ["Use the URL below"] + Self.wrapped(Self.signIn, width: 40) + ["and that was it"]
        let screen = Self.twoPanes(left: left, right: noise)
        let start = Self.sidebarWidth + 2
        let rowsOfLink = Self.wrapped(Self.signIn, width: 40).count
        #expect(rowsOfLink >= 5)

        for row in 2..<(2 + rowsOfLink) {
            #expect(Self.link(screen, row: row, column: start + 2) == Self.signIn, "tapped on row \(row)")
        }
    }

    @Test func aLinkWrappedInTheRightOfTwoPanesIsWhole() {
        let noise = (1...12).map { "left pane line \($0) with some words in" }
        let right = ["Use the URL below"] + Self.wrapped(Self.signIn, width: 40)
        let screen = Self.twoPanes(left: noise, right: right)
        let start = Self.sidebarWidth + 2 + 40 + 3

        #expect(Self.link(screen, row: 2, column: start + 2) == Self.signIn)
        #expect(Self.link(screen, row: 4, column: start + 10) == Self.signIn)
        // And the pane to the left is not looked into for it.
        #expect(Self.link(screen, row: 4, column: Self.sidebarWidth + 2 + 3) == nil)
    }

    // MARK: Where a link ends

    /// A link at the end of a line used to take the first word of the next
    /// line with it whenever it was 25 characters long.
    @Test func aLinkThatEndsItsLineIsNotJoinedToTheNextLinesFirstWord() {
        let lines = ["  See https://github.com/example/project/pull/12345", "  for the details of the change."]
        let alone = Self.screen(lines, columns: 100)
        #expect(Self.link(alone, row: 0, column: 20) == "https://github.com/example/project/pull/12345")
        #expect(Self.link(alone, row: 1, column: 3) == nil, "A word under a link is no link")

        let inAPane = Self.onePane(["", ""] + lines)
        #expect(Self.link(inAPane, row: 2, column: Self.sidebarWidth + 1 + 20) == "https://github.com/example/project/pull/12345")
        #expect(Self.link(inAPane, row: 3, column: Self.sidebarWidth + 1 + 3) == nil)
    }

    @Test func aLinkBrokenByTheProgramAtTheEdgeOfItsPaneIsWhole() {
        // A program that wraps its own lines, indented, one column short of the pane.
        let paneWidth = 100 - Self.sidebarWidth - 1
        let link = String(Self.signIn.prefix(110))
        let first = String(link.prefix(paneWidth - 3))
        let second = String(link.dropFirst(paneWidth - 3))
        let screen = Self.onePane(["", "", "  " + first, "  " + second, "", "  and a line after it"])

        #expect(Self.link(screen, row: 2, column: Self.sidebarWidth + 1 + 10) == link)
        #expect(Self.link(screen, row: 3, column: Self.sidebarWidth + 1 + 10) == link)
    }

    @Test func aLinkBrokenAfterASeparatorGoesOnBelowWhereverItStopped() {
        let screen = Self.onePane(["", "", "  https://example.com/releases/download/", "  v2.0/archive.tar.gz"])
        #expect(Self.link(screen, row: 2, column: Self.sidebarWidth + 1 + 10) == "https://example.com/releases/download/v2.0/archive.tar.gz")
    }

    @Test func aLinkUnderALinkIsItsOwn() {
        // The first one fills its row to the pane's edge, as one that goes on below would.
        let paneWidth = 100 - Self.sidebarWidth - 1
        let first = "https://example.com/first/" + String(repeating: "a", count: paneWidth - 26)
        let screen = Self.onePane(["", "", first, "https://example.com/second"])
        #expect(Self.link(screen, row: 3, column: Self.sidebarWidth + 1 + 4) == "https://example.com/second")
        #expect(Self.link(screen, row: 2, column: Self.sidebarWidth + 1 + 4) == first)
    }

    @Test func aLinkInATableIsNotJoinedToTheCellUnderIt() {
        // The lines between a table's columns end in ┬ and ┴, not in a corner:
        // they divide one pane's text, they are not the side of a pane.
        let table = [
            "┌──────────────────────────────────┬───────────────┐",
            "│ https://example.com/docs/install │ how to set up │",
            "│ notes                            │ read first    │",
            "└──────────────────────────────────┴───────────────┘",
        ]
        let screen = Self.onePane(["", ""] + table)
        #expect(Self.link(screen, row: 3, column: Self.sidebarWidth + 1 + 10) == "https://example.com/docs/install")
        #expect(Self.link(screen, row: 4, column: Self.sidebarWidth + 1 + 3) == nil)
    }

    @Test func aBlankLineEndsTheSearchUpwards() {
        let paneWidth = 100 - Self.sidebarWidth - 1
        let screen = Self.onePane(["", "", String(Self.signIn.prefix(paneWidth)), "", "words/that/could/go/on"])
        #expect(Self.link(screen, row: 4, column: Self.sidebarWidth + 1 + 3) == nil)
    }

    // MARK: Without Herdr

    @Test func aLinkTheTerminalItselfWrappedIsWhole() {
        let rows = Self.wrapped(Self.signIn, width: 60)
        let screen = Self.screen(rows + ["", "next"], columns: 60)
        for row in rows.indices {
            #expect(Self.link(screen, row: row, column: 4) == Self.signIn, "tapped on row \(row)")
        }
    }

    @Test func aRowTheTerminalSaysItWrappedGoesOnBelowEvenWhenItLooksShort() {
        // A wide character at the end of a row leaves its last column empty.
        let screen = Self.screen(["https://example.com/a/path/that/stops/early", "and/goes/on"], columns: 60)
        #expect(TerminalLinkFinder.link(in: screen, atRow: 0, column: 5, isSoftWrapped: { $0 == 0 })?.absoluteString
                == "https://example.com/a/path/that/stops/earlyand/goes/on")
        #expect(Self.link(screen, row: 0, column: 5) == "https://example.com/a/path/that/stops/early")
    }

    @Test func whatIsNotALinkIsNone() {
        let screen = Self.onePane(["", "", "  nothing to see here", "  mailto:someone@example.com is one though"])
        #expect(Self.link(screen, row: 2, column: Self.sidebarWidth + 1 + 6) == nil)
        #expect(Self.link(screen, row: 3, column: Self.sidebarWidth + 1 + 6) == "mailto:someone@example.com")
        #expect(Self.link(screen, row: 40, column: 3) == nil)
        #expect(Self.link(screen, row: 2, column: 400) == nil)
    }
}
