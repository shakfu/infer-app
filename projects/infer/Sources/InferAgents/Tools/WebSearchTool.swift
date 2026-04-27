import Foundation

/// Web search via one of two backends, chosen at registration time:
///
/// - **DuckDuckGo** (default; no setup). Hits `html.duckduckgo.com`,
///   parses the HTML response. Fragile to DOM changes — DDG can rev
///   their template at any time and break this tool — but works
///   immediately for users who don't want to run their own search
///   stack. The unit tests pin the parser against canned DDG HTML so
///   a future DDG change shows up as a test failure rather than a
///   silently-empty result list at runtime.
///
/// - **SearXNG** (opt-in). When `searxngEndpoint` is configured, the
///   tool uses SearXNG's stable JSON API instead. Robust, fast, and
///   under the user's own administrative control; the trade-off is
///   that the user has to run (or borrow) a SearXNG instance.
///
/// Argument schema:
/// ```
/// {
///   "query": "swift concurrency actors",
///   "limit": 5         // optional, default 5, capped at 10
/// }
/// ```
///
/// Result is a JSON array of `{title, url, snippet}` ordered by
/// relevance. The model can either answer from the snippets directly
/// or follow up with `http.fetch` (which has its own host allowlist —
/// search results pointing at hosts the user hasn't allowed are
/// readable to the model as text but not fetchable).
///
/// **Not a sandbox-bypass.** This tool does not loosen `http.fetch`'s
/// allowlist. The user explicitly opts a domain into `http.fetch` via
/// the agent layer; `web.search` only surfaces *which* URLs exist for
/// a query, not their contents.
public struct WebSearchTool: BuiltinTool, @unchecked Sendable {
    public let name: ToolName = "web.search"

    public static let defaultLimit = 5
    public static let maxLimit = 10
    public static let timeoutSeconds: TimeInterval = 30

    public enum Backend: Sendable, Equatable {
        case duckDuckGo
        case searxng(URL)
    }

    public struct SearchResult: Codable, Equatable, Sendable {
        public let title: String
        public let url: String
        public let snippet: String
    }

    public var spec: ToolSpec {
        let backendNote: String
        switch backend {
        case .duckDuckGo:
            backendNote = "DuckDuckGo HTML"
        case .searxng:
            backendNote = "SearXNG"
        }
        return ToolSpec(
            name: name,
            description: """
                Search the public web. Arguments: \
                {"query": "<search terms>", "limit": \(Self.defaultLimit)}. \
                `limit` is optional (default \(Self.defaultLimit), max \(Self.maxLimit)). \
                Returns a JSON array of {title, url, snippet} ordered by relevance. \
                Active backend: \(backendNote). Use to FIND URLs; use `http.fetch` \
                (with the host on the allowlist) to read a result's contents. \
                Search results pointing at hosts not on the http.fetch allowlist \
                are still useful — quote the snippet to the user, or ask them to \
                widen the allowlist.
                """
        )
    }

    public let backend: Backend
    /// Test seam: defaults to `URLSession.shared`. Tests inject a stub
    /// session backed by a `URLProtocol` mock so the parser is
    /// exercised without real network. Same pattern as `URLFetchTool`.
    public let session: URLSession

    public init(backend: Backend = .duckDuckGo, session: URLSession = .shared) {
        self.backend = backend
        self.session = session
    }

