import Foundation
import Testing
import UIKit
@testable import MultiSessionAIManager

private struct FakePasteboard: TerminalPasteboardReading {
    var hasStrings = false
    var string: String?
    var hasImages = false
    var image: UIImage?
    var dataByType: [String: Data] = [:]

    func data(forPasteboardType pasteboardType: String) -> Data? {
        dataByType[pasteboardType]
    }

    func contains(pasteboardTypes: [String]) -> Bool {
        pasteboardTypes.contains { dataByType[$0] != nil }
    }
}

@Suite struct TerminalClipboardTests {
    @Test func imageOnlyClipboardDoesNotAdvertiseAnUnsupportedPaste() {
        let pasteboard = FakePasteboard(hasImages: true)

        #expect(!TerminalClipboard.canPaste(from: pasteboard))
        #expect(TerminalClipboard.payload(from: pasteboard) == nil)
    }

    @Test func textRemainsPasteableWhenAnUnsupportedImageIsAlsoPresent() throws {
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        let pasteboard = FakePasteboard(hasStrings: true,
                                        string: "fallback text",
                                        hasImages: true,
                                        dataByType: ["public.png": png])

        let payload = TerminalClipboard.payload(from: pasteboard)

        #expect(payload == .text("fallback text"))
    }

    @Test func rawPNGClipboardDoesNotAdvertiseAnUnsupportedPaste() {
        let png = Data([0x89, 0x50, 0x4e, 0x47])
        let pasteboard = FakePasteboard(hasImages: false,
                                        dataByType: ["public.png": png])

        #expect(!TerminalClipboard.canPaste(from: pasteboard))
        #expect(TerminalClipboard.payload(from: pasteboard) == nil)
    }

    @Test func textClipboardFallsBackToTextPayload() throws {
        let pasteboard = FakePasteboard(hasStrings: true,
                                        string: "hello",
                                        hasImages: false)

        let payload = TerminalClipboard.payload(from: pasteboard)

        #expect(payload == .text("hello"))
    }
}
