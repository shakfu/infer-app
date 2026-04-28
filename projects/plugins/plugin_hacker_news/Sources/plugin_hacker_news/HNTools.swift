import Foundation
import PluginAPI

// MARK: - Shared HTTP

/// Minimal GET-with-JSON-decode helper shared by the three tools.
/// Returns either decoded `T` or a `ToolResult` carrying the error
/// message — pushes the model-facing error path through the same
/// shape every tool uses.
enum HNHTTPError: Error {
    case requestFailed(String)
    case nonSuccessStatus(Int)
    case decodeFailed(String)
}

@Sendable
func hnFetchJSON<T: Decodable>(
    _ type: T.Type,
    url: URL,
    session: URLSession
) async throws -> T {
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = HNBounds.timeoutSeconds
    request.setValue(HNBounds.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let body: Data
    let response: URLResponse
    do {
        (body, response) = try await session.data(for: request)
    } catch {
        throw HNHTTPError.requestFailed(error.localizedDescription)
    }
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
        throw HNHTTPError.nonSuccessStatus(http.statusCode)
    }
    do {
        return try JSONDecoder().decode(T.self, from: body)
    } catch {
        throw HNHTTPError.decodeFailed(error.localizedDescription)
    }
}

func hnEncode<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    var output = String(decoding: data, as: UTF8.self)
    if output.utf8.count > HNBounds.maxOutputBytes {
        // Truncate at the byte cap and append a marker. We slice on
        // String index boundaries to avoid splitting a multi-byte
        // sequence.
        let cap = HNBounds.maxOutputBytes - 64
        if let truncated = output.utf8.prefix(cap).asString() {
            output = truncated + "\n[truncated: response exceeded \(HNBounds.maxOutputBytes) bytes]"
        }
    }
    return output
}

private extension Sequence where Element == UInt8 {
    func asString() -> String? {
        let bytes = Array(self)
        return String(bytes: bytes, encoding: .utf8)
    }
}

// MARK: - hn.search

/// Search Hacker News via Algolia's HN API. Argument schema:
///   {"query": "<terms>", "type": "story|comment|all", "limit": 10}
///
/// `type` is optional (default `"story"`). Algolia's `tags` query
/// parameter does the filtering — we map our concise vocabulary onto
/// Algolia's tag names.
struct HNSearchTool: BuiltinTool {
    let apiBase: URL
    let session: URLSession

    init(apiBase: URL, session: URLSession = .shared) {
        self.apiBase = apiBase
        self.session = session
    }

    var name: ToolName { "hn.search" }

