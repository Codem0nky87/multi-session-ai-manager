import Foundation
import Testing
@testable import MultiSessionAIManager

@Suite @MainActor
struct SSHDirectoryBrowserTests {
    private func response(_ fields: [String]) -> Data {
        Data(("login banner\n\0MSAM_DIRECTORY_V1\0" + fields.joined(separator: "\0") + "\0").utf8)
    }

    @Test func parsesNamesWithoutSplittingSpacesQuotesOrNewlines() throws {
        let listing = try SSHDirectoryBrowser.parse(response([
            "ok", "/home/user", "d", "project's folder\nnext line", "f", ".hidden", "end"
        ]))
        #expect(listing.path == "/home/user")
        #expect(listing.entries.map(\.name) == ["project's folder\nnext line", ".hidden"])
        #expect(listing.entries.first?.path == "/home/user/project's folder\nnext line")
        #expect(listing.entries.first?.isDirectory == true)
    }

    @Test func rejectsTruncatedMalformedAndErrorListings() {
        for fields in [["ok", "/home", "d", "project"],
                       ["ok", "/home", "d", "../escape", "end"],
                       ["ok", "relative", "end"],
                       ["denied", "", "end"], ["missing", "", "end"]] {
            #expect(throws: FileTransferError.self) { try SSHDirectoryBrowser.parse(response(fields)) }
        }
    }

    @Test func usesBoundedSSHExecAndResolvesHome() async throws {
        let transport = FakeSSHTransport()
        transport.structuredCommandResults = [
            .success(.init(exitStatus: 0, stdout: Data("%OS%".utf8), stderr: Data())),
            .success(.init(exitStatus: 0, stdout: response(["ok", "/home/user", "d", "Projects", "end"]), stderr: Data()))
        ]
        let browser = makeBrowser(transport)
        let model = FileBrowserModel(transfer: browser, root: "/")
        await model.navigate(to: "~")
        #expect(model.errorMessage == nil)
        #expect(model.currentPath == "/home/user")
        #expect(model.entries.first?.path == "/home/user/Projects")
        let command = try #require(transport.structuredCommandsRun.last)
        #expect(command.command.hasPrefix("/bin/sh -c "))
        #expect(command.timeout == .seconds(15))
        #expect(command.outputLimit == 1_048_576)
        await browser.disconnect()
        #expect(!transport.isConnected)
    }

    @Test(arguments: ["Windows_NT $env:OS", "%OS%\nWindows_NT\n"])
    func windowsListingUsesEncodedPowerShellAndDrivePaths(probe: String) async throws {
        let transport = FakeSSHTransport()
        transport.structuredCommandResults = [
            .success(.init(exitStatus: 0, stdout: Data(probe.utf8), stderr: Data())),
            .success(.init(exitStatus: 0, stdout: response(["ok", "/", "d", "C:", "end"]), stderr: Data()))
        ]
        let browser = makeBrowser(transport)
        let listing = try await browser.directoryListing("/")
        #expect(listing.entries.first?.path == "C:/")
        #expect(transport.structuredCommandsRun.first?.command == "echo %OS% $env:OS")
        let command = try #require(transport.structuredCommandsRun.last)
        #expect(command.command.hasPrefix("powershell.exe -NoProfile -NonInteractive -EncodedCommand "))
        await browser.disconnect()
    }

    @Test func changedHostKeyIsRejectedBeforeListing() async {
        let transport = FakeSSHTransport()
        let store = KnownHostsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        store.pin(host: "fixture", fingerprint: "previous-key")
        let browser = makeBrowser(transport, knownHosts: store)
        await #expect(throws: SSHTransportError.self) { try await browser.directoryListing("/") }
        #expect(transport.structuredCommandsRun.isEmpty)
        await browser.disconnect()
    }

    private func makeBrowser(_ transport: FakeSSHTransport, knownHosts: KnownHostsStore? = nil) -> SSHDirectoryBrowser {
        SSHDirectoryBrowser(
            host: Host(name: "Fixture", address: "fixture", port: 22, username: "user", keyID: "fixture", defaultWorkdir: ""),
            key: SSHKeyMaterial(ed25519Seed: Data(repeating: 7, count: 32)),
            knownHosts: knownHosts ?? KnownHostsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!),
            transport: transport
        )
    }
}
