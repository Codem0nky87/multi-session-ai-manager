import Foundation
import Testing
@testable import MultiSessionAIManager

/// Herdr's marketplace = GitHub topic `herdr-plugin` + a valid manifest. Search
/// can only do the topic half, so these pin how the app handles the gap.
@Suite struct PluginCatalogueQueryTests {

    @Test func theTopicIsAlwaysPartOfTheQuery() throws {
        // Without it this searches ALL of GitHub for the user's words.
        // Asserted against the DECODED query item: `:` is legal unencoded in a
        // query value, so matching on the raw string is a test of URLComponents'
        // escaping policy rather than of this code.
        let url = try #require(GitHubPluginCatalogue.searchURL(query: ""))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "q" }?.value)
        #expect(query == "topic:herdr-plugin")
    }

    @Test func userTermsNarrowTheTopicRatherThanReplacingIt() throws {
        let url = try #require(GitHubPluginCatalogue.searchURL(query: "file viewer"))
        let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "q" }?.value)
        #expect(query.contains("topic:herdr-plugin"))
        #expect(query.contains("file viewer"))
    }

    @Test func theManifestProbeTargetsTheDocumentedFile() throws {
        let url = try #require(GitHubPluginCatalogue.manifestURL(fullName: "owner/repo"))
        #expect(url.absoluteString == "https://api.github.com/repos/owner/repo/contents/herdr-plugin.toml")
    }
}

@Suite struct PluginCatalogueParsingTests {

    @Test func repositoriesAreReadIntoCatalogueEntries() throws {
        let json = """
        {"total_count":2,"items":[
          {"full_name":"smarzban/herdr-file-viewer","description":"A file viewer.",
           "stargazers_count":42,"html_url":"https://github.com/smarzban/herdr-file-viewer"},
          {"full_name":"a/b","description":null,"stargazers_count":0,"html_url":"https://github.com/a/b"}
        ]}
        """
        let plugins = try GitHubPluginCatalogue.parseSearch(Data(json.utf8))

        #expect(plugins.count == 2)
        #expect(plugins[0].fullName == "smarzban/herdr-file-viewer")
        #expect(plugins[0].stars == 42)
        #expect(plugins[0].owner == "smarzban")
        // A repo with no description must not drop out of the list.
        #expect(plugins[1].description.isEmpty)
    }

    @Test func aRateLimitReplyIsNOTReadAsAnEmptyCatalogue() throws {
        // GitHub reports rate limiting in the BODY as well as the status. Reading
        // it as "no plugins found" would tell the user the catalogue is empty
        // when it is merely temporarily closed.
        let json = """
        {"message":"API rate limit exceeded for 1.2.3.4.","documentation_url":"https://docs.github.com/"}
        """
        #expect(throws: PluginCatalogueError.rateLimited) {
            try GitHubPluginCatalogue.parseSearch(Data(json.utf8))
        }
    }

    @Test func anotherAPIErrorSurfacesItsMessage() throws {
        let json = #"{"message":"Validation Failed"}"#
        #expect(throws: PluginCatalogueError.unavailable("Validation Failed")) {
            try GitHubPluginCatalogue.parseSearch(Data(json.utf8))
        }
    }

    @Test func garbageThrowsRatherThanReturningNothing() {
        #expect(throws: PluginCatalogueError.self) {
            try GitHubPluginCatalogue.parseSearch(Data("<html>".utf8))
        }
    }

    @Test func aCatalogueEntryIsDirectlyInstallable() throws {
        // `full_name` is what `herdr plugin install` takes for a plugin kept at
        // the top of its repository. One kept in a folder adds the folder, which
        // is found when the row is picked (PluginRepositoryListingTests).
        let json = #"{"items":[{"full_name":"smarzban/herdr-file-viewer","stargazers_count":1}]}"#
        let plugin = try #require(try GitHubPluginCatalogue.parseSearch(Data(json.utf8)).first)
        #expect(HerdrPluginManagement.isValidSource(plugin.fullName))
    }
}

/// A repository does not have to keep its plugin at the top. The app looked only
/// there, and told the user that zenbu-labs/terminal-browser, the most starred
/// plugin in the list, "has no herdr-plugin.toml": its manifest is in `herdr-plugin/`.
@Suite struct PluginRepositoryListingTests {
    /// GitHub's answer to a recursive tree request, cut to what is read from it.
    private func listing(_ files: [String], folders: [String] = [], truncated: Bool = false) throws -> Data {
        let entries = files.map { ["path": $0, "type": "blob"] } + folders.map { ["path": $0, "type": "tree"] }
        return try JSONSerialization.data(withJSONObject: ["sha": "abc", "tree": entries, "truncated": truncated])
    }

    private func sources(_ fullName: String, _ files: [String], folders: [String] = []) throws -> [String] {
        try GitHubPluginCatalogue.pluginSources(fullName: fullName, tree: listing(files, folders: folders)).sources
    }

