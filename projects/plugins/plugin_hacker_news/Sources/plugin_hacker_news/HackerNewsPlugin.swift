import Foundation
import PluginAPI

/// `hn.search` / `hn.item` / `hn.user` against the public Algolia HN
/// API (`https://hn.algolia.com/api/v1`). Pure Swift, no credentials,
/// no native deps. Useful as a template for the "API-wrapper plugin"
/// shape — adding a new public-API plugin (arXiv, RSS, etc.) is a
/// near-mechanical copy of this directory.
///
/// Config (all keys optional):
///   - `api_base` (string): override the API base URL. Used by
///     integration tests that point at a fixture server. Defaults to
///     `https://hn.algolia.com/api/v1`.
public enum HackerNewsPlugin: Plugin {
    public static let id = "hackernews"

    public static func register(
        config: PluginConfig,
        invoker _: ToolInvoker
    ) async throws -> PluginContributions {
        let cfg: Config = (try? config.decode(Config.self)) ?? Config()
        let baseString = cfg.apiBase ?? "https://hn.algolia.com/api/v1"
        // `URL(string:)` is famously permissive — "not a url" parses
        // as a relative URL. Require an http(s) scheme + a non-empty
        // host so a typo'd config fails fast at register time rather
        // than producing mysterious 404s at first invoke.
        guard
            let base = URL(string: baseString),
            let scheme = base.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = base.host(percentEncoded: false), !host.isEmpty
        else {
            throw HackerNewsError.invalidAPIBase(baseString)
        }
        return PluginContributions(tools: [
            HNSearchTool(apiBase: base),
            HNItemTool(apiBase: base),
            HNUserTool(apiBase: base),
        ])
    }

    struct Config: Decodable {
        var apiBase: String?
        enum CodingKeys: String, CodingKey {
            case apiBase = "api_base"
        }
        init() {}
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.apiBase = try c.decodeIfPresent(String.self, forKey: .apiBase)
        }
    }
}

public enum HackerNewsError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidAPIBase(String)
    public var description: String {
        switch self {
        case .invalidAPIBase(let s):
            return "plugin_hacker_news: api_base is not a valid URL: \(s)"
        }
    }
}

/// Bounds shared across the three tools so the same numbers don't
/// drift in three places.
enum HNBounds {
    static let defaultLimit = 10
    static let maxLimit = 50
    static let timeoutSeconds: TimeInterval = 30
    static let maxOutputBytes = 256 * 1024
    static let userAgent = "Infer/agents (plugin_hacker_news)"

    static func clampLimit(_ requested: Int?) -> Int {
        let v = requested ?? defaultLimit
        return max(1, min(maxLimit, v))
    }
}
