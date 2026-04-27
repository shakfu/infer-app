import XCTest
@testable import InferAgents

/// `URLProtocol` mock that lets each test register a per-host response
/// (status, headers, body). Faster than a real HTTP server and keeps
/// the tool's actual `URLSession.data(for:)` call path in scope.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (HTTPURLResponse, Data))?
    nonisolated(unsafe) static var lastRequests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        responder = nil
        lastRequests = []
    }

    static func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        lastRequests.append(request)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.record(request)
        guard let r = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let (response, data) = r(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class WebSearchToolTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        session?.invalidateAndCancel()
        session = nil
        super.tearDown()
    }

    // Build an HTTPURLResponse for the given URL.
    private func httpResponse(_ request: URLRequest, status: Int = 200, headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    // MARK: - Argument validation

    func testRejectsEmptyQuery() async throws {
        let tool = WebSearchTool(backend: .duckDuckGo, session: session)
        let result = try await tool.invoke(arguments: ##"{"query": "   "}"##)
        XCTAssertEqual(result.output, "")
        XCTAssertEqual(result.error, "query is empty")
    }

    func testRejectsMalformedJSON() async throws {
        let tool = WebSearchTool(backend: .duckDuckGo, session: session)
        let result = try await tool.invoke(arguments: "not-json")
        XCTAssertNotNil(result.error)
    }

    // MARK: - DuckDuckGo backend

    private static let ddgFixture = """
    <html><body>
    <div class="result">
      <h2 class="result__title">
        <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa&amp;rut=xyz">First &amp; Best</a>
      </h2>
      <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa">Snippet for <b>first</b> result with &quot;quotes&quot;.</a>
    </div>
    <div class="result">
      <h2 class="result__title">
        <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2Fb">Second result</a>
      </h2>
      <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.org%2Fb">Body of the second match.</a>
    </div>
    </body></html>
    """

    func testDDGHappyPath() async throws {
        StubURLProtocol.responder = { request in
            XCTAssertEqual(request.url?.host, "html.duckduckgo.com")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
                Data(Self.ddgFixture.utf8)
            )
        }
        let tool = WebSearchTool(backend: .duckDuckGo, session: session)
        let result = try await tool.invoke(arguments: ##"{"query": "first"}"##)
        XCTAssertNil(result.error, "got error: \(result.error ?? "")")
        let parsed = try JSONDecoder().decode([WebSearchTool.SearchResult].self, from: Data(result.output.utf8))
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].title, "First & Best")          // entity-decoded
        XCTAssertEqual(parsed[0].url, "https://example.com/a")    // uddg unwrapped
        XCTAssertTrue(parsed[0].snippet.contains("\"quotes\""))   // entity-decoded
        XCTAssertFalse(parsed[0].snippet.contains("<b>"))         // tags stripped
        XCTAssertEqual(parsed[1].url, "https://example.org/b")
    }

    func testDDGRespectsLimit() async throws {
        StubURLProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
             Data(Self.ddgFixture.utf8))
        }
        let tool = WebSearchTool(backend: .duckDuckGo, session: session)
        let result = try await tool.invoke(arguments: ##"{"query": "first", "limit": 1}"##)
        let parsed = try JSONDecoder().decode([WebSearchTool.SearchResult].self, from: Data(result.output.utf8))
        XCTAssertEqual(parsed.count, 1)
    }

    func testDDGEmptyResultsReturnEmptyArray() async throws {
        StubURLProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
             Data("<html><body>nothing here</body></html>".utf8))
        }
        let tool = WebSearchTool(backend: .duckDuckGo, session: session)
        let result = try await tool.invoke(arguments: ##"{"query": "needle in haystack"}"##)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, "[]")
    }

    func testDDGServerErrorSurfaced() async throws {
        StubURLProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil)!,
             Data())
        }
        let tool = WebSearchTool(backend: .duckDuckGo, session: session)
        let result = try await tool.invoke(arguments: ##"{"query": "anything"}"##)
        XCTAssertEqual(result.output, "")
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("search failed"))
    }

    // MARK: - DDG parser unit tests

    func testParseHandlesBareURL() {
        // Some DDG result types don't go through the redirect wrapper —
        // the parser should pass those through as-is.
        let html = """
        <a class="result__a" href="https://direct.example.com/page">Direct</a>
        <a class="result__snippet">A direct snippet.</a>
        """
        let parsed = WebSearchTool.parseDDGHTML(html)
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].url, "https://direct.example.com/page")
    }

    func testParseUnwrapsRedirect() {
        let raw = "//duckduckgo.com/l/?uddg=https%3A%2F%2Freal.example.com%2Fpath%3Fq%3D1&rut=xyz"
        XCTAssertEqual(WebSearchTool.unwrapDDGRedirect(raw), "https://real.example.com/path?q=1")
    }

    func testParseDecodesEntities() {
        let s = decodeHTMLEntities("Tom &amp; Jerry &quot;reboot&quot; &#39;90s &lt;b&gt;")
        XCTAssertEqual(s, "Tom & Jerry \"reboot\" '90s <b>")
    }

    func testParseStripsHTMLTags() {
        XCTAssertEqual(stripHTMLTags("a <b>bold</b> word"), "a bold word")
    }

    // MARK: - SearXNG backend

    func testSearXNGHappyPath() async throws {
        let endpoint = URL(string: "https://searx.example.org")!
        let json = """
        {"results": [
          {"title": "First", "url": "https://example.com/1", "content": "First snippet"},
          {"title": "Second", "url": "https://example.com/2", "content": "Second snippet"}
        ]}
        """
        StubURLProtocol.responder = { request in
            // Path should have been suffixed with /search; format=json query param present.
            XCTAssertEqual(request.url?.path, "/search")
            XCTAssertTrue(request.url?.query?.contains("format=json") ?? false)
            XCTAssertTrue(request.url?.query?.contains("q=") ?? false)
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
                Data(json.utf8)
            )
        }
        let tool = WebSearchTool(backend: .searxng(endpoint), session: session)
        let result = try await tool.invoke(arguments: ##"{"query": "swift", "limit": 5}"##)
        XCTAssertNil(result.error)
        let parsed = try JSONDecoder().decode([WebSearchTool.SearchResult].self, from: Data(result.output.utf8))
        XCTAssertEqual(parsed.map(\.title), ["First", "Second"])
        XCTAssertEqual(parsed.map(\.url), ["https://example.com/1", "https://example.com/2"])
    }

    func testSearXNGAcceptsEndpointWithExistingSearchPath() async throws {
        let endpoint = URL(string: "https://searx.example.org/search")!
        StubURLProtocol.responder = { request in
            // Should NOT have appended a second /search; path stays as-is.
            XCTAssertEqual(request.url?.path, "/search")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
                Data(##"{"results": []}"##.utf8)
            )
        }
        let tool = WebSearchTool(backend: .searxng(endpoint), session: session)
        let result = try await tool.invoke(arguments: ##"{"query": "x"}"##)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, "[]")
    }

    func testSearXNGSkipsResultsMissingURLOrTitle() async throws {
        let endpoint = URL(string: "https://searx.example.org")!
        let json = """
        {"results": [
          {"title": "Good", "url": "https://example.com/", "content": "ok"},
          {"title": "Bad - no url", "content": "no url"},
          {"url": "https://example.com/2", "content": "no title"}
        ]}
        """
        StubURLProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
             Data(json.utf8))
        }
        let tool = WebSearchTool(backend: .searxng(endpoint), session: session)
        let result = try await tool.invoke(arguments: ##"{"query": "x"}"##)
        let parsed = try JSONDecoder().decode([WebSearchTool.SearchResult].self, from: Data(result.output.utf8))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].title, "Good")
    }

    func testSearXNGMalformedJSONSurfaced() async throws {
        let endpoint = URL(string: "https://searx.example.org")!
        StubURLProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
             Data("<html>Login required</html>".utf8))   // SearXNG returns HTML when format=json is rejected by some configs
        }
        let tool = WebSearchTool(backend: .searxng(endpoint), session: session)
        let result = try await tool.invoke(arguments: ##"{"query": "x"}"##)
        XCTAssertEqual(result.output, "")
        XCTAssertNotNil(result.error)
    }

    // MARK: - Backend selection

    func testEndpointConstructorPicksDDGOnEmpty() {
        let tool = WebSearchTool(searxngEndpoint: nil)
        XCTAssertEqual(tool.backend, .duckDuckGo)
        let tool2 = WebSearchTool(searxngEndpoint: "")
        XCTAssertEqual(tool2.backend, .duckDuckGo)
        let tool3 = WebSearchTool(searxngEndpoint: "   ")
        XCTAssertEqual(tool3.backend, .duckDuckGo)
    }

    func testEndpointConstructorPicksSearXNGOnValidURL() {
        let tool = WebSearchTool(searxngEndpoint: "https://searx.example.org")
        if case .searxng(let url) = tool.backend {
            XCTAssertEqual(url.absoluteString, "https://searx.example.org")
        } else {
            XCTFail("expected SearXNG backend")
        }
    }

    func testEndpointConstructorRejectsNonHTTPURL() {
        // file:// or javascript: URLs shouldn't accidentally become endpoints.
        let tool = WebSearchTool(searxngEndpoint: "file:///etc/passwd")
        XCTAssertEqual(tool.backend, .duckDuckGo)
    }
}
