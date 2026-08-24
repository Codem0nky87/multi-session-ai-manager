import Testing
import Foundation
import SwiftTerm
@testable import MultiSessionAIManager

/// Does SwiftTerm's core parser end up with the CORRECT buffer after the exact byte
/// sequences a line editor sends on backspace? If the buffer is wrong here, no amount
/// of repaint fixes the "backspace leaves a ghost" the user sees in a bare shell.
@Suite struct TerminalEraseTests {

    final class NoopDelegate: TerminalDelegate {
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
    }

    private func lineText(_ term: Terminal, row: Int = 0, cols: Int = 20) -> String {
        term.getText(start: Position(col: 0, row: row), end: Position(col: cols, row: row))
            .trimmingCharacters(in: .whitespaces)
    }

    /// bash/readline backspace = `\b` (cursor left) + `ESC[K` (erase to end of line).
    /// Captured live from bash on the target Mac: 08 1b5b4b.
    @Test func bashBackspaceErasesCell() {
        let term = Terminal(delegate: NoopDelegate())
        term.feed(text: "abc")
        term.feed(byteArray: [0x08, 0x1b, 0x5b, 0x4b])   // backspace once
        term.feed(byteArray: [0x08, 0x1b, 0x5b, 0x4b])   // backspace twice
        #expect(lineText(term) == "a")
    }

    /// Some editors send `\b \b` (left, space, left) instead.
    @Test func backspaceSpaceBackspaceErasesCell() {
        let term = Terminal(delegate: NoopDelegate())
        term.feed(text: "abc")
        term.feed(byteArray: [0x08, 0x20, 0x08])
        #expect(lineText(term) == "ab")
    }

    /// Carriage-return rewrite (editline/zsh often redraw the whole line): CR to
    /// column 0, rewrite shorter text, then `ESC[K` to clear the tail.
    @Test func carriageReturnRewriteClearsTail() {
        let term = Terminal(delegate: NoopDelegate())
        term.feed(text: "abcdef")
        term.feed(byteArray: [0x0d])                       // CR → col 0
        term.feed(text: "abc")
        term.feed(byteArray: [0x1b, 0x5b, 0x4b])           // ESC[K erase to EOL
        #expect(lineText(term) == "abc")
    }

    // MARK: - XTWINOPS size-query suppression (the bare-shell backspace garbage fix)

    /// `ESC[18t` / `ESC[14t` etc. size QUERIES are stripped so SwiftTerm doesn't
    /// auto-reply with a report a line editor would read as input.
    @Test func sizeReportQueriesAreStripped() {
        let f = TerminalEmulator.dropSizeReportQueries
        // 'a' + ESC[18t + 'b'  → "ab"
        #expect(f([0x61, 0x1b, 0x5b, 0x31, 0x38, 0x74, 0x62]) == [0x61, 0x62])
        // ESC[14t dropped too
        #expect(f([0x1b, 0x5b, 0x31, 0x34, 0x74]) == [])
        // 15t / 16t / 19t dropped
        #expect(f([0x1b, 0x5b, 0x31, 0x35, 0x74]) == [])
        #expect(f([0x1b, 0x5b, 0x31, 0x39, 0x74]) == [])
    }

    /// Must NOT touch a size REPORT (`ESC[8;..t`, starts ESC[8 not ESC[1), SGR
    /// (`ESC[1m`), or other CSI — only the size queries.
    @Test func sizeReportsAndOtherCSIPassThrough() {
        let f = TerminalEmulator.dropSizeReportQueries
        let report: [UInt8] = [0x1b, 0x5b, 0x38, 0x3b, 0x31, 0x39, 0x3b, 0x31, 0x38, 0x33, 0x74] // ESC[8;19;183t
        #expect(f(report) == report)
        let sgrBold: [UInt8] = [0x1b, 0x5b, 0x31, 0x6d]   // ESC[1m
        #expect(f(sgrBold) == sgrBold)
        let title: [UInt8] = [0x1b, 0x5b, 0x32, 0x31, 0x74] // ESC[21t (report title) — not a size query
        #expect(f(title) == title)
        let plain: [UInt8] = Array("hello world".utf8)
        #expect(f(plain) == plain)
    }
}
