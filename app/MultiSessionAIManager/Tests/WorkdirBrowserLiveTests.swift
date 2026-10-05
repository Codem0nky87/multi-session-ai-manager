import Foundation
import Testing
@testable import MultiSessionAIManager

/// Opt-in, read-only checks against a temporary loopback SSH server.
/// The fixture manifest names its disposable key and directory tree; no saved
/// host, user SSH configuration, or production credentials are used.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MSAM_SSH_IT"] == "1"))
@MainActor
struct WorkdirBrowserLiveTests {
    private struct Fixture: Decodable {
        let root: String
        let port: Int
        let username: String
    }

    private func fixture() throws -> (SSHDirectoryBrowser, String) {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            URL(fileURLWithPath: ProcessInfo.processInfo.environment["MSAM_SSH_FIXTURE"]!)))
        let pem = try String(contentsOfFile: fixture.root + "/client_key", encoding: .utf8)
        let key = SSHKeyMaterial(ed25519Seed: try KeyStore.parseEd25519Seed(pem: pem))
        let host = Host(name: "SSH fixture", address: "127.0.0.1", port: fixture.port,
                        username: fixture.username, keyID: "fixture", defaultWorkdir: "")
        let transfer = SSHDirectoryBrowser(host: host, key: key, knownHosts: KnownHostsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!))
        return (transfer, fixture.root + "/folders")
    }

    @Test func listsAndNavigatesRealRemoteFolders() async throws {
        let (transfer, path) = try fixture()
        let model = FileBrowserModel(transfer: transfer, root: "/")
        await model.load()
        #expect(model.errorMessage == nil)
        #expect(model.visibleEntries.contains { $0.isDirectory })
        await model.navigate(to: path)
        #expect(model.errorMessage == nil)
        let projects = try #require(model.visibleEntries.first { $0.name == "Projects" })
        #expect(projects.isDirectory)
        await model.open(projects)
        #expect(model.errorMessage == nil)
        #expect(model.visibleEntries.contains { $0.name == "nested folder" && $0.isDirectory })
        await model.goUp()
        #expect(model.currentPath == path)
        #expect(model.visibleEntries.contains { $0.name == "README.txt" && !$0.isDirectory })
        #expect(!model.visibleEntries.contains { $0.name == ".hidden" })
        model.showHidden = true
        #expect(model.visibleEntries.contains { $0.name == ".hidden" && $0.isDirectory })
        await transfer.disconnect()
    }

    @Test func linkedRemoteFoldersRemainNavigable() async throws {
        let (transfer, path) = try fixture()
        let entries = try await transfer.listDirectory(path)
        let link = try #require(entries.first { $0.name == "linked projects" })
        #expect(link.isDirectory, "A directory symlink must be selectable in the folder browser")
        let model = FileBrowserModel(transfer: transfer, root: "/")
        await model.open(link)
        #expect(model.errorMessage == nil)
        #expect(model.visibleEntries.contains { $0.name == "nested folder" && $0.isDirectory })
        #expect(entries.contains { $0.name == "linked file" && !$0.isDirectory })
        #expect(entries.contains { $0.name == "broken link" && !$0.isDirectory })
        await transfer.disconnect()
    }

    @Test func handlesShellCharactersMissingFoldersAndPermissions() async throws {
        let (transfer, path) = try fixture()
        let listing = try await transfer.listDirectory(path)
        let unusual = try #require(listing.first { $0.name == "quote's $dollar\nline" })
        let child = try await transfer.directoryListing(unusual.path)
        #expect(child.path == unusual.path)
        #expect(child.entries.isEmpty)
        await #expect(throws: FileTransferError.notFound) { try await transfer.directoryListing(path + "/missing") }
        await #expect(throws: FileTransferError.permissionDenied) { try await transfer.directoryListing(path + "/locked") }
        let home = try await transfer.directoryListing("~")
        #expect(home.path.hasPrefix("/"))
        let sameHome = try await transfer.directoryListing("~/.")
        #expect(sameHome.path == home.path)
        await transfer.disconnect()
    }
}
