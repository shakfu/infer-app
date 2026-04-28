import XCTest
@testable import PluginAPI
@testable import plugin_hacker_news

/// Fast-path unit tests with stubbed HTTP. The real-API tests live
/// in `HackerNewsExternalTests` and skip on CI / offline boxes.
final class HNToolsUnitTests: XCTestCase {

    // MARK: - Plugin shape

    func testRegisterContributesThreeTools() async throws {
        let contrib = try await HackerNewsPlugin.register(
            config: .empty,
            invoker: { _, _ in ToolResult(output: "") }
        )
        let names = contrib.tools.map(\.name).sorted()
        XCTAssertEqual(names, ["hn.item", "hn.search", "hn.user"])
    }

    func testRegisterRejectsInvalidAPIBase() async {
        let cfg = PluginConfig(json: Data(#"{"api_base":"not a url"}"#.utf8))
        do {
            _ = try await HackerNewsPlugin.register(
                config: cfg,
                invoker: { _, _ in ToolResult(output: "") }
            )
            XCTFail("expected throw")
        } catch let error as HackerNewsError {
            guard case .invalidAPIBase = error else {
                return XCTFail("wrong error case: \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testRegisterAcceptsCustomAPIBase() async throws {
        let cfg = PluginConfig(json: Data(#"{"api_base":"https://example.test/api"}"#.utf8))
        _ = try await HackerNewsPlugin.register(
            config: cfg,
            invoker: { _, _ in ToolResult(output: "") }
        )
    }

    // MARK: - Bounds

    func testClampLimitInsideRange() {
        XCTAssertEqual(HNBounds.clampLimit(nil), 10)
        XCTAssertEqual(HNBounds.clampLimit(0), 1)
        XCTAssertEqual(HNBounds.clampLimit(-3), 1)
        XCTAssertEqual(HNBounds.clampLimit(99), 50)
        XCTAssertEqual(HNBounds.clampLimit(25), 25)
    }

    // MARK: - hn.search wire shape

    func testSearchRejectsEmptyQuery() async throws {
        let tool = HNSearchTool(apiBase: URL(string: "https://example.test/api")!,
                                session: Self.makeStubSession())
        let result = try await tool.invoke(arguments: #"{"query":"   "}"#)
        XCTAssertEqual(result.error, "query is empty")
    }

    func testSearchRejectsUnknownType() async throws {
        let tool = HNSearchTool(apiBase: URL(string: "https://example.test/api")!,
                                session: Self.makeStubSession())
        let result = try await tool.invoke(arguments: #"{"query":"x","type":"banana"}"#)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("type must be one of"))
    }

    func testSearchHappyPath() async throws {
        let json = """
            {"hits":[
                {"objectID":"123","title":"Show HN: foo","url":"https://foo.test","author":"alice","points":42,"num_comments":7,"created_at_i":1700000000,"_tags":["story","show_hn"]},
                {"objectID":"456","title":null,"story_title":"Parent","url":null,"story_url":"https://parent.test","author":"bob","points":3,"num_comments":0,"created_at_i":1700000010,"_tags":["comment"]}
            ]}
            """
        StubURLProtocol.register(response: .success(jsonBody: json))
        defer { StubURLProtocol.clear() }

        let tool = HNSearchTool(apiBase: URL(string: "https://hn.algolia.com/api/v1")!,
                                session: Self.makeStubSession())
        let result = try await tool.invoke(arguments: #"{"query":"foo","limit":2}"#)
        XCTAssertNil(result.error)
        struct Item: Decodable {
            let id: String
            let title: String
            let url: String?
            let author: String?
            let points: Int
            let comment_count: Int
            let hn_url: String
            let tags: [String]
        }
        let items = try JSONDecoder().decode([Item].self, from: Data(result.output.utf8))
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].id, "123")
        XCTAssertEqual(items[0].title, "Show HN: foo")
        XCTAssertEqual(items[0].url, "https://foo.test")
        XCTAssertEqual(items[0].points, 42)
        XCTAssertEqual(items[0].hn_url, "https://news.ycombinator.com/item?id=123")
        XCTAssertEqual(items[0].tags, ["story", "show_hn"])
        // Comment hit should fall back to story_title and story_url.
        XCTAssertEqual(items[1].title, "Parent")
        XCTAssertEqual(items[1].url, "https://parent.test")
    }

    func testSearchURLContainsExpectedQueryItems() async throws {
        StubURLProtocol.register(response: .success(jsonBody: #"{"hits":[]}"#))
        defer { StubURLProtocol.clear() }
        let tool = HNSearchTool(apiBase: URL(string: "https://hn.algolia.com/api/v1")!,
                                session: Self.makeStubSession())
        _ = try await tool.invoke(arguments: #"{"query":"swift concurrency","type":"comment","limit":7}"#)
        let captured = try XCTUnwrap(StubURLProtocol.lastRequest)
        let comps = URLComponents(url: captured.url!, resolvingAgainstBaseURL: false)!
        let items = comps.queryItems ?? []
        XCTAssertTrue(items.contains(URLQueryItem(name: "query", value: "swift concurrency")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "tags", value: "comment")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "hitsPerPage", value: "7")))
        XCTAssertEqual(captured.url!.path, "/api/v1/search")
    }

    func testSearchTypeAllOmitsTagsParameter() async throws {
        StubURLProtocol.register(response: .success(jsonBody: #"{"hits":[]}"#))
        defer { StubURLProtocol.clear() }
        let tool = HNSearchTool(apiBase: URL(string: "https://hn.algolia.com/api/v1")!,
                                session: Self.makeStubSession())
        _ = try await tool.invoke(arguments: #"{"query":"x","type":"all"}"#)
        let captured = try XCTUnwrap(StubURLProtocol.lastRequest)
        let comps = URLComponents(url: captured.url!, resolvingAgainstBaseURL: false)!
        let names = (comps.queryItems ?? []).map(\.name)
        XCTAssertFalse(names.contains("tags"), "type=all should omit the tags filter")
    }

    func testSearchHTTPErrorSurfaced() async throws {
        StubURLProtocol.register(response: .status(503))
        defer { StubURLProtocol.clear() }
        let tool = HNSearchTool(apiBase: URL(string: "https://hn.algolia.com/api/v1")!,
                                session: Self.makeStubSession())
        let result = try await tool.invoke(arguments: #"{"query":"x"}"#)
        XCTAssertEqual(result.error, "search failed: HTTP 503")
    }

    func testSearchEmptyHitsReturnsEmptyArray() async throws {
        StubURLProtocol.register(response: .success(jsonBody: #"{"hits":[]}"#))
        defer { StubURLProtocol.clear() }
        let tool = HNSearchTool(apiBase: URL(string: "https://hn.algolia.com/api/v1")!,
                                session: Self.makeStubSession())
        let result = try await tool.invoke(arguments: #"{"query":"x"}"#)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, "[]")
    }

    // MARK: - hn.item

    func testItemAcceptsBothStringAndIntID() async throws {
        StubURLProtocol.register(response: .success(jsonBody: #"{"id":1,"type":"story","author":"a"}"#))
        defer { StubURLProtocol.clear() }
        let tool = HNItemTool(apiBase: URL(string: "https://hn.algolia.com/api/v1")!,
                              session: Self.makeStubSession())
        let r1 = try await tool.invoke(arguments: #"{"id":1}"#)
        XCTAssertNil(r1.error)
        let r2 = try await tool.invoke(arguments: #"{"id":"1"}"#)
        XCTAssertNil(r2.error)
    }

    func testItem404IsFriendly() async throws {
        StubURLProtocol.register(response: .status(404))
        defer { StubURLProtocol.clear() }
        let tool = HNItemTool(apiBase: URL(string: "https://hn.algolia.com/api/v1")!,
                              session: Self.makeStubSession())
        let result = try await tool.invoke(arguments: #"{"id":99999999999}"#)
        XCTAssertEqual(result.error, "no HN item with id 99999999999")
    }

    func testItemClipsCommentDepth() async throws {
        // Build a 5-level deep tree; depth=2 should keep the root + 2 levels.
        let json = """
            {"id":1,"type":"story","author":"a","children":[
                {"id":2,"type":"comment","author":"b","children":[
                    {"id":3,"type":"comment","author":"c","children":[
                        {"id":4,"type":"comment","author":"d","children":[
                            {"id":5,"type":"comment","author":"e","children":[]}
                        ]}
                    ]}
                ]}
            ]}
            """
        StubURLProtocol.register(response: .success(jsonBody: json))
        defer { StubURLProtocol.clear() }
        let tool = HNItemTool(apiBase: URL(string: "https://hn.algolia.com/api/v1")!,
                              session: Self.makeStubSession())
        let result = try await tool.invoke(arguments: #"{"id":1,"max_comment_depth":2}"#)
        struct Node: Decodable {
            let id: Int
            let children: [Node]
        }
        let root = try JSONDecoder().decode(Node.self, from: Data(result.output.utf8))
        XCTAssertEqual(root.id, 1)
        XCTAssertEqual(root.children.count, 1)
        XCTAssertEqual(root.children[0].id, 2)
        XCTAssertEqual(root.children[0].children.count, 1)
        XCTAssertEqual(root.children[0].children[0].id, 3)
        XCTAssertTrue(root.children[0].children[0].children.isEmpty, "should be clipped at depth 2")
    }

    // MARK: - hn.user

    func testUserRejectsInvalidCharacters() async throws {
        StubURLProtocol.clear()
        let tool = HNUserTool(apiBase: URL(string: "https://example.test/api")!,
                              session: Self.makeStubSession())
        let result = try await tool.invoke(arguments: #"{"username":"foo/bar"}"#)
        XCTAssertEqual(result.error, "username contains invalid characters")
    }

    func testUserRejectsEmptyUsername() async throws {
        let tool = HNUserTool(apiBase: URL(string: "https://example.test/api")!,
                              session: Self.makeStubSession())
        let result = try await tool.invoke(arguments: #"{"username":""}"#)
        XCTAssertEqual(result.error, "username is empty")
    }

    func testUserHappyPath() async throws {
        let json = #"{"username":"pg","karma":12345,"about":"hi","created_at_i":1234567890,"avg":4.7}"#
        StubURLProtocol.register(response: .success(jsonBody: json))
        defer { StubURLProtocol.clear() }
        let tool = HNUserTool(apiBase: URL(string: "https://hn.algolia.com/api/v1")!,
                              session: Self.makeStubSession())
        let result = try await tool.invoke(arguments: #"{"username":"pg"}"#)
        XCTAssertNil(result.error)
        struct U: Decodable {
            let username: String
            let karma: Int
            let about_html: String
            let average_post_score: Double
            let hn_url: String
        }
        let u = try JSONDecoder().decode(U.self, from: Data(result.output.utf8))
        XCTAssertEqual(u.username, "pg")
        XCTAssertEqual(u.karma, 12345)
        XCTAssertEqual(u.about_html, "hi")
        XCTAssertEqual(u.average_post_score, 4.7, accuracy: 0.001)
        XCTAssertEqual(u.hn_url, "https://news.ycombinator.com/user?id=pg")
    }

    func testUser404IsFriendly() async throws {
        StubURLProtocol.register(response: .status(404))
        defer { StubURLProtocol.clear() }
        let tool = HNUserTool(apiBase: URL(string: "https://hn.algolia.com/api/v1")!,
                              session: Self.makeStubSession())
        let result = try await tool.invoke(arguments: #"{"username":"nobody-here"}"#)
        XCTAssertEqual(result.error, "no HN user named nobody-here")
    }

    // MARK: - URLSession with stub protocol

    static func makeStubSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

// MARK: - StubURLProtocol

/// Single-shot URLProtocol stub. Each test sets up a response, fires
/// one or more requests, and clears in `defer`. `lastRequest` carries
/// the last URLRequest for assertions on URL shape / headers.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Response {
        case success(jsonBody: String)
        case status(Int)
        case transportError(any Error)
    }

    nonisolated(unsafe) static var queued: Response?
    nonisolated(unsafe) static var lastRequest: URLRequest?

    static func register(response: Response) {
        queued = response
        lastRequest = nil
    }
    static func clear() {
        queued = nil
        lastRequest = nil
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        guard let queued = Self.queued else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let url = request.url ?? URL(string: "about:blank")!
        switch queued {
        case .success(let body):
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .status(let code):
            let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .transportError(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