    var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
                Search Hacker News (Algolia HN API). Arguments: \
                {"query": "<terms>", "type": "story", "limit": 10}. \
                `type` is optional (default "story"; values: "story", "comment", "all"). \
                `limit` is optional (default \(HNBounds.defaultLimit), max \(HNBounds.maxLimit)). \
                Returns a JSON array of hits ordered by relevance, each: \
                {id, title, url, author, points, comment_count, created_at_unix, hn_url, tags}. \
                For comments, `title` is the parent story's title and `url` is the parent's URL; \
                `hn_url` is always the news.ycombinator.com permalink for the hit itself. \
                Use `hn.item` to fetch the full text + comment tree of any hit.
                """
        )
    }

    private struct Args: Decodable {
        let query: String
        let type: String?
        let limit: Int?
    }

    private struct AlgoliaResponse: Decodable {
        let hits: [AlgoliaHit]
    }

    private struct AlgoliaHit: Decodable {
        let objectID: String
        let title: String?
        let story_title: String?
        let url: String?
        let story_url: String?
        let author: String?
        let points: Int?
        let num_comments: Int?
        let created_at_i: Int?
        let _tags: [String]?
    }

    private struct SearchResultItem: Encodable {
        let id: String
        let title: String
        let url: String?
        let author: String?
        let points: Int
        let comment_count: Int
        let created_at_unix: Int
        let hn_url: String
        let tags: [String]
    }

    func invoke(arguments: String) async throws -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: Data(arguments.utf8))
        } catch {
            return ToolResult(output: "", error: "could not parse arguments: \(error.localizedDescription)")
        }
        let query = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return ToolResult(output: "", error: "query is empty")
        }
        let limit = HNBounds.clampLimit(args.limit)
        let typeTag: String?
        switch (args.type ?? "story").lowercased() {
        case "story": typeTag = "story"
        case "comment": typeTag = "comment"
        case "all": typeTag = nil
        default:
            return ToolResult(output: "", error: "type must be one of: story, comment, all")
        }

        var components = URLComponents(url: apiBase.appending(path: "search"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "hitsPerPage", value: String(limit)),
        ]
        if let typeTag {
            items.append(URLQueryItem(name: "tags", value: typeTag))
        }
        components.queryItems = items
        guard let url = components.url else {
            return ToolResult(output: "", error: "could not construct HN API URL")
        }

        let decoded: AlgoliaResponse
        do {
            decoded = try await hnFetchJSON(AlgoliaResponse.self, url: url, session: session)
        } catch let HNHTTPError.requestFailed(msg) {
            return ToolResult(output: "", error: "search failed: \(msg)")
        } catch let HNHTTPError.nonSuccessStatus(code) {
            return ToolResult(output: "", error: "search failed: HTTP \(code)")
        } catch let HNHTTPError.decodeFailed(msg) {
            return ToolResult(output: "", error: "could not parse HN response: \(msg)")
        }

        let results: [SearchResultItem] = decoded.hits.map { hit in
            SearchResultItem(
                id: hit.objectID,
                title: hit.title ?? hit.story_title ?? "",
                url: hit.url ?? hit.story_url,
                author: hit.author,
                points: hit.points ?? 0,
                comment_count: hit.num_comments ?? 0,
                created_at_unix: hit.created_at_i ?? 0,
                hn_url: "https://news.ycombinator.com/item?id=\(hit.objectID)",
                tags: hit._tags ?? []
            )
        }
        do {
            return ToolResult(output: try hnEncode(results))
        } catch {
            return ToolResult(output: "", error: "could not encode results: \(error.localizedDescription)")
        }
    }
}

// MARK: - hn.item

/// Fetch a single HN story or comment by id. Comments include their
/// parent + story refs; stories include the children comment tree
/// (clipped to a sensible depth so a viral submission with thousands
/// of replies doesn't blow the response cap).
struct HNItemTool: BuiltinTool {
    let apiBase: URL
    let session: URLSession

    init(apiBase: URL, session: URLSession = .shared) {
        self.apiBase = apiBase
        self.session = session
    }

    var name: ToolName { "hn.item" }

    var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
                Fetch a Hacker News story or comment by id. Arguments: \
                {"id": <integer or string>, "max_comment_depth": 3}. \
                `max_comment_depth` is optional (default 3) and clips the recursive children \
                tree so a long thread doesn't blow the output cap of \(HNBounds.maxOutputBytes) bytes. \
                Returns a JSON object: \
                {id, type, title, url, author, points, text, parent_id, story_id, created_at_unix, \
                hn_url, children: [<recursive>]}. \
                For comments, `text` is the comment body (HTML); for stories with self-text, \
                `text` is the story body. Use `hn.search` first to find candidate ids.
                """
        )
    }

    private struct Args: Decodable {
        let id: AnyID
        let max_comment_depth: Int?

        // Algolia returns ids as strings but the model often passes
        // integers; accept both transparently.
        struct AnyID: Decodable {
            let value: String
            init(from decoder: any Decoder) throws {
                let c = try decoder.singleValueContainer()
                if let s = try? c.decode(String.self) { self.value = s; return }
                if let i = try? c.decode(Int.self) { self.value = String(i); return }
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "id must be string or int")
            }
        }
    }

    private struct AlgoliaItem: Decodable {
        let id: Int
        let type: String?
        let title: String?
        let url: String?
        let author: String?
        let points: Int?
        let text: String?
        let parent_id: Int?
        let story_id: Int?
        let created_at_i: Int?
        let children: [AlgoliaItem]?
    }

    private struct ItemResult: Encodable {
        let id: Int
        let type: String?
        let title: String?
        let url: String?
        let author: String?
        let points: Int
        let text: String?
        let parent_id: Int?
        let story_id: Int?
        let created_at_unix: Int
        let hn_url: String
        let children: [ItemResult]
    }

    func invoke(arguments: String) async throws -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: Data(arguments.utf8))
        } catch {
            return ToolResult(output: "", error: "could not parse arguments: \(error.localizedDescription)")
        }
        let depth = max(0, min(10, args.max_comment_depth ?? 3))
        let url = apiBase.appending(path: "items").appending(path: args.id.value)

        let decoded: AlgoliaItem
        do {
            decoded = try await hnFetchJSON(AlgoliaItem.self, url: url, session: session)
        } catch let HNHTTPError.requestFailed(msg) {
            return ToolResult(output: "", error: "fetch failed: \(msg)")
        } catch let HNHTTPError.nonSuccessStatus(code) {
            if code == 404 {
                return ToolResult(output: "", error: "no HN item with id \(args.id.value)")
            }
            return ToolResult(output: "", error: "fetch failed: HTTP \(code)")
        } catch let HNHTTPError.decodeFailed(msg) {
            return ToolResult(output: "", error: "could not parse HN response: \(msg)")
        }

        let result = transform(decoded, remainingDepth: depth)
        do {
            return ToolResult(output: try hnEncode(result))
        } catch {
            return ToolResult(output: "", error: "could not encode item: \(error.localizedDescription)")
        }
    }

    private func transform(_ item: AlgoliaItem, remainingDepth: Int) -> ItemResult {
        let kids: [ItemResult]
        if remainingDepth > 0, let children = item.children, !children.isEmpty {
            kids = children.map { transform($0, remainingDepth: remainingDepth - 1) }
        } else {
            kids = []
        }
        return ItemResult(
            id: item.id,
            type: item.type,
            title: item.title,
            url: item.url,
            author: item.author,
            points: item.points ?? 0,
            text: item.text,
            parent_id: item.parent_id,
            story_id: item.story_id,
            created_at_unix: item.created_at_i ?? 0,
            hn_url: "https://news.ycombinator.com/item?id=\(item.id)",
            children: kids
        )
    }
}

