import CoreGraphics
import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite struct BrowserSpaceLocatorTests {
    /// A screen like Herdr's: a sidebar, its border, and a pane to the right of it.
    private func screen(columns: Int = 60, rows: Int = 12,
                        pane: (column: Int, row: Int, columns: Int, rows: Int)? = (20, 1, 40, 11),
                        id: String = "7f3a2c") -> [[Character]] {
        var grid = (0..<rows).map { row -> [Character] in
            let sidebar = row == 0 ? " spaces" : (row == 5 ? " new            menu" : "")
            return Array((sidebar.padding(toLength: 19, withPad: " ", startingAt: 0) + "│")
                .padding(toLength: columns, withPad: " ", startingAt: 0))
        }
        if let pane {
            for row in pane.row..<pane.row + pane.rows {
                for column in pane.column..<pane.column + pane.columns { grid[row][column] = BrowserSpaceMarker.fill }
            }
            let marker = Array(BrowserSpaceMarker.text(id: id, columns: pane.columns, rows: pane.rows))
            grid[pane.row].replaceSubrange(pane.column..<pane.column + marker.count, with: marker)
        }
        return grid
    }

    @Test func aPaneThatIsWhollyFillIsFoundWhereItsMarkerIs() {
        #expect(BrowserSpaceLocator.regions(in: screen())
                == [BrowserSpaceRegion(id: "7f3a2c", column: 20, row: 1, columns: 40, rows: 11)])
    }

    @Test func aScreenWithoutAMarkerHasNoRegion() {
        #expect(BrowserSpaceLocator.regions(in: screen(pane: nil)).isEmpty)
    }

    @Test func somethingDrawnOverThePaneHidesIt() {
        var grid = screen()
        #expect(BrowserSpaceLocator.regions(in: grid).count == 1)
        // A Herdr menu in the middle of the pane, nowhere near the marker.
        grid[6].replaceSubrange(30..<36, with: Array("┌────┐"))
        #expect(BrowserSpaceLocator.regions(in: grid).isEmpty)
    }

    @Test func aPaneThatRunsOffTheScreenIsNotShown() {
        var grid = screen()
        #expect(BrowserSpaceLocator.regions(in: grid).count == 1)
        grid.removeLast(2)
        #expect(BrowserSpaceLocator.regions(in: grid).isEmpty)
    }

    @Test func aMarkerThatClaimsMoreThanIsFilledIsNotShown() {
        var grid = screen(columns: 70)
        #expect(BrowserSpaceLocator.regions(in: grid).count == 1)
        let wider = Array(BrowserSpaceMarker.text(id: "7f3a2c", columns: 41, rows: 11))
        grid[1].replaceSubrange(20..<20 + wider.count, with: wider)
        #expect(BrowserSpaceLocator.regions(in: grid).isEmpty)
    }

    @Test func twoPanesSideBySideAreBothFound() {
        var grid = screen(columns: 100, pane: (20, 1, 39, 11), id: "aaaaaa")
        for row in 1..<12 {
            for column in 60..<100 { grid[row][column] = BrowserSpaceMarker.fill }
        }
        let marker = Array(BrowserSpaceMarker.text(id: "bbbbbb", columns: 40, rows: 11))
        grid[1].replaceSubrange(60..<60 + marker.count, with: marker)

        #expect(BrowserSpaceLocator.regions(in: grid) == [
            BrowserSpaceRegion(id: "aaaaaa", column: 20, row: 1, columns: 39, rows: 11),
            BrowserSpaceRegion(id: "bbbbbb", column: 60, row: 1, columns: 40, rows: 11),
        ])
    }

    @Test(arguments: [
        "[[AIM-BROWSER 7f3a2c 40x11",          // cut short
        "[[AIM-BROWSER 7f3a2c 40]]",           // no rows
        "[[AIM-BROWSER zzzzzz 40x11]]",        // not an id
        "[[AIM-BROWSER 7f3a2c 0x11]]",         // no width
        "see [[AIM-BROWSER]] in the docs",     // talked about, in a shell
    ])
    func textThatOnlyLooksLikeAMarkerIsNotOne(text: String) {
        var grid = screen()
        let cells = Array(text.padding(toLength: 40, withPad: "░", startingAt: 0))
        grid[1].replaceSubrange(20..<60, with: cells)
        #expect(BrowserSpaceLocator.regions(in: grid).isEmpty)
    }

    @Test func aRegionIsLaidOutOnItsCells() {
        let region = BrowserSpaceRegion(id: "7f3a2c", column: 26, row: 1, columns: 113, rows: 39)
        #expect(BrowserSpaceGeometry.frame(of: region, cell: CGSize(width: 8, height: 17))
                == CGRect(x: 208, y: 17, width: 904, height: 663))
    }

    @MainActor @Test func theTerminalsOwnRowsAreRead() {
        // What the placeholder writes, through the app's terminal, beside a sidebar.
        let emulator = TerminalEmulator(cols: 60, rows: 12, frameClock: TestTerminalFrameClock())
        _ = emulator.setVisibility(true, for: TerminalVisibilityOwner())
        var bytes = "\u{1b}[?1049h"
        for row in 1...12 { bytes += "\u{1b}[\(row);1H spaces            │" }
        for row in 2...11 { bytes += "\u{1b}[\(row);21H" + String(repeating: "░", count: 40) }
        bytes += "\u{1b}[2;21H" + BrowserSpaceMarker.text(id: "7f3a2c", columns: 40, rows: 10)
        emulator.feed(Data(bytes.utf8))
        emulator.tick()

        #expect(BrowserSpaceLocator.regions(in: emulator.lines)
                == [BrowserSpaceRegion(id: "7f3a2c", column: 20, row: 1, columns: 40, rows: 10)])
    }
}
