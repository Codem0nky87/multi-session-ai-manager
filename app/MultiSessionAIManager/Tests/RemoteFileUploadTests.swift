import Foundation
import Testing
@testable import MultiSessionAIManager

/// A terminal carries text, so an image can never be pasted into one. The bytes
/// go to the host's filesystem over the tab's ALREADY-authenticated SSH
/// connection, and only the path travels through the PTY. These pin the parts
/// of that trip that are quiet to break and loud to debug.
@Suite struct RemoteFileUploadNamingTests {

    /// 2026-08-23 13:45:02.118 UTC
    private var instant: Date {
        Date(timeIntervalSince1970: 1_787_492_702.118)
    }

    @Test func filenameIsDerivedFromTheInstantAndIsAPNG() {
        let name = RemoteFileUpload.filename(at: instant, fileExtension: "png")
        #expect(name.hasSuffix(".png"))
        #expect(name.hasPrefix("msam-"))
    }

    @Test func twoUploadsInTheSameSecondDoNotCollide() {
        // sub-second precision is the whole reason the name carries milliseconds;
        // a seconds-resolution stamp silently overwrites the first image when
        // someone sends two in quick succession.
        let first = RemoteFileUpload.filename(at: instant, fileExtension: "png")
        let second = RemoteFileUpload.filename(at: instant.addingTimeInterval(0.4), fileExtension: "png")
        #expect(first != second)
    }

    @Test func theSameInstantAlwaysProducesTheSameName() {
        #expect(RemoteFileUpload.filename(at: instant, fileExtension: "png") == RemoteFileUpload.filename(at: instant, fileExtension: "png"))
    }

    @Test func filenameNeedsNoShellQuoting() {
        // THE load-bearing invariant: this path is TYPED INTO A SHELL PROMPT.
        // A space, quote, or glob character would make the agent's shell parse
        // it as several arguments. The name is generated from digits and
        // hyphens so that is true by construction -- this test is what stops a
        // later "use the original photo filename" change from breaking it.
        let name = RemoteFileUpload.filename(at: instant, fileExtension: "png")
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        #expect(name.unicodeScalars.allSatisfy { safe.contains($0) })
    }

    @Test func pathIsAbsoluteAndUnderTheUploadsDirectory() {
        let path = RemoteFileUpload.path(home: "/Users/alice", filename: "msam-1.png")
        #expect(path == "/Users/alice/.msam/uploads/msam-1.png")
    }

    @Test func aHomeWithATrailingSlashDoesNotProduceADoubleSlash() {
        // `printf %s "$HOME"` returns "/root" on most hosts but "/" is a real
        // possibility for a root-homed account, and "//x" reads as a UNC path.
        #expect(RemoteFileUpload.path(home: "/root/", filename: "a.png")
            == "/root/.msam/uploads/a.png")
        #expect(RemoteFileUpload.path(home: "/", filename: "a.png")
            == "/.msam/uploads/a.png")
    }
}

@Suite struct RemoteFileUploadPaneInsertionTests {

    @Test func theInsertionEndsWithASpaceSoTypingCanContinue() {
        #expect(RemoteFileUpload.paneInsertion(for: "/h/a.png") == "/h/a.png ")
    }

    @Test func theInsertionNEVERCarriesANewline() {
        // Sending Enter would submit a bare path as a prompt on its own, before
        // the user has said what to do with the image. This is exactly the kind
        // of thing a later refactor "helpfully" adds, so it is pinned.
        let insertion = RemoteFileUpload.paneInsertion(for: "/h/a.png")
        #expect(!insertion.contains("\n"))
        #expect(!insertion.contains("\r"))
    }
}

@Suite struct RemoteFileUploadPreparationTests {

    @Test func oneRoundTripBothCreatesTheDirectoryAndReportsHome() {
        // Two commands would be two round trips over a link that may be going
        // through WARP; they are deliberately fused.
        let command = RemoteFileUpload.prepareCommand
        #expect(command.contains("mkdir -p"))
        #expect(command.contains(RemoteFileUpload.relativeDirectory))
        #expect(command.contains("printf %s \"$HOME\""))
    }
}

@Suite @MainActor struct RemoteFileUploadTransferTests {

