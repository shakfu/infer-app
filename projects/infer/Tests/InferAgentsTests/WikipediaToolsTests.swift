import XCTest
@testable import InferAgents

final class WikipediaToolsTests: XCTestCase {
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

    // MARK: - URL construction

    func testArticleURLConstruction() {
        XCTAssertEqual(
            WikipediaCommon.articleURL(title: "Ada Lovelace", lang: "en"),
            "https://en.wikipedia.org/wiki/Ada_Lovelace"
        )
        XCTAssertEqual(
            WikipediaCommon.articleURL(title: "C++", lang: "en"),
            "https://en.wikipedia.org/wiki/C++"
        )
        // Non-ASCII titles get percent-encoded.
        XCTAssertEqual(
            WikipediaCommon.articleURL(title: "Æ", lang: "en"),
            "https://en.wikipedia.org/wiki/%C3%86"
        )
        XCTAssertEqual(
            WikipediaCommon.articleURL(title: "Mündung", lang: "de"),
            "https://de.wikipedia.org/wiki/M%C3%BCndung"
        )
    }

    func testLangNormalisation() {
        XCTAssertEqual(WikipediaCommon.normalisedLang(nil), "en")
        XCTAssertEqual(WikipediaCommon.normalisedLang(""), "en")
        XCTAssertEqual(WikipediaCommon.normalisedLang("  "), "en")
        XCTAssertEqual(WikipediaCommon.normalisedLang("EN"), "en")
        XCTAssertEqual(WikipediaCommon.normalisedLang("fr"), "fr")
        XCTAssertEqual(WikipediaCommon.normalisedLang("zh-yue"), "zh-yue")
        // Defensive: reject inputs that could land in the hostname.
        XCTAssertEqual(WikipediaCommon.normalisedLang("en/../evil"), "en")
        XCTAssertEqual(WikipediaCommon.normalisedLang("evil.com"), "en")
        XCTAssertEqual(WikipediaCommon.normalisedLang("a-very-long-language-code"), "en")
    }

    // MARK: - wikipedia.search

    private static let searchFixture = """
    {
      "batchcomplete": true,
      "query": {
        "search": [
          {
            "title": "Ada Lovelace",
            "pageid": 1140,
            "snippet": "Augusta <span class=\\"searchmatch\\">Ada</span> King, Countess of <span class=\\"searchmatch\\">Lovelace</span> &amp; mathematician",
            "size": 84231,
            "wordcount": 11892,
            "timestamp": "2026-01-12T08:32:11Z"
          },
          {
            "title": "Lovelace (film)",
            "pageid": 38193245,
            "snippet": "biographical drama film about <span class=\\"searchmatch\\">Lovelace</span>",
            "size": 14201,
            "wordcount": 1782,
            "timestamp": "2025-11-04T19:11:00Z"
          }
        ]
      }
    }
    """

