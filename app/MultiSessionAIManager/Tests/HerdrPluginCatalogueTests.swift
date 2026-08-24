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
        // `full_name` is exactly what `herdr plugin install` takes, which is why
        // no conversion step exists between browsing and installing.
        let json = #"{"items":[{"full_name":"smarzban/herdr-file-viewer","stargazers_count":1}]}"#
        let plugin = try #require(try GitHubPluginCatalogue.parseSearch(Data(json.utf8)).first)
        #expect(HerdrPluginManagement.isValidSource(plugin.fullName))
    }
}