    @Test func aPluginInAFolderIsNamedByTheSourceThatInstallsIt() throws {
        let found = try sources("zenbu-labs/terminal-browser",
                                ["README.md", "herdr-plugin/README.md", "herdr-plugin/herdr-plugin.toml",
                                 "herdr-plugin/open-split.sh", "pixel/engine/crates/pixel-kitty/src/herdr.rs"],
                                folders: ["herdr-plugin", "pixel"])
        #expect(found == ["zenbu-labs/terminal-browser/herdr-plugin"])
    }

    @Test func pluginsAreFoundAnyNumberOfFoldersDownTheShallowestFirst() throws {
        let found = try sources("owner/kit", ["plugins/herdr/layout/herdr-plugin.toml", "zeta/herdr-plugin.toml",
                                              "plugins/notify/herdr-plugin.toml", "alpha/herdr-plugin.toml"])
        #expect(found == ["owner/kit/alpha", "owner/kit/zeta", "owner/kit/plugins/notify", "owner/kit/plugins/herdr/layout"])
    }

    @Test func aManifestAtTheTopIsTheRepositoryItself() throws {
        #expect(try sources("owner/plugin", ["herdr-plugin.toml", "links/herdr-plugin.toml"])
                == ["owner/plugin", "owner/plugin/links"])
    }

    @Test func onlyAFileNamedExactlyLikeTheManifestCounts() throws {
        let found = try sources("owner/repo",
                                ["docs/not-herdr-plugin.toml", "old/herdr-plugin.toml.bak", "x/herdr-plugin.toml/notes.md"],
                                folders: ["herdr-plugin.toml", "x/herdr-plugin.toml"])
        #expect(found.isEmpty)
    }

    @Test func aFolderTheInstallerWouldRefuseIsNotOffered() throws {
        // The source goes into a command line on the user's host.
        let found = try sources("owner/repo", ["my plugins/herdr-plugin.toml", "-rf/herdr-plugin.toml",
                                               "a;id/herdr-plugin.toml", "fine/herdr-plugin.toml"])
        #expect(found == ["owner/repo/fine"])
    }

    @Test func aListingThatGitHubCutShortSaysSo() throws {
        let cut = try GitHubPluginCatalogue.pluginSources(fullName: "owner/huge", tree: listing(["a.txt"], truncated: true))
        #expect(cut.sources.isEmpty)
        #expect(!cut.isComplete)
        #expect(try GitHubPluginCatalogue.pluginSources(fullName: "owner/small", tree: listing(["a.txt"])).isComplete)
    }

    @Test func somethingThatIsNotAListingIsAnErrorAndNotAnEmptyRepository() {
        #expect(throws: PluginCatalogueError.self) {
            _ = try GitHubPluginCatalogue.pluginSources(fullName: "owner/repo", tree: Data(#"{"message":"Not Found"}"#.utf8))
        }
    }

    @Test func theWholeDefaultBranchIsListedInOneRequest() {
        #expect(GitHubPluginCatalogue.treeURL(fullName: "owner/repo")?.absoluteString
                == "https://api.github.com/repos/owner/repo/git/trees/HEAD?recursive=1")
    }
}

/// The requests the catalogue makes for one repository, against a stand-in for GitHub.
@Suite(.serialized) struct GitHubPluginCatalogueRequestTests {
    private static let manifest = "https://api.github.com/repos/owner/repo/contents/herdr-plugin.toml"
    private static let tree = "https://api.github.com/repos/owner/repo/git/trees/HEAD?recursive=1"

