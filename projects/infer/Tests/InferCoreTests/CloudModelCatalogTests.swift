import XCTest
@testable import InferCore

final class CloudModelCatalogTests: XCTestCase {
    private var cacheDir: URL!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: cacheDir)
        super.tearDown()
    }

    private func json(_ s: String) -> Data { Data(s.utf8) }

    private func respond(_ pages: [String]) {
        StubURLProtocol.handler = { req in
            let index = StubURLProtocol.urls.count - 1
            let body = index < pages.count ? pages[index] : "{}"
            return (HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(body.utf8))
        }
    }

    func testListURLs() {
        XCTAssertEqual(CloudModelCatalog.listURL(for: .openai).absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(CloudModelCatalog.listURL(for: .openrouter).absoluteString, "https://openrouter.ai/api/v1/models")
        XCTAssertEqual(CloudModelCatalog.listURL(for: .anthropic).absoluteString, "https://api.anthropic.com/v1/models?limit=1000")
        XCTAssertEqual(
            CloudModelCatalog.listURL(for: .openaiCompatible(name: "o", baseURL: URL(string: "http://localhost:11434/v1")!)).absoluteString,
            "http://localhost:11434/v1/models"
        )
    }

    func testOpenAIFilterKeepsChatModelsOnly() throws {
        let ids = [
            "gpt-5.5", "gpt-5.5-2026-04-23", "gpt-5.5-pro", "gpt-5.4-mini", "o3", "o4-mini",
            "chat-latest", "gpt-5.3-codex", "gpt-realtime", "gpt-audio", "gpt-4o-mini-tts",
            "gpt-image-2", "text-embedding-3-small", "whisper-1", "gpt-3.5-turbo-instruct",
            "omni-moderation-latest", "gpt-live-1", "o1-pro", "dall-e-3",
        ]
        let data = json(#"{"data":["# + ids.map { #"{"id":"\#($0)"}"# }.joined(separator: ",") + "]}")
        let parsed = try CloudModelCatalog.parse(data, provider: .openai)
        XCTAssertEqual(parsed.ids, ["chat-latest", "gpt-5.4-mini", "gpt-5.5", "o3", "o4-mini"])
        XCTAssertNil(parsed.nextAfterId)
    }

    func testOpenRouterDropsModelsWithoutTextOutput() throws {
        let data = json(#"""
        {"data":[
          {"id":"z/text","architecture":{"output_modalities":["text"]}},
          {"id":"a/image","architecture":{"output_modalities":["image"]}},
          {"id":"b/no-metadata"}
        ]}
        """#)
        XCTAssertEqual(try CloudModelCatalog.parse(data, provider: .openrouter).ids, ["b/no-metadata", "z/text"])
    }

    func testAnthropicFetchFollowsPaginationAndKeepsOrder() async throws {
        respond([
            #"{"data":[{"id":"claude-new"},{"id":"claude-mid"}],"has_more":true,"last_id":"claude-mid"}"#,
            #"{"data":[{"id":"claude-old"}],"has_more":false,"last_id":"claude-old"}"#,
        ])
        let ids = try await CloudModelCatalog.fetch(provider: .anthropic, apiKey: "sk-ant", session: makeStubSession())
        XCTAssertEqual(ids, ["claude-new", "claude-mid", "claude-old"])
        XCTAssertEqual(StubURLProtocol.urls.count, 2)
        XCTAssertEqual(StubURLProtocol.urls[1].absoluteString, "https://api.anthropic.com/v1/models?limit=1000&after_id=claude-mid")
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "x-api-key"), "sk-ant")
        XCTAssertNotNil(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "anthropic-version"))
    }

    func testRefreshCachesAndSuggestionsPreferFetchedList() async throws {
        let provider = CloudProvider.openaiCompatible(name: "Stub", baseURL: URL(string: "https://compat.test/v1")!)
        XCTAssertEqual(CloudRecommendedModels.suggestions(for: provider, cacheDirectory: cacheDir), [])

        respond([#"{"data":[{"id":"m2"},{"id":"m1"}]}"#])
        let fetchedAt = Date(timeIntervalSince1970: 1_000_000)
        try await CloudModelCatalog.refresh(
            provider: provider, apiKey: "k", session: makeStubSession(),
            cacheDirectory: cacheDir, now: fetchedAt
        )
        XCTAssertEqual(StubURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer k")

        let entry = try XCTUnwrap(CloudModelCatalog.cached(for: provider, cacheDirectory: cacheDir))
        XCTAssertEqual(entry.models, ["m1", "m2"])
        XCTAssertTrue(CloudModelCatalog.isFresh(entry, now: fetchedAt.addingTimeInterval(3600)))
        XCTAssertFalse(CloudModelCatalog.isFresh(entry, now: fetchedAt.addingTimeInterval(CloudModelCatalog.maxAge + 1)))
        XCTAssertEqual(CloudRecommendedModels.suggestions(for: provider, cacheDirectory: cacheDir), ["m1", "m2"])

        // The file on disk is what a relaunch reads.
        let file = try XCTUnwrap(CloudModelCatalog.cacheFile(for: provider, in: cacheDir))
        let onDisk = try JSONDecoder().decode(CloudModelCatalog.Entry.self, from: Data(contentsOf: file))
        XCTAssertEqual(onDisk, entry)
    }

    func testCacheIgnoredWhenCompatURLChanges() async throws {
        let original = CloudProvider.openaiCompatible(name: "Same", baseURL: URL(string: "https://one.test/v1")!)
        let moved = CloudProvider.openaiCompatible(name: "Same", baseURL: URL(string: "https://two.test/v1")!)
        respond([#"{"data":[{"id":"m"}]}"#])
        try await CloudModelCatalog.refresh(provider: original, apiKey: "k", session: makeStubSession(), cacheDirectory: cacheDir)
        XCTAssertNotNil(CloudModelCatalog.cached(for: original, cacheDirectory: cacheDir))
        XCTAssertNil(CloudModelCatalog.cached(for: moved, cacheDirectory: cacheDir))
    }

    func testHTTPErrorThrowsAndLeavesCacheUntouched() async {
        let provider = CloudProvider.openaiCompatible(name: "Err", baseURL: URL(string: "https://err.test/v1")!)
        StubURLProtocol.handler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!,
             Data(#"{"error":"bad key sk-test-1234567890abcdef"}"#.utf8))
        }
        do {
            try await CloudModelCatalog.refresh(
                provider: provider, apiKey: "sk-test-1234567890abcdef",
                session: makeStubSession(), cacheDirectory: cacheDir
            )
            XCTFail("expected throw")
        } catch let CloudError.http(status, body) {
            XCTAssertEqual(status, 401)
            XCTAssertFalse(body.contains("sk-test-1234567890abcdef"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertNil(CloudModelCatalog.cached(for: provider, cacheDirectory: cacheDir))
    }
}