    private func makeService() async throws -> (SSHService, FakeSSHTransport) {
        let host = Host(name: "h", address: "10.0.0.1", port: 22,
                        username: "alice", keyID: "k", defaultWorkdir: "/home/alice")
        let transport = FakeSSHTransport()
        let knownHosts = KnownHostsStore(defaults: UserDefaults(suiteName: "msam.img.\(UUID())")!)
        let service = SSHService(host: host, transport: transport, knownHosts: knownHosts)
        try await service.connect(key: SSHKeyMaterial(ed25519Seed: Data(repeating: 7, count: 32))) { _, _ in true }
        return (service, transport)
    }

    @Test func uploadWritesTheBytesAndReturnsTheAbsolutePath() async throws {
        let (service, transport) = try await makeService()
        transport.defaultCommandResponse = "/home/alice"
        let bytes = Data([0x89, 0x50, 0x4E, 0x47])

        let path = try await RemoteFileUpload.upload(bytes, fileExtension: "png", using: service, at: Date())

        #expect(path.hasPrefix("/home/alice/.msam/uploads/"))
        #expect(transport.writtenFiles[path] == bytes)
    }

    @Test func theReportedHomeIsTrimmedBeforeUse() async throws {
        // a login shell can emit a trailing newline even after `printf %s`;
        // an untrimmed home yields the path "/home/alice\n/.msam/..."
        let (service, transport) = try await makeService()
        transport.defaultCommandResponse = "/home/alice\n"

        let path = try await RemoteFileUpload.upload(Data([1]), fileExtension: "png", using: service, at: Date())

        #expect(!path.contains("\n"))
        #expect(path.hasPrefix("/home/alice/.msam/uploads/"))
    }

    @Test func anEmptyImageIsRejectedBeforeAnyRoundTrip() async throws {
        let (service, transport) = try await makeService()
        await #expect(throws: RemoteFileUpload.Failure.emptyFile) {
            try await RemoteFileUpload.upload(Data(), fileExtension: "png", using: service, at: Date())
        }
        #expect(transport.commandsRun.isEmpty)
    }

    @Test func anOversizeImageIsRejectedBeforeAnyRoundTrip() async throws {
        let (service, transport) = try await makeService()
        let huge = RemoteFileUpload.maximumByteCount + 1
        await #expect(throws: RemoteFileUpload.Failure.tooLarge(byteCount: huge)) {
            try await RemoteFileUpload.upload(Data(repeating: 0, count: huge),
                                               fileExtension: "png", using: service, at: Date())
        }
        #expect(transport.commandsRun.isEmpty)
    }

    @Test func aHostThatCannotReportHomeFailsRatherThanGuessing() async throws {
        // Falling back to "~" or "." here would write the image somewhere the
        // typed absolute path does not point at -- a silent wrong-file bug.
        let (service, transport) = try await makeService()
        transport.defaultCommandResponse = "   "

        await #expect(throws: RemoteFileUpload.Failure.homeUnresolved) {
            try await RemoteFileUpload.upload(Data([1]), fileExtension: "png", using: service, at: Date())
        }
        #expect(transport.writtenFiles.isEmpty)
    }

    @Test func aFailedWriteSurfacesRatherThanReturningAPathToNothing() async throws {
        let (service, transport) = try await makeService()
        transport.defaultCommandResponse = "/home/alice"
        transport.writeFileError = FileTransferError.permissionDenied

        await #expect(throws: RemoteFileUpload.Failure.self) {
            try await RemoteFileUpload.upload(Data([1]), fileExtension: "png", using: service, at: Date())
        }
    }
}

/// The generic transport seam must not pretend an upload happened.
@Suite struct SSHTransportWriteFileDefaultTests {

    private final class ProbeOnlyTransport: SSHTransport, @unchecked Sendable {
        func connect(host: Host, key: SSHKeyMaterial,
                     hostKeyValidator: @escaping @Sendable (String) -> Bool) async throws {}
        func runCommand(_ cmd: String) async throws -> String { "" }
        func openPTY(command: String, cols: Int, rows: Int,
                     onOutput: @escaping @Sendable (Data) -> Void) async throws -> PTYChannel {
            throw SSHTransportError.notConnected
        }
        func disconnect() async {}
    }

    @Test func aTransportWithoutSFTPThrowsInsteadOfFakingSuccess() async {
        await #expect(throws: SSHTransportError.self) {
            try await ProbeOnlyTransport().writeFile(Data([1]), to: "/tmp/x")
        }
    }
}

#if canImport(UIKit)
import UIKit

@Suite struct RemoteFileNormalisationTests {

