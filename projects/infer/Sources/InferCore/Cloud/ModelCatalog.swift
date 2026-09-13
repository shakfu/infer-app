import Foundation

/// Chat model ids fetched from each provider's model-list endpoint and cached
/// on disk, so the model picker tracks what the provider serves today rather
/// than the list bundled at release time.
///
/// Cache: one JSON file per provider under
/// `~/Library/Caches/Infer/cloud-models/<keychainAccount>.json`, considered
/// fresh for `maxAge`. A compat endpoint's entry is ignored once its URL
/// changes. `CloudRecommendedModels.suggestions(for:)` reads the cache.
public enum CloudModelCatalog {
    public static let maxAge: TimeInterval = 24 * 60 * 60

    public struct Entry: Codable, Equatable, Sendable {
        public let endpoint: String
        public let fetchedAt: Date
        public let models: [String]
    }

    public static var defaultCacheDirectory: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Infer/cloud-models", isDirectory: true)
    }

    /// Fetch the provider's model list, filter it to chat models, and write
    /// the cache. Returns the filtered ids.
    @discardableResult
    public static func refresh(
        provider: CloudProvider,
        apiKey: String,
        session: URLSession = CloudClients.sharedSession,
        cacheDirectory: URL? = defaultCacheDirectory,
        now: Date = Date()
    ) async throws -> [String] {
        let models = try await fetch(provider: provider, apiKey: apiKey, session: session)
        guard let file = cacheFile(for: provider, in: cacheDirectory) else { return models }
        let entry = Entry(endpoint: listURL(for: provider).absoluteString, fetchedAt: now, models: models)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONEncoder().encode(entry).write(to: file, options: .atomic)
        memo.set(file, entry)
        return models
    }

    /// Cached entry for `provider`, or nil when absent, unreadable, or
    /// recorded for a different endpoint URL.
    public static func cached(
        for provider: CloudProvider,
        cacheDirectory: URL? = defaultCacheDirectory
    ) -> Entry? {
        guard let file = cacheFile(for: provider, in: cacheDirectory) else { return nil }
        let entry = memo.get(file) ?? {
            guard let data = try? Data(contentsOf: file),
                  let decoded = try? JSONDecoder().decode(Entry.self, from: data)
            else { return nil }
            memo.set(file, decoded)
            return decoded
        }()
        guard let entry, entry.endpoint == listURL(for: provider).absoluteString else { return nil }
        return entry
    }

    public static func isFresh(_ entry: Entry?, now: Date = Date()) -> Bool {
        guard let entry else { return false }
        return now.timeIntervalSince(entry.fetchedAt) < maxAge
    }

    // MARK: - Wire

    static func listURL(for provider: CloudProvider) -> URL {
        let url = provider.baseURL.appendingPathComponent("models")
        guard case .anthropic = provider else { return url }
        return URL(string: url.absoluteString + "?limit=1000")!
    }

    static func fetch(
        provider: CloudProvider,
        apiKey: String,
        session: URLSession
    ) async throws -> [String] {
        var ids: [String] = []
        var url = listURL(for: provider)
        // Anthropic paginates; 10 pages of 1000 is far beyond any real list.
        for _ in 0..<10 {
            var req = URLRequest(url: url)
            req.timeoutInterval = 30
            switch provider {
            case .anthropic:
                req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            case .openai, .openrouter, .openaiCompatible:
                req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse else { throw CloudError.invalidResponse }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(decoding: data.prefix(4096), as: UTF8.self)
                throw CloudError.http(
                    status: http.statusCode,
                    body: CloudClients.scrubKey(from: body, apiKey: apiKey)
                )
            }
            let page = try parse(data, provider: provider)
            ids += page.ids
            guard let after = page.nextAfterId,
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            else { break }
            components.queryItems = (components.queryItems ?? []).filter { $0.name != "after_id" }
                + [URLQueryItem(name: "after_id", value: after)]
            guard let next = components.url else { break }
            url = next
        }
        return ids
    }

    /// Extract chat model ids from one response page. Anthropic keeps API
    /// order (newest first); the others sort by id.
    static func parse(_ data: Data, provider: CloudProvider) throws -> (ids: [String], nextAfterId: String?) {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["data"] as? [[String: Any]]
        else { throw CloudError.decodingFailed("model list has no `data` array") }

        switch provider {
        case .anthropic:
            let ids = items.compactMap { $0["id"] as? String }
            let more = obj["has_more"] as? Bool ?? false
            return (ids, more ? obj["last_id"] as? String : nil)
        case .openrouter:
            let ids = items.filter { item in
                // Keep models that emit text; missing metadata counts as text.
                guard let outputs = (item["architecture"] as? [String: Any])?["output_modalities"] as? [String]
                else { return true }
                return outputs.contains("text")
            }.compactMap { $0["id"] as? String }
            return (ids.sorted(), nil)
        case .openai:
            return (items.compactMap { $0["id"] as? String }.filter(isOpenAIChatModel).sorted(), nil)
        case .openaiCompatible:
            return (items.compactMap { $0["id"] as? String }.sorted(), nil)
        }
    }

    /// OpenAI's `/v1/models` lists every model the key can use, with no
    /// capability metadata. Keep the chat families and drop variants that
    /// `/v1/chat/completions` rejects (audio, realtime, Responses-only
    /// `-pro` and codex models, ...). Dated snapshots duplicate their alias.
    /// A blocklist over an allowlist, so new chat families appear unaided.
    static func isOpenAIChatModel(_ id: String) -> Bool {
        let isChatFamily = id.hasPrefix("gpt-") || id.hasPrefix("chatgpt-") || id == "chat-latest"
            || (id.first == "o" && id.dropFirst().first?.isNumber == true)
        guard isChatFamily else { return false }
        let excluded = [
            "audio", "realtime", "transcribe", "tts", "image", "moderation",
            "instruct", "codex", "-pro", "deep-research", "computer-use", "live",
        ]
        if excluded.contains(where: { id.contains($0) }) { return false }
        return id.range(of: #"-\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) == nil
    }

    // MARK: - Cache

    static func cacheFile(for provider: CloudProvider, in directory: URL?) -> URL? {
        directory?.appendingPathComponent("\(provider.keychainAccount).json")
    }

    /// Avoids a disk read on every picker render.
    private static let memo = Memo()

    private final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [URL: Entry] = [:]
        func get(_ url: URL) -> Entry? {
            lock.lock(); defer { lock.unlock() }
            return entries[url]
        }
        func set(_ url: URL, _ entry: Entry) {
            lock.lock(); defer { lock.unlock() }
            entries[url] = entry
        }
    }
}
