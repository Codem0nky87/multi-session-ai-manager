import Foundation
import Testing
@testable import MultiSessionAIManager

/// The watch runs on a PTY, which translates newlines and delivers arbitrary
/// chunks — a path WILL arrive split across two reads.
@Suite struct OutboxLineAccumulatorTests {

    @Test func aWholeLineIsReturnedImmediately() {
        var accumulator = RemoteFileDownload.LineAccumulator()
        #expect(accumulator.consume(Data("/tmp/a.txt\n".utf8)) == ["/tmp/a.txt"])
    }

    @Test func aPathSplitAcrossTwoReadsIsHeldUntilComplete() {
        // The failure this prevents: emitting "/tmp/rep" and "ort.pdf" as two
        // paths, both of which then fail to download.
        var accumulator = RemoteFileDownload.LineAccumulator()
        #expect(accumulator.consume(Data("/tmp/rep".utf8)).isEmpty)
        #expect(accumulator.consume(Data("ort.pdf\n".utf8)) == ["/tmp/report.pdf"])
    }

    @Test func carriageReturnsFromThePTYAreStripped() {
        // A PTY turns \n into \r\n; an untrimmed \r rides into the path and the
        // download fails with a filename that LOOKS right in any log.
        var accumulator = RemoteFileDownload.LineAccumulator()
        #expect(accumulator.consume(Data("/tmp/a.txt\r\n".utf8)) == ["/tmp/a.txt"])
    }

    @Test func severalLinesInOneChunkAllArrive() {
        var accumulator = RemoteFileDownload.LineAccumulator()
        let lines = accumulator.consume(Data("/a\n/b\n/c\n".utf8))
        #expect(lines == ["/a", "/b", "/c"])
    }

    @Test func blankLinesAreIgnored() {
        var accumulator = RemoteFileDownload.LineAccumulator()
        #expect(accumulator.consume(Data("\n\n/a\n\n".utf8)) == ["/a"])
    }

    @Test func aTrailingPartialLineIsNotEmittedEarly() {
        var accumulator = RemoteFileDownload.LineAccumulator()
        #expect(accumulator.consume(Data("/a\n/partial".utf8)) == ["/a"])
    }
}

@Suite struct OutboxPathAcceptanceTests {

    @Test func absolutePathsAreAccepted() {
        #expect(RemoteFileDownload.isAcceptable("/Users/alice/a.png"))
    }

    @Test func aRelativePathIsRefusedRatherThanGuessedAt() {
        // msam-send always queues an absolute path, so a relative entry means
        // something else wrote to the outbox. Resolving it against a guessed
        // directory would download the WRONG file and look like it worked.
        #expect(!RemoteFileDownload.isAcceptable("a.png"))
        #expect(!RemoteFileDownload.isAcceptable("../etc/passwd"))
    }

    @Test func anEmptyEntryIsRefused() {
        #expect(!RemoteFileDownload.isAcceptable(""))
    }
}

@Suite struct OutboxWatchCommandTests {

    private var command: String { RemoteFileDownload.watchCommand(identity: "tab-1") }

    @Test func theWatchReportsOnlyWhatArrivesAfterItStarts() {
        // Without -n 0 every reconnect replays the entire history of the outbox
        // and re-delivers every file the user ever sent.
        #expect(command.contains("-n 0"))
    }

    @Test func theWatchSurvivesTheFileBeingRecreated() {
        #expect(command.contains("-F"))
    }

    @Test func theWatchCreatesTheOutboxSoTailHasSomethingToFollow() {
        #expect(command.contains("mkdir -p"))
    }

    @Test func aWatcherEvictsWhateverThePreviousRunLeftBehind() {
        // Force-quitting the app leaves the TCP connection open, so sshd never
        // sends SIGHUP, and an idle `tail` never writes so it never learns its
        // reader is gone. Without this every relaunch adds another orphan.
        #expect(command.contains("kill "))
        #expect(command.contains("watch-tab-1.pid"))
    }

    @Test func thePidIsRecordedBEFOREExecSoItIsTheTailsOwnPid() {
        // `exec` replaces the shell in place, so `$$` captured beforehand is the
        // pid tail ends up running under. Recording it after would be too late,
        // and matching on a `pkill` pattern would be a guess.
        let pidWrite = try! #require(command.range(of: "> \"$pidfile\""))
        let execTail = try! #require(command.range(of: "exec tail"))
        #expect(pidWrite.lowerBound < execTail.lowerBound)
    }

    @Test func eachTabClaimsItsOwnSlot() {
        // A second tab -- or a second device -- must not evict a watcher that is
        // not its own.
        #expect(RemoteFileDownload.watchCommand(identity: "tab-a").contains("watch-tab-a.pid"))
        #expect(RemoteFileDownload.watchCommand(identity: "tab-b").contains("watch-tab-b.pid"))
    }

    @Test func theIdentityIsReducedToSomethingSafeInAShellAndAFilename() {
        // It reaches both a command line and a path.
        #expect(RemoteFileDownload.sanitizedIdentity("A1B2-C3") == "a1b2-c3")
        #expect(RemoteFileDownload.sanitizedIdentity("x; rm -rf ~") == "xrm-rf")
        #expect(RemoteFileDownload.sanitizedIdentity("../../etc") == "etc")
        #expect(RemoteFileDownload.sanitizedIdentity("") == "default")
        #expect(RemoteFileDownload.sanitizedIdentity(String(repeating: "a", count: 500)).count == 64)
    }