    private func solidImage() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    @Test func aPickedImageIsReEncodedAsPNGWhateverItArrivedAs() throws {
        // Photos hands back HEIC on a modern iPad, which plenty of tools on a
        // Linux host cannot open. Going through UIImage and back out as PNG is
        // what makes the ".png" in the generated filename honest.
        let jpeg = try #require(solidImage().jpegData(compressionQuality: 0.8))
        let reloaded = try #require(UIImage(data: jpeg))
        let png = try #require(RemoteFileUpload.pngData(from: reloaded))

        // PNG magic number
        #expect(Array(png.prefix(4)) == [0x89, 0x50, 0x4E, 0x47])
    }
}
#endif

/// The end-to-end trip through a live tab: bytes out over SFTP on the tab's own
/// connection, path in through the tab's own PTY.
@Suite @MainActor struct HerdrHostSessionFileSendTests {

    private func makeLiveSession(transport: FakeSSHTransport) async throws -> HerdrHostSession {
        let keyStore = KeyStore(backing: InMemoryKeychain())
        let keyID = try keyStore.generateEd25519(label: "image-upload")
        let session = HerdrHostSession(
            connection: HostConnection(
                host: Host(name: "mac", address: "192.0.2.10",
                           username: "alice", keyID: keyID, defaultWorkdir: "/Users/alice"),
                keyStore: keyStore,
                knownHosts: KnownHostsStore(
                    defaults: UserDefaults(suiteName: "msam.img.\(UUID())")!
                ),
                transport: transport
            ),
            sessionName: nil
        )
        await session.start()
        return session
    }

    @Test func aLiveTabUploadsThenTypesTheAbsolutePath() async throws {
        let transport = FakeSSHTransport()
        transport.defaultCommandResponse = "/Users/alice"
        let session = try await makeLiveSession(transport: transport)
        #expect(session.status == .live)

        let path = try await session.sendFile(Data([0x89, 0x50, 0x4E, 0x47]), fileExtension: "png")

        #expect(transport.writtenFiles[path] != nil)
        let typed = String(decoding: try #require(transport.openedPTYs.last).sent, as: UTF8.self)
        #expect(typed.contains(path))
    }

    @Test func theTypedPathIsNeverSubmitted() async throws {
        // The user still has to say what to DO with the image. A newline here
        // would fire a bare path at the agent as a prompt of its own.
        let transport = FakeSSHTransport()
        transport.defaultCommandResponse = "/Users/alice"
        let session = try await makeLiveSession(transport: transport)

        _ = try await session.sendFile(Data([1, 2, 3]), fileExtension: "png")

        let typed = String(decoding: try #require(transport.openedPTYs.last).sent, as: UTF8.self)
        #expect(!typed.contains("\n"))
        #expect(!typed.contains("\r"))
        #expect(typed.hasSuffix(" "))
    }

    @Test func anOfflineTabRefusesRatherThanDiallingBehindTheUsersBack() async throws {
        let transport = FakeSSHTransport()
        let keyStore = KeyStore(backing: InMemoryKeychain())
        let keyID = try keyStore.generateEd25519(label: "image-upload")
        let session = HerdrHostSession(
            connection: HostConnection(
                host: Host(name: "mac", address: "10.0.0.1",
                           username: "alice", keyID: keyID, defaultWorkdir: "/Users/alice"),
                keyStore: keyStore,
                knownHosts: KnownHostsStore(
                    defaults: UserDefaults(suiteName: "msam.img.\(UUID())")!
                ),
                transport: transport
            ),
            sessionName: nil
        )
        // never started -- status is .idle

        await #expect(throws: RemoteFileUpload.Failure.self) {
            try await session.sendFile(Data([1]), fileExtension: "pdf")
        }
        #expect(transport.writtenFiles.isEmpty)
        #expect(transport.commandsRun.isEmpty)
    }
}

@Suite @MainActor struct FileSendSheetMessageTests {