// MARK: - hn.user

/// Fetch a HN user's profile by username.
struct HNUserTool: BuiltinTool {
    let apiBase: URL
    let session: URLSession

    init(apiBase: URL, session: URLSession = .shared) {
        self.apiBase = apiBase
        self.session = session
    }

    var name: ToolName { "hn.user" }

    var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: """
                Fetch a Hacker News user profile by username. Arguments: \
                {"username": "<user>"}. \
                Returns {username, karma, about_html, created_at_unix, average_post_score, hn_url}. \
                `about_html` is the profile body as HTML (HN allows limited markup); \
                `average_post_score` is Algolia's `avg` field. Returns an error for unknown users.
                """
        )
    }

    private struct Args: Decodable {
        let username: String
    }

    private struct AlgoliaUser: Decodable {
        let username: String
        let karma: Int?
        let about: String?
        let created_at_i: Int?
        let avg: Double?
    }

    private struct UserResult: Encodable {
        let username: String
        let karma: Int
        let about_html: String
        let created_at_unix: Int
        let average_post_score: Double
        let hn_url: String
    }

    func invoke(arguments: String) async throws -> ToolResult {
        let args: Args
        do {
            args = try JSONDecoder().decode(Args.self, from: Data(arguments.utf8))
        } catch {
            return ToolResult(output: "", error: "could not parse arguments: \(error.localizedDescription)")
        }
        let username = args.username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty else {
            return ToolResult(output: "", error: "username is empty")
        }
        // HN usernames are alphanumerics + underscore + dash; reject
        // anything else before constructing the URL.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        if username.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return ToolResult(output: "", error: "username contains invalid characters")
        }
        let url = apiBase.appending(path: "users").appending(path: username)

        let decoded: AlgoliaUser
        do {
            decoded = try await hnFetchJSON(AlgoliaUser.self, url: url, session: session)
        } catch let HNHTTPError.requestFailed(msg) {
            return ToolResult(output: "", error: "fetch failed: \(msg)")
        } catch let HNHTTPError.nonSuccessStatus(code) {
            if code == 404 {
                return ToolResult(output: "", error: "no HN user named \(username)")
            }
            return ToolResult(output: "", error: "fetch failed: HTTP \(code)")
        } catch let HNHTTPError.decodeFailed(msg) {
            return ToolResult(output: "", error: "could not parse HN response: \(msg)")
        }

        let result = UserResult(
            username: decoded.username,
            karma: decoded.karma ?? 0,
            about_html: decoded.about ?? "",
            created_at_unix: decoded.created_at_i ?? 0,
            average_post_score: decoded.avg ?? 0,
            hn_url: "https://news.ycombinator.com/user?id=\(decoded.username)"
        )
        do {
            return ToolResult(output: try hnEncode(result))
        } catch {
            return ToolResult(output: "", error: "could not encode user: \(error.localizedDescription)")
        }
    }
}
