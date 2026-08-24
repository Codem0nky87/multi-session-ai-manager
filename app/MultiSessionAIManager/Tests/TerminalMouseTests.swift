import Testing
import Foundation
@testable import MultiSessionAIManager

@Suite struct TerminalMouseTests {
    @Test func pressAtOriginIsOneBased() {
        #expect(TerminalMouse.sgr(.press, col: 0, row: 0) == Array("\u{1b}[<0;1;1M".utf8))
    }
    @Test func releaseUsesLowercaseM() {
        #expect(TerminalMouse.sgr(.release, col: 4, row: 2) == Array("\u{1b}[<0;5;3m".utf8))
    }
    @Test func dragSetsMotionFlag32() {
        #expect(TerminalMouse.sgr(.drag, col: 9, row: 1) == Array("\u{1b}[<32;10;2M".utf8))
    }
    @Test func largerCoordsFormat() {
        #expect(TerminalMouse.sgr(.press, col: 119, row: 49) == Array("\u{1b}[<0;120;50M".utf8))
    }
    @Test func negativeClampsToOne() {
        #expect(TerminalMouse.sgr(.press, col: -3, row: -1) == Array("\u{1b}[<0;1;1M".utf8))
    }

    @Test func cellAtOrigin() {
        let c = TerminalMouse.cell(x: 0, y: 0, cellWidth: 8, cellHeight: 16)
        #expect(c.col == 0 && c.row == 0)
    }
    @Test func cellRoundsDown() {
        let c = TerminalMouse.cell(x: 20, y: 40, cellWidth: 8, cellHeight: 16)
        #expect(c.col == 2 && c.row == 2)
    }
    @Test func cellExactBoundary() {
        let c = TerminalMouse.cell(x: 8, y: 16, cellWidth: 8, cellHeight: 16)
        #expect(c.col == 1 && c.row == 1)
    }
    @Test func cellClampsNegative() {
        let c = TerminalMouse.cell(x: -5, y: -5, cellWidth: 8, cellHeight: 16)
        #expect(c.col == 0 && c.row == 0)
    }
    @Test func cellZeroMetricsGuard() {
        let c = TerminalMouse.cell(x: 20, y: 40, cellWidth: 0, cellHeight: 0)
        #expect(c.col == 0 && c.row == 0)
    }

    // MARK: - Remote scroll wheel

    @Test func wheelUpIsButton64() {
        #expect(TerminalMouse.wheel(up: true, col: 0, row: 0) == Array("\u{1b}[<64;1;1M".utf8))
    }
    @Test func wheelDownIsButton65() {
        #expect(TerminalMouse.wheel(up: false, col: 4, row: 2) == Array("\u{1b}[<65;5;3M".utf8))
    }
    @Test func wheelIsOneBasedAndClamps() {
        #expect(TerminalMouse.wheel(up: true, col: -3, row: -1) == Array("\u{1b}[<64;1;1M".utf8))
    }
    @Test func wheelLargerCoords() {
        #expect(TerminalMouse.wheel(up: false, col: 119, row: 49) == Array("\u{1b}[<65;120;50M".utf8))
    }
}

@Suite struct TerminalScrollTicksTests {
    @Test func zeroBelowOneCell() {
        #expect(TerminalScroll.ticks(forDelta: 15, cellHeight: 16) == 0)
    }
    @Test func onePerWholeCell() {
        #expect(TerminalScroll.ticks(forDelta: 16, cellHeight: 16) == 1)
        #expect(TerminalScroll.ticks(forDelta: 39, cellHeight: 16) == 2)
    }
    @Test func negativePreservesDirection() {
        #expect(TerminalScroll.ticks(forDelta: -33, cellHeight: 16) == -2)
    }
    @Test func zeroCellHeightGuard() {
        #expect(TerminalScroll.ticks(forDelta: 40, cellHeight: 0) == 0)
    }
}