    @Test func eachFailureGetsAnActionableSentenceNotAnEnumName() {
        // The sheet is the only place these are ever seen, so a raw
        // "uploadFailed(...)" description would be the user's whole diagnosis.
        #expect(FileSendSheet.message(for: RemoteFileUpload.Failure.homeUnresolved)
            .contains("home directory"))
        #expect(FileSendSheet.message(for: RemoteFileUpload.Failure.emptyFile)
            .localizedCaseInsensitiveContains("empty"))
        #expect(FileSendSheet.message(for: RemoteFileUpload.Failure.uploadFailed("permission denied"))
            .contains("permission denied"))
    }

    @Test func anOversizeImageIsReportedInMegabytesNotBytes() {
        // "26214401 bytes" tells the user nothing about whether their photo is
        // unusual; "25.0 MB, limit 25 MB" does.
        let message = FileSendSheet.message(
            for: RemoteFileUpload.Failure.tooLarge(byteCount: 26 * 1_048_576)
        )
        #expect(message.contains("26.0 MB"))
        #expect(message.contains("25 MB"))
    }

    @Test func anUnexpectedErrorStillProducesSomethingReadable() {
        let message = FileSendSheet.message(for: FileTransferError.notConnected)
        #expect(message.localizedCaseInsensitiveContains("upload failed"))
    }
}

/// The extension is the ONE part of the generated filename that comes from user
/// data — a filename chosen in the Files app — and the finished path is typed
/// into a shell prompt.
@Suite struct RemoteFileUploadExtensionTests {

    private var instant: Date { Date(timeIntervalSince1970: 1_787_492_702.118) }

    @Test func anOrdinaryExtensionSurvivesLowercased() {
        #expect(RemoteFileUpload.sanitizedExtension("pdf") == "pdf")
        #expect(RemoteFileUpload.sanitizedExtension("PDF") == "pdf")
        #expect(RemoteFileUpload.sanitizedExtension("PNG") == "png")
    }

    @Test func aFileWithNoExtensionGetsAFallbackRatherThanATrailingDot() {
        // "msam-20260823-134502-118." is a valid but confusing filename, and
        // some tools treat it as having an empty extension.
        #expect(RemoteFileUpload.sanitizedExtension("") == RemoteFileUpload.defaultExtension)
        let name = RemoteFileUpload.filename(at: instant, fileExtension: "")
        #expect(!name.hasSuffix("."))
        #expect(name.hasSuffix(".\(RemoteFileUpload.defaultExtension)"))
    }

    @Test func shellMetacharactersInAnExtensionAreStripped() {
        // A file named `notes.pdf; rm -rf ~` in Files must not put a command
        // separator into a path that gets typed at a prompt.
        #expect(RemoteFileUpload.sanitizedExtension("pdf; rm -rf ~") == "pdfrmrf")
        #expect(RemoteFileUpload.sanitizedExtension("../../etc/passwd") == "etcpasswd")
        #expect(RemoteFileUpload.sanitizedExtension("$(whoami)") == "whoami")
    }

    @Test func anAbsurdlyLongExtensionIsBounded() {
        let long = String(repeating: "a", count: 500)
        #expect(RemoteFileUpload.sanitizedExtension(long).count
            == RemoteFileUpload.maximumExtensionLength)
    }

    @Test func aGeneratedNameIsShellSafeForEVERYExtensionWeAccept() {
        // The property, not an example: whatever a file was called, the name we
        // build out of it needs no quoting.
        let safe = CharacterSet(charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let hostile = ["pdf", "", "  ", "a b", "x';rm -rf /;'", "../..",
                       "$(id)", "`id`", "*", "?", "\\n", "tar.gz", "PNG"]
        for raw in hostile {
            let name = RemoteFileUpload.filename(at: instant, fileExtension: raw)
            #expect(name.unicodeScalars.allSatisfy { safe.contains($0) },
                    "unsafe name \(name) from extension \(raw.debugDescription)")
        }
    }

    @Test func theExtensionReachesTheRemotePath() async throws {
        let host = Host(name: "h", address: "10.0.0.1", port: 22,
                        username: "alice", keyID: "k", defaultWorkdir: "/home/alice")
        let transport = FakeSSHTransport()
        let knownHosts = KnownHostsStore(defaults: UserDefaults(suiteName: "msam.ext.\(UUID())")!)
        let service = SSHService(host: host, transport: transport, knownHosts: knownHosts)
        try await service.connect(key: SSHKeyMaterial(ed25519Seed: Data(repeating: 7, count: 32))) { _, _ in true }
        transport.defaultCommandResponse = "/home/alice"

        let path = try await RemoteFileUpload.upload(
            Data("%PDF-1.7".utf8), fileExtension: "pdf", using: service, at: Date()
        )

        // Tools dispatch on the extension, so a PDF must not land as a .png.
        #expect(path.hasSuffix(".pdf"))
    }
}