    /// Convenience for the chat VM's bootstrap: pass the user's
    /// `searxngEndpoint` setting and get the right backend. Empty /
    /// nil / unparseable endpoint → DDG fallback.
    public init(searxngEndpoint: String?, session: URLSession = .shared) {
        if let raw = searxngEndpoint?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let url = URL(string: raw),
           url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" {
            self.backend = .searxng(url)
        } else {
            self.backend = .duckDuckGo
        }
        self.session = session
    }

    private struct Args: Decodable {
        let query: String
        let limit: Int?
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

        let results: [SearchResult]
        do {
            switch backend {
            case .duckDuckGo:
                results = try await searchDDG(query: query, limit: limit)
            case .searxng(let endpoint):
                results = try await searchSearXNG(query: query, limit: limit, endpoint: endpoint)
            }
        } catch {
            return ToolResult(output: "", error: "search failed: \(error.localizedDescription)")
        }

        if results.isEmpty {
            // Empty result is not an error — the model should be told
            // "no hits" so it can fall back to parametric knowledge or
            // suggest a broader query, rather than retrying blindly.
            return ToolResult(output: "[]")
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

    // MARK: - DuckDuckGo

    private func searchDDG(query: String, limit: Int) async throws -> [SearchResult] {
        // POST is the documented submission shape for DDG's HTML
        // endpoint and is more reliable than GET (some DDG fronts
        // reject GET with empty form bodies).
        guard var components = URLComponents(string: "https://html.duckduckgo.com/html/") else {
            throw URLError(.badURL)
        }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.timeoutSeconds
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        // DDG rejects requests with no User-Agent or with the default
        // URLSession UA. A plain Mozilla string is the conventional
        // dodge for headless scraping.
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0",
            forHTTPHeaderField: "User-Agent"
        )
        request.httpBody = "q=\(query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")".data(using: .utf8)

        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.init(rawValue: http.statusCode))
        }
        guard let html = String(data: body, encoding: .utf8) else {
            throw URLError(.cannotDecodeContentData)
        }
        let parsed = Self.parseDDGHTML(html)
        return Array(parsed.prefix(limit))
    }

    /// DDG HTML parser. Public-static so unit tests can pin the parser
    /// against canned HTML without spinning up a tool / URLSession.
    /// The shape we target:
    ///
    /// ```
    /// <div class="result results_links_deep">
    ///   <h2 class="result__title">
    ///     <a class="result__a" href="//duckduckgo.com/l/?uddg=<encoded>&...">Title</a>
    ///   </h2>
    ///   <a class="result__snippet" href="...">Snippet text with <b>highlights</b></a>
    /// </div>
    /// ```
    ///
    /// Not a real HTML parser — `NSRegularExpression` against a
    /// stable-enough pattern. If DDG tightens markup whitespace or
    /// renames classes, this returns `[]` and the unit tests fail
    /// before users notice.
    public static func parseDDGHTML(_ html: String) -> [SearchResult] {
        // One match per result. The `[\s\S]` form matches across
        // newlines (Swift's NSRegularExpression doesn't have
        // `dotAll` by default).
        let pattern = #"class=\"result__a\"[^>]*href=\"([^\"]+)\"[^>]*>([\s\S]*?)</a>[\s\S]*?class=\"result__snippet\"[^>]*>([\s\S]*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let range = NSRange(html.startIndex..., in: html)
        var results: [SearchResult] = []
        regex.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match,
                  match.numberOfRanges == 4,
                  let urlRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html),
                  let snippetRange = Range(match.range(at: 3), in: html) else {
                return
            }
            let rawURL = String(html[urlRange])
            let rawTitle = String(html[titleRange])
            let rawSnippet = String(html[snippetRange])
            let resolvedURL = unwrapDDGRedirect(rawURL)
            let title = decodeHTMLEntities(stripHTMLTags(rawTitle)).trimmingCharacters(in: .whitespacesAndNewlines)
            let snippet = decodeHTMLEntities(stripHTMLTags(rawSnippet)).trimmingCharacters(in: .whitespacesAndNewlines)
            // Drop entries whose URL or title couldn't be salvaged —
            // returning empty fields would just feed the model junk.
            guard !resolvedURL.isEmpty, !title.isEmpty else { return }
            results.append(SearchResult(title: title, url: resolvedURL, snippet: snippet))
        }
        return results
    }

    /// DDG wraps result links as `//duckduckgo.com/l/?uddg=<percent-encoded-real-url>&...`.
    /// Unwrap to the underlying URL. Some result types (DDG's own
    /// instant-answer rows) come through unwrapped — pass those
    /// through as-is, prefixing `https:` to scheme-relative URLs.
    static func unwrapDDGRedirect(_ raw: String) -> String {
        let normalised: String
        if raw.hasPrefix("//") {
            normalised = "https:" + raw
        } else {
            normalised = raw
        }
        guard let components = URLComponents(string: normalised),
              components.host?.contains("duckduckgo.com") == true,
              let uddg = components.queryItems?.first(where: { $0.name == "uddg" })?.value
        else {
            return normalised
        }
        // `uddg` is already percent-decoded by URLComponents, but
        // some DDG fronts double-encode — try a re-decode pass.
        return uddg.removingPercentEncoding ?? uddg
    }

    // HTML helpers (`stripHTMLTags`, `decodeHTMLEntities`) live as
    // free functions in `HTMLTextHelpers.swift` so other tools that
    // consume search-engine snippet markup (Wikipedia search, future
    // SERP tools) can share them.

    // MARK: - SearXNG

    private struct SearXNGResponse: Decodable {
        let results: [SearXNGResult]
    }

    private struct SearXNGResult: Decodable {
        let title: String?
        let url: String?
        let content: String?
    }

    private func searchSearXNG(query: String, limit: Int, endpoint: URL) async throws -> [SearchResult] {
        // SearXNG accepts both POST and GET; GET is simpler and works
        // against every install I've tested. `format=json` is the
        // critical bit — without it SearXNG returns its HTML UI.
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        // Append `/search` if the user gave us the bare instance URL.
        if let path = components?.path, !path.hasSuffix("/search") {
            components?.path = path.hasSuffix("/") ? path + "search" : path + "/search"
        }
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components?.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeoutSeconds
        request.setValue("Infer/agents", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw URLError(.init(rawValue: http.statusCode))
        }
        let decoded = try JSONDecoder().decode(SearXNGResponse.self, from: body)
        let mapped = decoded.results.compactMap { r -> SearchResult? in
            guard let title = r.title, let url = r.url else { return nil }
            return SearchResult(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                url: url,
                snippet: (r.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return Array(mapped.prefix(limit))
    }
}
