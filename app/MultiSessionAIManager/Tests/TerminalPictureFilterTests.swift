import Foundation
import Testing
@testable import MultiSessionAIManager

/// AI Manager shows no pictures, but its terminal engine told programs it could.
/// A browser running in a terminal pane then streamed pictures the app threw
/// away: an empty pane, and megabytes a second over the connection.
@Suite struct TerminalPictureFilterTests {
    private static let esc = "\u{1b}"
    /// One whole frame as Herdr forwards it: sent in pieces, then placed.
    private static let frame = "\(esc)_Ga=t,t=d,f=24,s=320,v=200,i=1334961601,q=2,m=1;QUFBQUFB\(esc)\\"
        + "\(esc)_Gm=1;QkJCQkJC\(esc)\\\(esc)_Gm=0;Q0ND\(esc)\\"
        + "\(esc)_Ga=p,i=1334961601,p=1,c=35,r=10,z=0,C=1,q=2,w=320,h=200\(esc)\\"
    private static let query = "\(esc)_Gi=4207,a=q,t=d,f=24,s=1,v=1;AAAA\(esc)\\"

    private func strip(_ pieces: [String]) -> (text: String, drew: Bool) {
        var filter = TerminalPictureFilter()
        var kept: [UInt8] = []
        var drew = false
        for piece in pieces {
            let result = filter.strip(Array(piece.utf8))
            kept += result.bytes
            drew = drew || result.drew
        }
        return (String(decoding: kept, as: UTF8.self), drew)
    }

    @Test func ordinaryOutputPassesUntouched() {
        let output = "ls -la\r\n\(Self.esc)[1;32mok\(Self.esc)[0m \(Self.esc)]0;title\u{07}\(Self.esc)[?1004h héllo ✓"
        let result = strip([output])
        #expect(result.text == output)
        #expect(!result.drew)
    }

    @Test func aPictureIsRemovedAndTheTextAroundItStays() {
        let result = strip(["before \(Self.frame)after"])
        #expect(result.text == "before after")
        #expect(result.drew)
    }

    @Test func aPictureCutAnywhereByTheNetworkIsRemovedAllTheSame() {
        // Output arrives in pieces of any size. Wherever one ends, the result is
        // what it would have been in one piece, and nothing of a picture leaks.
        let output = "a\(Self.esc)[2J\(Self.frame)b\(Self.esc)_Xother\(Self.esc)\\c\(Self.frame)\(Self.esc)[H"
        let whole = strip([output])
        #expect(whole.text == "a\(Self.esc)[2Jb\(Self.esc)_Xother\(Self.esc)\\c\(Self.esc)[H")
        let bytes = Array(output.utf8)
        for cut in 1..<bytes.count {
            var filter = TerminalPictureFilter()
            let first = filter.strip(Array(bytes[..<cut]))
            let second = filter.strip(Array(bytes[cut...]))
            #expect(first.bytes + second.bytes == Array(whole.text.utf8), "cut at \(cut)")
            #expect(first.drew || second.drew, "cut at \(cut)")
        }
    }

    @Test func otherApplicationStringsAreNotPictures() {
        let output = "\(Self.esc)_Xsomething else\(Self.esc)\\ \(Self.esc)_gnot capital\(Self.esc)\\"
        #expect(strip([output]).text == output)
        #expect(!strip([output]).drew)
    }

    @Test func aProgramAskingWhetherPicturesWorkIsNotDrawing() {
        // The question is removed like any picture command, so the engine never
        // answers yes to it. But nothing was drawn: there is nothing to tell the user.
        let result = strip(["\(Self.query)\(Self.esc)[c"])
        #expect(result.text == "\(Self.esc)[c")
        #expect(!result.drew)
    }

    @Test func removingAPictureFromTheScreenIsNotDrawing() {
        let result = strip(["\(Self.esc)_Ga=d,d=I,i=7,q=2\(Self.esc)\\"])
        #expect(result.text.isEmpty)
        #expect(!result.drew)
    }

    @Test func aPictureCutOffByAnotherSequenceDoesNotSwallowIt() {
        // A string ends at ESC \. An ESC followed by anything else begins a new
        // sequence, which must reach the terminal.
        let result = strip(["\(Self.esc)_Ga=t,f=24;AAAA\(Self.esc)[31mred"])
        #expect(result.text == "\(Self.esc)[31mred")
    }

    @Test func aCancelledPictureLetsTheFollowingOutputThrough() {
        let result = strip(["\(Self.esc)_Ga=t,f=24;AAAA\u{18}plain"])
        #expect(result.text == "plain")
    }

    @Test func anEscapeAtTheVeryEndIsKeptForTheNextPiece() {
        // It may be the start of a picture; it is not lost if it is not.
        var filter = TerminalPictureFilter()
        #expect(filter.strip(Array("x\(Self.esc)".utf8)).bytes == Array("x".utf8))
        #expect(filter.strip(Array("[1m".utf8)).bytes == Array("\(Self.esc)[1m".utf8))
        #expect(filter.strip(Array("\(Self.esc)\(Self.esc)_G;A\(Self.esc)\\y".utf8)).bytes == Array("\(Self.esc)y".utf8))
    }
}