    @Test func aRealTabIdSurvivesSanitisationIntact() {
        // Tab ids are UUIDs; hyphens and hex are all allowed, so the identity
        // stays recognisable on the host rather than being mangled.
        let uuid = "3F2504E0-4F89-11D3-9A0C-0305E82C3301"
        #expect(RemoteFileDownload.sanitizedIdentity(uuid) == uuid.lowercased())
    }
}

@Suite @MainActor struct RemoteFileDownloadTests {

    private func makeService() async throws -> (SSHService, FakeSSHTransport) {
        let host = Host(name: "h", address: "10.0.0.1", port: 22,
                        username: "alice", keyID: "k", defaultWorkdir: "/home/alice")
        let transport = FakeSSHTransport()
        let knownHosts = KnownHostsStore(defaults: UserDefaults(suiteName: "msam.dl.\(UUID())")!)
        let service = SSHService(host: host, transport: transport, knownHosts: knownHosts)
        try await service.connect(key: SSHKeyMaterial(ed25519Seed: Data(repeating: 3, count: 32))) { _, _ in true }
        return (service, transport)
    }

    @Test func aQueuedFileIsDownloadedWithItsPathAndBytes() async throws {
        let (service, transport) = try await makeService()
        transport.remoteFiles["/tmp/report.pdf"] = Data("%PDF-1.7".utf8)

        let file = try await RemoteFileDownload.download("/tmp/report.pdf", using: service)

        #expect(file.remotePath == "/tmp/report.pdf")
        #expect(file.displayName == "report.pdf")
        #expect(file.fileExtension == "pdf")
        #expect(file.data == Data("%PDF-1.7".utf8))
    }

    @Test func anOversizeFileIsRefusedWITHOUTReadingIt() async throws {
        // The whole point of checking size first: a 2 GB log must not cross the
        // link at all, let alone land in an iPad's memory.
        let (service, transport) = try await makeService()
        let huge = RemoteFileDownload.maximumByteCount + 1
        transport.remoteFiles["/tmp/huge.log"] = Data(repeating: 0, count: huge)

        await #expect(throws: RemoteFileDownload.Failure.tooLarge(byteCount: huge)) {
            try await RemoteFileDownload.download("/tmp/huge.log", using: service)
        }
        #expect(transport.readPaths.isEmpty)
    }

    @Test func aMissingFileReportsNotFound() async throws {
        let (service, _) = try await makeService()
        await #expect(throws: RemoteFileDownload.Failure.notFound("/tmp/gone.txt")) {
            try await RemoteFileDownload.download("/tmp/gone.txt", using: service)
        }
    }

    @Test func aRelativePathIsRefusedBeforeAnyRoundTrip() async throws {
        let (service, transport) = try await makeService()
        await #expect(throws: RemoteFileDownload.Failure.self) {
            try await RemoteFileDownload.download("relative.txt", using: service)
        }
        #expect(transport.readPaths.isEmpty)
    }
}

@Suite struct IncomingFileFailureMessageTests {

    @Test func eachFailureGetsAnActionableSentence() {
        #expect(IncomingFileFailure.message(for: RemoteFileDownload.Failure.notFound("/tmp/x"))
            .contains("/tmp/x"))
        #expect(IncomingFileFailure.message(
            for: RemoteFileDownload.Failure.tooLarge(byteCount: 60 * 1_048_576)
        ).contains("60.0 MB"))
        #expect(IncomingFileFailure.message(for: RemoteFileDownload.Failure.downloadFailed("boom"))
            .contains("boom"))
    }
}

#if canImport(UIKit)
import UIKit
import UniformTypeIdentifiers

@Suite @MainActor struct IncomingFileSheetHelperTests {

    private func file(_ name: String, _ data: Data) -> IncomingFile {
        IncomingFile(remotePath: "/home/alice/\(name)", data: data)
    }

    @Test func aKnownExtensionGetsItsRealContentType() {
        #expect(IncomingFileSheet.contentType(for: file("a.pdf", Data([1]))) == .pdf)
    }

    @Test func anUnknownOrMissingExtensionFallsBackToRawData() {
        // A WRONG content type makes Files refuse the save outright; the
        // generic one always works and merely loses the icon.
        #expect(IncomingFileSheet.contentType(for: file("README", Data([1]))) == .data)
        #expect(IncomingFileSheet.contentType(for: file("a.wat", Data([1]))) == .data)
    }

    @Test func realTextGetsAPreview() {
        let text = "line one\nline two\n"
        #expect(IncomingFileSheet.previewText(for: file("a.log", Data(text.utf8))) == text)
    }

    @Test func binaryIsNOTRenderedAsReplacementCharacters() {
        // A PNG shown as mojibake is worse than saying there is no preview.
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0xFE])
        #expect(IncomingFileSheet.previewText(for: file("a.png", png)) == nil)
    }

    @Test func textContainingNULIsTreatedAsBinary() {
        // Valid UTF-8 can still be a binary format; an embedded NUL is the tell.
        let data = Data("abc\u{0}def".utf8)
        #expect(IncomingFileSheet.previewText(for: file("a.bin", data)) == nil)
    }

    @Test func anEnormousTextFileIsNotDecodedIntoTheView() {
        let big = Data(repeating: 0x61, count: 300_000)
        #expect(IncomingFileSheet.previewText(for: file("big.log", big), limit: 200_000) == nil)
    }

    @Test func theSharedTemporaryFileKeepsTheHostsName() throws {
        // Sharing a file called "Untitled" loses the one piece of context that
        // tells the user what they are looking at.
        let url = try #require(IncomingFileSheet.temporaryURL(for: file("report.pdf", Data("x".utf8))))
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(url.lastPathComponent == "report.pdf")
        #expect(try Data(contentsOf: url) == Data("x".utf8))
    }
}

#endif