    private func catalogue(_ answers: [String: (status: Int, body: String)]) -> GitHubPluginCatalogue {
        StandInGitHub.state.reset(answers)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StandInGitHub.self]
        return GitHubPluginCatalogue(session: URLSession(configuration: configuration))
    }

    private func listing(_ files: [String], truncated: Bool = false) -> String {
        let entries = files.map { #"{"path":"\#($0)","type":"blob"}"# }.joined(separator: ",")
        return #"{"tree":[\#(entries)],"truncated":\#(truncated)}"#
    }

    @Test func aManifestAtTheTopCostsOneSmallRequest() async throws {
        let catalogue = catalogue([Self.manifest: (200, "{}")])

        #expect(try await catalogue.pluginSources(in: "owner/repo") == ["owner/repo"])
        #expect(StandInGitHub.state.requested == [Self.manifest])
    }

    @Test func aRepositoryWithoutOneAtTheTopIsLookedThroughForIt() async throws {
        let catalogue = catalogue([Self.manifest: (404, "{}"),
                                   Self.tree: (200, listing(["README.md", "herdr-plugin/herdr-plugin.toml"]))])

        #expect(try await catalogue.pluginSources(in: "owner/repo") == ["owner/repo/herdr-plugin"])
        #expect(StandInGitHub.state.requested == [Self.manifest, Self.tree])
    }

    @Test func aRepositoryWithNoManifestAnywhereHoldsNoPlugin() async throws {
        let catalogue = catalogue([Self.manifest: (404, "{}"), Self.tree: (200, listing(["README.md", "src/main.rs"]))])

        #expect(try await catalogue.pluginSources(in: "owner/repo").isEmpty)
    }

    @Test(arguments: [403, 429])
    func aRateLimitOnTheListingIsReportedAsOne(status: Int) async {
        let catalogue = catalogue([Self.manifest: (404, "{}"), Self.tree: (status, "{}")])

        await #expect(throws: PluginCatalogueError.rateLimited) {
            _ = try await catalogue.pluginSources(in: "owner/repo")
        }
    }

    @Test func aRateLimitOnTheFirstRequestIsReportedWithoutASecond() async {
        let catalogue = catalogue([Self.manifest: (403, "{}")])

        await #expect(throws: PluginCatalogueError.rateLimited) {
            _ = try await catalogue.pluginSources(in: "owner/repo")
        }
        #expect(StandInGitHub.state.requested == [Self.manifest])
    }

    @Test func nothingFoundInAListingThatWasCutShortIsNotReadAsNoPlugin() async {
        let catalogue = catalogue([Self.manifest: (404, "{}"), Self.tree: (200, listing(["a.txt"], truncated: true))])

        await #expect(throws: PluginCatalogueError.self) {
            _ = try await catalogue.pluginSources(in: "owner/repo")
        }
    }

    @Test func aPluginFoundInAListingThatWasCutShortIsStillOffered() async throws {
        let catalogue = catalogue([Self.manifest: (404, "{}"),
                                   Self.tree: (200, listing(["plugin/herdr-plugin.toml"], truncated: true))])

        #expect(try await catalogue.pluginSources(in: "owner/repo") == ["owner/repo/plugin"])
    }

    // MARK: - Does the plugin draw pictures?

    private static let raw = "https://raw.githubusercontent.com/zenbu-labs/terminal-browser/HEAD/"

    @Test func aPluginsOwnWordsAreReadFromItsManifestItsReadmeAndItsRepositorysReadme() async {
        // terminal-browser says it only in the README of its repository: neither
        // its manifest nor the README in the plugin's own folder mentions pictures.
        let catalogue = catalogue([
            Self.raw + "herdr-plugin/herdr-plugin.toml": (200, #"id = "zenbu-labs.terminal-browser""#),
            Self.raw + "herdr-plugin/README.md": (200, "A real browser that runs inside your terminal"),
            Self.raw + "README.md": (200, "Terminals that support the Kitty Graphics protocol allow a program to display pixels."),
        ])

        let need = await catalogue.pictureNeed(of: "zenbu-labs/terminal-browser/herdr-plugin")

        #expect(need == PluginPictureNeed(phrase: "kitty graphics", file: "README.md"))
        #expect(StandInGitHub.state.requested == [
            Self.raw + "herdr-plugin/herdr-plugin.toml", Self.raw + "herdr-plugin/README.md", Self.raw + "README.md",
        ])
    }

    @Test func theFileThatSaysSoIsNamedAndNoFurtherOneIsFetched() async {
        let catalogue = catalogue([
            "https://raw.githubusercontent.com/nikok6/herdr-pet/HEAD/herdr-plugin.toml":
                (200, "# host terminal that speaks the kitty graphics protocol (Ghostty, kitty, WezTerm)."),
        ])

        let need = await catalogue.pictureNeed(of: "nikok6/herdr-pet")

        #expect(need == PluginPictureNeed(phrase: "kitty graphics", file: "herdr-plugin.toml"))
        #expect(StandInGitHub.state.requested.count == 1)
    }

    @Test func aPluginThatSaysNothingAboutPicturesNeedsNone() async {
        let base = "https://raw.githubusercontent.com/smarzban/herdr-file-viewer/HEAD/"
        let catalogue = catalogue([
            base + "herdr-plugin.toml": (200, #"id = "herdr-file-viewer""#),
            base + "README.md": (200, "A git-aware, read-only file viewer."),
        ])

        #expect(await catalogue.pictureNeed(of: "smarzban/herdr-file-viewer") == nil)
        // The repository's README is the plugin's own when the plugin is at the top.
        #expect(StandInGitHub.state.requested == [base + "herdr-plugin.toml", base + "README.md"])
    }

    @Test func filesThatCannotBeReadAreNoReasonToRefuseAPlugin() async {
        // A private repository, or GitHub unreachable from this device.
        #expect(await catalogue([:]).pictureNeed(of: "owner/private-plugin") == nil)
    }
}

/// Answers the catalogue's requests from a table instead of the network.
private final class StandInGitHub: URLProtocol, @unchecked Sendable {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: (status: Int, body: String)] = [:]
        private var asked: [String] = []

        func reset(_ answers: [String: (status: Int, body: String)]) {
            lock.withLock { self.answers = answers; asked = [] }
        }

        func answer(to url: String) -> (status: Int, body: String) {
            lock.withLock {
                asked.append(url)
                return answers[url] ?? (404, "{}")
            }
        }

        var requested: [String] { lock.withLock { asked } }
    }

    static let state = State()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let answer = Self.state.answer(to: url.absoluteString)
        let response = HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(answer.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
