import Foundation
import Testing
import UniformTypeIdentifiers
@testable import MultiSessionAIManager

#if canImport(UIKit)
import UIKit

private func solidImage() -> UIImage {
    UIGraphicsImageRenderer(size: CGSize(width: 6, height: 6)).image { ctx in
        UIColor.blue.setFill()
        ctx.fill(CGRect(x: 0, y: 0, width: 6, height: 6))
    }
}

/// An image reaches the pasteboard in more than one shape, and `UIPasteboard.image`
/// only covers the friendliest of them.
@Suite struct PasteboardImageReaderTests {

    /// A private pasteboard, so these never touch (or clobber) the real one.
    private func withScratchPasteboard(_ body: (UIPasteboard) throws -> Void) rethrows {
        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        try body(pasteboard)
    }

    @Test func aPlainCopiedImageIsFound() throws {
        try withScratchPasteboard { pasteboard in
            pasteboard.image = solidImage()
            #expect(PasteboardImageReader.image(from: pasteboard) != nil)
            #expect(PasteboardImageReader.hasImage(pasteboard))
        }
    }

    @Test func rawImageDataUnderATypedEntryIsFound() throws {
        // What an image copied out of another app often looks like: bytes under
        // a declared UTI, with `UIPasteboard.image` returning nil.
        try withScratchPasteboard { pasteboard in
            let png = try #require(solidImage().pngData())
            pasteboard.setData(png, forPasteboardType: UTType.png.identifier)

            #expect(PasteboardImageReader.image(from: pasteboard) != nil)
            #expect(PasteboardImageReader.hasImage(pasteboard))
        }
    }

    @Test func anImageFileURLOnThePasteboardIsFollowed() throws {
        // Copying a file in Files puts a URL on the pasteboard, not pixels.
        let png = try #require(solidImage().pngData())
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msam-paste-\(UUID()).png")
        try png.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        try withScratchPasteboard { pasteboard in
            pasteboard.url = url
            #expect(PasteboardImageReader.image(from: pasteboard) != nil)
        }
    }

    @Test func plainTextIsNotMistakenForAnImage() throws {
        try withScratchPasteboard { pasteboard in
            pasteboard.string = "ls -la"
            #expect(PasteboardImageReader.image(from: pasteboard) == nil)
            #expect(!PasteboardImageReader.hasImage(pasteboard))
        }
    }

    @Test func anEmptyPasteboardYieldsNothing() throws {
        try withScratchPasteboard { pasteboard in
            #expect(PasteboardImageReader.image(from: pasteboard) == nil)
            #expect(!PasteboardImageReader.hasImage(pasteboard))
        }
    }
}

@Suite struct LocalImageLoaderTests {

    private func writeTemp(_ data: Data, ext: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("msam-file-\(UUID()).\(ext)")
        try data.write(to: url)
        return url
    }

    @Test func anImageFileLoads() throws {
        let png = try #require(solidImage().pngData())
        let url = try writeTemp(png, ext: "png")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: Never.self) { try LocalImageLoader.load(from: url) }
    }

    @Test func anOrdinaryContainerURLLoadsWhateverTheSecurityScopeReports() throws {
        // THE trap this guards: `startAccessingSecurityScopedResource()` is
        // documented to return false for URLs that are not security-scoped, and
        // a `guard` on that return value looks like careful code while breaking
        // ordinary reads. The loader must therefore treat the scope as
        // best-effort and let the READ decide -- which is what this proves for a
        // plain container URL, whichever way the platform answers.
        let png = try #require(solidImage().pngData())
        let url = try writeTemp(png, ext: "png")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: Never.self) { try LocalImageLoader.load(from: url) }
    }

    @Test func aMissingFileReportsUnreadableRatherThanCrashing() {
        let url = URL(fileURLWithPath: "/nope/\(UUID()).png")
        #expect(throws: LocalImageLoader.Failure.unreadable) {
            try LocalImageLoader.load(from: url)
        }
    }

    @Test func aFileThatIsNotAnImageIsRejected() throws {
        let url = try writeTemp(Data("not an image".utf8), ext: "png")
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(throws: LocalImageLoader.Failure.notAnImage) {
            try LocalImageLoader.load(from: url)
        }
    }
}
#endif
