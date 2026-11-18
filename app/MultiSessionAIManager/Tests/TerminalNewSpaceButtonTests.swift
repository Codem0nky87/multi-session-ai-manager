import Testing
@testable import MultiSessionAIManager

@Suite struct TerminalNewSpaceButtonTests {
    /// Row 19 of a real Herdr 0.9.5 screen, 140 columns wide.
    private let row = Array(" new                 menu│" + String(repeating: "░", count: 114))

    @Test(arguments: [0, 1, 2, 3, 4])
    func aTapOnTheWordOrRightBesideItCounts(column: Int) {
        #expect(TerminalNewSpaceButton.isHit(column: column, row: row))
    }

    @Test(arguments: [5, 12, 21, 24, 25, 60])
    func aTapElsewhereOnTheRowDoesNot(column: Int) {
        #expect(!TerminalNewSpaceButton.isHit(column: column, row: row))
    }

    @Test(arguments: [
        " · scratchpad            │",        // a space in the list
        " new                     │",        // not Herdr's row: no "menu"
        " new project         menu│",        // three words
        " agents           grouped│",
        "new menu",                           // no sidebar border: a shell line
        "│ new                menu",          // the words are in a pane, not the sidebar
        "",
    ])
    func otherRowsAreNotTheButton(text: String) {
        for column in 0..<4 {
            #expect(!TerminalNewSpaceButton.isHit(column: column, row: Array(text)))
        }
    }
}