    func testSearchHappyPath() async throws {
        StubURLProtocol.responder = { request in
            XCTAssertEqual(request.url?.host, "en.wikipedia.org")
            XCTAssertEqual(request.url?.path, "/w/api.php")
            let query = request.url?.query ?? ""
            XCTAssertTrue(query.contains("action=query"))
            XCTAssertTrue(query.contains("list=search"))
            XCTAssertTrue(query.contains("srsearch=lovelace"))
            XCTAssertTrue(query.contains("formatversion=2"))
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
                Data(Self.searchFixture.utf8)
            )
        }
        let tool = WikipediaSearchTool(session: session)
        let result = try await tool.invoke(arguments: ##"{"query": "lovelace"}"##)
        XCTAssertNil(result.error, "got error: \(result.error ?? "")")
        let parsed = try JSONDecoder().decode([WikipediaSearchTool.SearchResult].self, from: Data(result.output.utf8))
        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].title, "Ada Lovelace")
        XCTAssertEqual(parsed[0].url, "https://en.wikipedia.org/wiki/Ada_Lovelace")
        XCTAssertEqual(parsed[0].wordcount, 11892)
        // Snippet has highlights stripped and entities decoded.
        XCTAssertFalse(parsed[0].snippet.contains("<span"))
        XCTAssertFalse(parsed[0].snippet.contains("&amp;"))
        XCTAssertTrue(parsed[0].snippet.contains("Ada"))
        XCTAssertTrue(parsed[0].snippet.contains("&"))
    }

    func testSearchHonoursLangArg() async throws {
        StubURLProtocol.responder = { request in
            XCTAssertEqual(request.url?.host, "fr.wikipedia.org")
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
                Data(##"{"query": {"search": []}}"##.utf8)
            )
        }
        let tool = WikipediaSearchTool(session: session)
        _ = try await tool.invoke(arguments: ##"{"query": "x", "lang": "fr"}"##)
    }

    func testSearchEmptyResultReturnsEmptyArray() async throws {
        StubURLProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
             Data(##"{"query": {"search": []}}"##.utf8))
        }
        let tool = WikipediaSearchTool(session: session)
        let result = try await tool.invoke(arguments: ##"{"query": "asdfghjklq"}"##)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.output, "[]")
    }

    func testSearchHTTPErrorSurfaced() async throws {
        StubURLProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1", headerFields: nil)!,
             Data())
        }
        let tool = WikipediaSearchTool(session: session)
        let result = try await tool.invoke(arguments: ##"{"query": "x"}"##)
        XCTAssertEqual(result.output, "")
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("HTTP 503"))
    }

    func testSearchEmptyQueryRejected() async throws {
        let tool = WikipediaSearchTool(session: session)
        let result = try await tool.invoke(arguments: ##"{"query": "   "}"##)
        XCTAssertEqual(result.error, "query is empty")
    }

    func testSearchClampsLimit() async throws {
        StubURLProtocol.responder = { request in
            let q = request.url?.query ?? ""
            // Limit 99 → clamped to maxLimit=10
            XCTAssertTrue(q.contains("srlimit=10"))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
                    Data(##"{"query": {"search": []}}"##.utf8))
        }
        let tool = WikipediaSearchTool(session: session)
        _ = try await tool.invoke(arguments: ##"{"query": "x", "limit": 99}"##)
    }

    // MARK: - wikipedia.article

    private static let articleFixture = """
    {
      "batchcomplete": true,
      "query": {
        "pages": [
          {
            "pageid": 1140,
            "ns": 0,
            "title": "Ada Lovelace",
            "extract": "Augusta Ada King, Countess of Lovelace (née Byron; 10 December 1815 – 27 November 1852) was an English mathematician and writer, chiefly known for her work on Charles Babbage's proposed mechanical general-purpose computer, the Analytical Engine."
          }
        ]
      }
    }
    """

    func testArticleHappyPath() async throws {
        StubURLProtocol.responder = { request in
            let q = request.url?.query ?? ""
            XCTAssertTrue(q.contains("prop=extracts"))
            XCTAssertTrue(q.contains("explaintext=1"))
            XCTAssertTrue(q.contains("titles=Ada%20Lovelace"))   // form-encoded by URLComponents
            XCTAssertFalse(q.contains("exintro"))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
                    Data(Self.articleFixture.utf8))
        }
        let tool = WikipediaArticleTool(session: session)
        let result = try await tool.invoke(arguments: ##"{"title": "Ada Lovelace"}"##)
        XCTAssertNil(result.error)
        XCTAssertTrue(result.output.contains("Augusta Ada King"))
        XCTAssertTrue(result.output.contains("Analytical Engine"))
        // No HTML chrome.
        XCTAssertFalse(result.output.contains("<"))
        XCTAssertFalse(result.output.contains("</"))
    }

    func testArticleLeadOnlyAddsExintro() async throws {
        StubURLProtocol.responder = { request in
            let q = request.url?.query ?? ""
            XCTAssertTrue(q.contains("exintro=1"))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
                    Data(Self.articleFixture.utf8))
        }
        let tool = WikipediaArticleTool(session: session)
        _ = try await tool.invoke(arguments: ##"{"title": "Ada Lovelace", "lead": true}"##)
    }

    func testArticleMissingTitleSurfacesRecoverableError() async throws {
        let json = """
        {"query": {"pages": [
          {"title": "Definitely Not A Real Article", "missing": true}
        ]}}
        """
        StubURLProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
             Data(json.utf8))
        }
        let tool = WikipediaArticleTool(session: session)
        let result = try await tool.invoke(arguments: ##"{"title": "Definitely Not A Real Article"}"##)
        XCTAssertEqual(result.output, "")
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("no Wikipedia article"))
        XCTAssertTrue(result.error!.contains("wikipedia.search"))   // points the model at recovery
    }

    func testArticleEmptyExtractSurfacesError() async throws {
        // Disambiguation pages and stubs sometimes produce empty extracts.
        let json = """
        {"query": {"pages": [
          {"title": "Some Disambig", "extract": ""}
        ]}}
        """
        StubURLProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
             Data(json.utf8))
        }
        let tool = WikipediaArticleTool(session: session)
        let result = try await tool.invoke(arguments: ##"{"title": "Some Disambig"}"##)
        XCTAssertNotNil(result.error)
        XCTAssertTrue(result.error!.contains("empty extract"))
    }

    func testArticleEmptyTitleRejected() async throws {
        let tool = WikipediaArticleTool(session: session)
        let result = try await tool.invoke(arguments: ##"{"title": "   "}"##)
        XCTAssertEqual(result.error, "title is empty")
    }

    func testArticleTruncatesOversize() async throws {
        // Build an extract larger than maxBytes and confirm the
        // returned text fits within the cap (plus the marker) and
        // ends with the truncation marker.
        let oversizeBody = String(repeating: "lorem ipsum dolor sit amet ", count: 12000)
        let payload: [String: Any] = [
            "query": ["pages": [["title": "Big", "extract": oversizeBody]]]
        ]
        let json = try JSONSerialization.data(withJSONObject: payload)
        StubURLProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!,
             json)
        }
        let tool = WikipediaArticleTool(session: session)
        let result = try await tool.invoke(arguments: ##"{"title": "Big"}"##)
        XCTAssertNil(result.error)
        XCTAssertLessThanOrEqual(result.output.utf8.count, WikipediaArticleTool.maxBytes)
        XCTAssertTrue(result.output.contains("truncated at"))
    }
}
