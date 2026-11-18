import Foundation

/// One repository from the plugin catalogue.
struct CataloguePlugin: Identifiable, Equatable, Sendable {
    /// `owner/repo` — also exactly what `herdr plugin install` takes.
    let fullName: String
    let description: String
    let stars: Int
    let htmlURL: URL?

    var id: String { fullName }
    var owner: String { String(fullName.split(separator: "/").first ?? "") }
    var repositoryName: String { String(fullName.split(separator: "/").last ?? "") }
}

/// Browses community Herdr plugins.
///
/// Herdr's marketplace indexes GitHub repositories carrying the topic
/// `herdr-plugin` AND a valid `herdr-plugin.toml`. GitHub's search API can do
/// the topic half but not the manifest half, so a raw topic search returns a
/// lot of repositories that merely wear the tag -- at the time of writing the
/// highest-starred results are terminal apps that are not Herdr plugins at all.
///
/// So the manifest is looked for LAZILY, when the user picks a row, rather than
/// for every result: unauthenticated GitHub search allows about 10 requests a
/// minute, and verifying a page of results would spend that budget in one go.
///
/// The manifest need not be at the top of the repository. Herdr installs from
/// `owner/repo[/folder...]`, and its marketplace lists every manifest in a
/// repository, each as its own plugin. About one listed repository in sixteen
/// keeps its plugin in a folder, the most popular ones among them.
protocol PluginCatalogueFetching: Sendable {
    func search(_ query: String) async throws -> [CataloguePlugin]
    /// The plugins in this repository, each as the source `herdr plugin install`
    /// takes: `owner/repo` for a manifest at the top, `owner/repo/folder` for one
    /// in a folder. Empty when the repository holds no manifest at all.
    func pluginSources(in fullName: String) async throws -> [String]
    /// Whether the plugin at this source draws pictures in the terminal, going
    /// by its manifest and READMEs. Nil when they do not say so, and when they
    /// cannot be read: not knowing is no reason to refuse a plugin.
    func pictureNeed(of source: String) async -> PluginPictureNeed?
}

enum PluginCatalogueError: Error, Equatable {
    case rateLimited
    case unavailable(String)
}

