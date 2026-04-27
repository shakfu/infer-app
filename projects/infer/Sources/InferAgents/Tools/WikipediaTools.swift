import Foundation

/// Wikipedia search via the MediaWiki Action API
/// (`/w/api.php?action=query&list=search`). Returns matching article
/// titles with snippets and word counts; the URL is constructed
/// client-side because the API doesn't return canonical wiki URLs.
///
/// Argument schema:
/// ```
/// {
///   "query": "ada lovelace",
///   "limit": 5,         // optional, default 5, max 10
///   "lang":  "en"       // optional, default "en" (Wikipedia subdomain)
/// }
/// ```
///
/// Result is a JSON array of `{title, url, snippet, wordcount}`. Use
/// `wikipedia.article` (companion tool) to fetch the full text of a
/// specific result. Use `web.search` instead for non-encyclopedic
/// queries (current events, public docs, library API references).
public struct WikipediaSearchTool: BuiltinTool, @unchecked Sendable {
    public let name: ToolName = "wikipedia.search"

    public static let defaultLimit = 5
    public static let maxLimit = 10
    public static let defaultLang = "en"
    public static let timeoutSeconds: TimeInterval = 30

    public struct SearchResult: Codable, Equatable, Sendable {
        public let title: String
        public let url: String
        public let snippet: String
        public let wordcount: Int
    }

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
                Search Wikipedia article titles + bodies. Arguments: \
                {"query": "<terms>", "limit": \(Self.defaultLimit), "lang": "\(Self.defaultLang)"}. \
                `limit` is optional (default \(Self.defaultLimit), max \(Self.maxLimit)); \
                `lang` is the Wikipedia language subdomain (en, fr, de, etc.; default \(Self.defaultLang)). \
                Returns a JSON array of {title, url, snippet, wordcount} ordered by relevance. \
                Prefer this over `web.search` for encyclopedic / definitional / biographical / \
                historical questions. Pair with `wikipedia.article` to read the full text of a hit.
                """
        )
    }

    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    private struct Args: Decodable {
        let query: String
        let limit: Int?
        let lang: String?
    }

    private struct APIResponse: Decodable {
        let query: QueryBlock?
    }
    private struct QueryBlock: Decodable {
        let search: [APISearchHit]
    }
    private struct APISearchHit: Decodable {
        let title: String
        let snippet: String
        let wordcount: Int
        let pageid: Int
    }

    public func invoke(arguments: String) async throws -> ToolResult {
        guard let data = arguments.data(using: .utf8) else {
            return ToolResult(output: "", error: "arguments not UTF-8")
        }
        let parsed: Args
        do {
            parsed = try JSONDecoder().decode(Args.self, from: data)
        } catch {
            return ToolResult(output: "", error: "could not parse arguments: \(error.localizedDescription)")
        }
        let query = parsed.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return ToolResult(output: "", error: "query is empty")
        }
        let limit = max(1, min(Self.maxLimit, parsed.limit ?? Self.defaultLimit))
        let lang = WikipediaCommon.normalisedLang(parsed.lang)

        var components = URLComponents(string: "https://\(lang).wikipedia.org/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "list", value: "search"),
            URLQueryItem(name: "srsearch", value: query),
            URLQueryItem(name: "srlimit", value: String(limit)),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
            URLQueryItem(name: "origin", value: "*"),
        ]
        guard let url = components.url else {
            return ToolResult(output: "", error: "could not construct Wikipedia API URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeoutSeconds
        request.setValue("Infer/agents (Wikipedia tool)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: Data
        let response: URLResponse
        do {
            (body, response) = try await session.data(for: request)
        } catch {
            return ToolResult(output: "", error: "search failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            return ToolResult(output: "", error: "search failed: HTTP \(code)")
        }
        let decoded: APIResponse
        do {
            decoded = try JSONDecoder().decode(APIResponse.self, from: body)
        } catch {
            return ToolResult(output: "", error: "could not parse Wikipedia response: \(error.localizedDescription)")
        }
        let hits = decoded.query?.search ?? []
        if hits.isEmpty {
            return ToolResult(output: "[]")
        }
        let results = hits.map { hit in
            SearchResult(
                title: hit.title,
                url: WikipediaCommon.articleURL(title: hit.title, lang: lang),
                snippet: decodeHTMLEntities(stripHTMLTags(hit.snippet))
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                wordcount: hit.wordcount
            )
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let payload = try encoder.encode(results)
            return ToolResult(output: String(decoding: payload, as: UTF8.self))
        } catch {
            return ToolResult(output: "", error: "could not encode results: \(error.localizedDescription)")
        }
    }
}

/// Fetch the plain-text body of a specific Wikipedia article via the
/// MediaWiki Action API's `extracts` prop. Unlike fetching the article
/// HTML through `http.fetch`, the `extracts` endpoint strips chrome
/// (sidebar, infobox, navigation, edit links, citation superscripts,
/// references) and returns just the prose — much cleaner input for
/// the model to ground answers on.
///
/// Argument schema:
/// ```
/// {
///   "title": "Ada Lovelace",
///   "lead":  false,         // optional, default false → full article;
///                           // true → just the lead paragraph (~500 chars)
///   "lang":  "en"           // optional, default "en"
/// }
/// ```
///
/// Returns the article text. Output capped at `maxBytes` with a
/// truncation marker; if hit, the model can re-call with `lead: true`
/// to get just the intro. Missing articles return an explicit error so
/// the model can recover (suggest a `wikipedia.search` follow-up).
public struct WikipediaArticleTool: BuiltinTool, @unchecked Sendable {
    public let name: ToolName = "wikipedia.article"

    public static let maxBytes = 256 * 1024
    public static let defaultLang = "en"
    public static let timeoutSeconds: TimeInterval = 30

    public var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
                Fetch the plain-text body of a Wikipedia article. Arguments: \
                {"title": "<exact article title>", "lead": false, "lang": "\(Self.defaultLang)"}. \
                `lead` is optional (default false → full article; true → just the lead paragraph). \
                `lang` is the Wikipedia language subdomain (default \(Self.defaultLang)). \
                Returns the article body as plain text without HTML chrome — sidebar, \
                infobox, edit links, references-as-superscripts are all stripped. \
                Use after `wikipedia.search` has identified the right title. Output is \
                capped at \(Self.maxBytes) bytes; truncated articles end with a marker \
                so the model knows to re-call with `lead: true` for just the intro.
                """
        )
    }

    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    private struct Args: Decodable {
        let title: String
        let lead: Bool?
        let lang: String?
    }

    private struct APIResponse: Decodable {
        let query: QueryBlock?
    }
    private struct QueryBlock: Decodable {
        let pages: [APIPage]
    }
    private struct APIPage: Decodable {
        let title: String
        let extract: String?
        let missing: Bool?
    }

    public func invoke(arguments: String) async throws -> ToolResult {
        guard let data = arguments.data(using: .utf8) else {
            return ToolResult(output: "", error: "arguments not UTF-8")
        }
        let parsed: Args
        do {
            parsed = try JSONDecoder().decode(Args.self, from: data)
        } catch {
            return ToolResult(output: "", error: "could not parse arguments: \(error.localizedDescription)")
        }
        let title = parsed.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return ToolResult(output: "", error: "title is empty")
        }
        let lang = WikipediaCommon.normalisedLang(parsed.lang)
        let leadOnly = parsed.lead ?? false

        var components = URLComponents(string: "https://\(lang).wikipedia.org/w/api.php")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "action", value: "query"),
            URLQueryItem(name: "prop", value: "extracts"),
            URLQueryItem(name: "explaintext", value: "1"),
            URLQueryItem(name: "titles", value: title),
            URLQueryItem(name: "redirects", value: "1"),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
            URLQueryItem(name: "origin", value: "*"),
        ]
        if leadOnly {
            items.append(URLQueryItem(name: "exintro", value: "1"))
        }
        components.queryItems = items
        guard let url = components.url else {
            return ToolResult(output: "", error: "could not construct Wikipedia API URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeoutSeconds
        request.setValue("Infer/agents (Wikipedia tool)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let body: Data
        let response: URLResponse
        do {
            (body, response) = try await session.data(for: request)
        } catch {
            return ToolResult(output: "", error: "fetch failed: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            return ToolResult(output: "", error: "fetch failed: HTTP \(code)")
        }
        let decoded: APIResponse
        do {
            decoded = try JSONDecoder().decode(APIResponse.self, from: body)
        } catch {
            return ToolResult(output: "", error: "could not parse Wikipedia response: \(error.localizedDescription)")
        }
        guard let pages = decoded.query?.pages, let page = pages.first else {
            return ToolResult(output: "", error: "Wikipedia returned no pages for title '\(title)'")
        }
        if page.missing == true {
            return ToolResult(
                output: "",
                error: "no Wikipedia article titled '\(title)'. Try `wikipedia.search` to find the canonical title."
            )
        }
        guard let extract = page.extract, !extract.isEmpty else {
            return ToolResult(
                output: "",
                error: "Wikipedia returned an empty extract for '\(page.title)' — likely a disambiguation page or stub."
            )
        }

        // Truncate by UTF-8 bytes, not character count, so the cap
        // matches the contract (and so a single character with a
        // long UTF-8 representation can't smuggle past). Reserve
        // headroom for the marker; size it from the marker itself
        // rather than guessing a magic number.
        if extract.utf8.count > Self.maxBytes {
            let marker = "\n\n[... truncated at \(Self.maxBytes) bytes; re-call with lead: true for the intro only ...]"
            let budget = Self.maxBytes - marker.utf8.count
            var truncated = extract
            while truncated.utf8.count > budget {
                truncated.removeLast()
            }
            truncated.append(marker)
            return ToolResult(output: truncated)
        }
        return ToolResult(output: extract)
    }
}

/// Logic shared between the two Wikipedia tools — language
/// normalisation and canonical article URL construction. Kept as a
/// caseless enum (not a struct of statics) so it's clear nothing
/// instantiates it.
enum WikipediaCommon {
    /// Normalise a user-supplied language code. Falls back to "en"
    /// when nil / empty / non-ASCII / longer than 8 characters
    /// (defensive: a 100-character string here would land in the
    /// hostname). Lowercased for canonical form.
    static func normalisedLang(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.count <= 8,
              raw.allSatisfy({ $0.isASCII && ($0.isLetter || $0 == "-") })
        else {
            return "en"
        }
        return raw.lowercased()
    }

    /// Build the canonical `https://<lang>.wikipedia.org/wiki/<title>`
    /// URL. Spaces become underscores per Wikipedia convention; the
    /// rest is percent-encoded against `urlPathAllowed` so titles like
    /// `C++` (→ `C%2B%2B`) and `Æ` (→ `%C3%86`) end up with the same
    /// canonical form Wikipedia uses internally.
    static func articleURL(title: String, lang: String) -> String {
        let underscored = title.replacingOccurrences(of: " ", with: "_")
        let encoded = underscored.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? underscored
        return "https://\(lang).wikipedia.org/wiki/\(encoded)"
    }
}
