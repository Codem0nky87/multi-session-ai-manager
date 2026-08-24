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
/// So the manifest is checked LAZILY, when the user picks a row, rather than
/// for every result: unauthenticated GitHub search allows about 10 requests a
/// minute, and verifying a page of results would spend that budget in one go.
protocol PluginCatalogueFetching: Sendable {
    func search(_ query: String) async throws -> [CataloguePlugin]
    /// Whether this repository actually carries a plugin manifest.
    func hasManifest(_ fullName: String) async throws -> Bool
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

    func hasManifest(_ fullName: String) async throws -> Bool {
        guard let url = Self.manifestURL(fullName: fullName) else { return false }
        let (_, response) = try await fetch(url)
        guard let http = response as? HTTPURLResponse else { return false }
        if http.statusCode == 403 || http.statusCode == 429 {
            throw PluginCatalogueError.rateLimited
        }
        return http.statusCode == 200
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