/// The GitHub-backed catalogue.
struct GitHubPluginCatalogue: PluginCatalogueFetching {
    static let topic = "herdr-plugin"
    static let manifestFileName = "herdr-plugin.toml"
    static let resultLimit = 30

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    static func searchURL(query: String, limit: Int = resultLimit) -> URL? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // The topic is always part of the query -- searching all of GitHub for
        // the user's words would return anything at all.
        let terms = trimmed.isEmpty ? "topic:\(topic)" : "topic:\(topic) \(trimmed)"
        var components = URLComponents(string: "https://api.github.com/search/repositories")
        components?.queryItems = [
            URLQueryItem(name: "q", value: terms),
            URLQueryItem(name: "sort", value: "stars"),
            URLQueryItem(name: "order", value: "desc"),
            URLQueryItem(name: "per_page", value: String(limit))
        ]
        return components?.url
    }

    static func manifestURL(fullName: String) -> URL? {
        URL(string: "https://api.github.com/repos/\(fullName)/contents/\(manifestFileName)")
    }

    func search(_ query: String) async throws -> [CataloguePlugin] {
        guard let url = Self.searchURL(query: query) else {
            throw PluginCatalogueError.unavailable("could not build the search request")
        }
        let (data, response) = try await fetch(url)
        if let http = response as? HTTPURLResponse, http.statusCode == 403 || http.statusCode == 429 {
            throw PluginCatalogueError.rateLimited
        }
        return try Self.parseSearch(data)
    }

    /// The whole file listing of the default branch, in one request.
    static func treeURL(fullName: String) -> URL? {
        URL(string: "https://api.github.com/repos/\(fullName)/git/trees/HEAD?recursive=1")
    }

    func pluginSources(in fullName: String) async throws -> [String] {
        guard let manifest = Self.manifestURL(fullName: fullName),
              let tree = Self.treeURL(fullName: fullName) else { return [] }
        // Most plugins keep their manifest at the top, and one small request
        // settles those. Only a repository without one is looked through.
        if try status(of: await fetch(manifest).1) == 200 { return [fullName] }
        let (listing, response) = try await fetch(tree)
        guard try status(of: response) == 200 else { return [] }
        let found = try Self.pluginSources(fullName: fullName, tree: listing)
        if found.sources.isEmpty, !found.isComplete {
            // GitHub cuts a very large listing short. Nothing found in part of a
            // repository is not the same as nothing in it.
            throw PluginCatalogueError.unavailable("the repository is too large to look through for a plugin")
        }
        return found.sources
    }

    /// Where a plugin describes itself: its manifest, the README beside it, and
    /// the README of its repository. Read as plain files, which costs nothing
    /// against GitHub's hourly limit for the API.
    static func descriptionFiles(of source: String) -> [(file: String, url: URL)] {
        let parts = source.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return [] }
        let folder = parts.dropFirst(2).joined(separator: "/")
        let inFolder = folder.isEmpty ? "" : folder + "/"
        var files = [inFolder + manifestFileName, inFolder + "README.md"]
        if !folder.isEmpty { files.append("README.md") }
        return files.compactMap { file in
            URL(string: "https://raw.githubusercontent.com/\(parts[0])/\(parts[1])/HEAD/\(file)").map { (file, $0) }
        }
    }

    func pictureNeed(of source: String) async -> PluginPictureNeed? {
        for (file, url) in Self.descriptionFiles(of: source) {
            guard let (data, response) = try? await fetch(url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
            // A README is a few kilobytes; nobody needs megabytes of one read.
            let text = String(decoding: data.prefix(400_000), as: UTF8.self)
            if let phrase = PluginPictureRequirement.phrase(in: text) {
                return PluginPictureNeed(phrase: phrase, file: file)
            }
        }
        return nil
    }

    private func status(of response: URLResponse) throws -> Int {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 403 || status == 429 { throw PluginCatalogueError.rateLimited }
        return status
    }

    /// Every plugin manifest in a repository's file listing, as install sources,
    /// the shallowest first. `isComplete` is false when GitHub cut the listing short.
    static func pluginSources(fullName: String, tree data: Data) throws -> (sources: [String], isComplete: Bool) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["tree"] as? [[String: Any]] else {
            throw PluginCatalogueError.unavailable("GitHub returned an unreadable file listing")
        }
        var sources: [String] = []
        for entry in entries {
            guard entry["type"] as? String == "blob", let path = entry["path"] as? String else { continue }
            var folders = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard folders.popLast() == manifestFileName else { continue }
            let source = ([fullName] + folders).joined(separator: "/")
            // A folder the installer refuses (a space in its name, say) cannot be
            // installed from here, so it is not offered.
            guard HerdrPluginManagement.isValidSource(source) else { continue }
            sources.append(source)
        }
        func depth(_ source: String) -> Int { source.split(separator: "/").count }
        sources.sort { (depth($0), $0) < (depth($1), $1) }
        return (sources, !(root["truncated"] as? Bool ?? false))
    }

    private func fetch(_ url: URL) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        do {
            return try await session.data(for: request)
        } catch {
            throw PluginCatalogueError.unavailable(error.localizedDescription)
        }
    }

    static func parseSearch(_ data: Data) throws -> [CataloguePlugin] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PluginCatalogueError.unavailable("the catalogue returned something unreadable")
        }
        guard let items = root["items"] as? [[String: Any]] else {
            // GitHub reports rate limiting in the BODY as well as the status, and
            // a caller that missed the status must not read that as "no results".
            if let message = root["message"] as? String {
                if message.lowercased().contains("rate limit") {
                    throw PluginCatalogueError.rateLimited
                }
                throw PluginCatalogueError.unavailable(message)
            }
            throw PluginCatalogueError.unavailable("the catalogue returned no results field")
        }
        return items.compactMap { item in
            guard let fullName = item["full_name"] as? String else { return nil }
            return CataloguePlugin(
                fullName: fullName,
                description: item["description"] as? String ?? "",
                stars: item["stargazers_count"] as? Int ?? 0,
                htmlURL: (item["html_url"] as? String).flatMap(URL.init(string:))
            )
        }
    }
}
