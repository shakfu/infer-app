import XCTest
@testable import Infer

final class RemoteSourceLoaderTests: XCTestCase {
    private func session(body: Data, status: Int = 200, contentType: String) -> URLSession {
        RemoteSourceStubProtocol.response = (body, status, contentType)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RemoteSourceStubProtocol.self]
        return URLSession(configuration: config)
    }

    private func assertFails(
        _ url: String = "https://x.test/a",
        body: Data = Data("x".utf8),
        status: Int = 200,
        contentType: String = "text/plain",
        contains text: String,
        line: UInt = #line
    ) async {
        do {
            _ = try await RemoteSourceLoader.load(url, session: session(body: body, status: status, contentType: contentType))
            XCTFail("expected throw", line: line)
        } catch {
            XCTAssertTrue("\(error)".contains(text), "got \(error)", line: line)
        }
    }

    func testHTMLBecomesPlainText() async throws {
        let html = "<html><head><title>T</title></head><body><script>evil()</script><h1>Title</h1><p>One &amp; two</p></body></html>"
        let (source, _) = try await RemoteSourceLoader.load(
            "https://x.test/a",
            session: session(body: Data(html.utf8), contentType: "text/html; charset=utf-8")
        )
        XCTAssertEqual(source.kind, "url")
        XCTAssertEqual(source.content, "Title\n\nOne & two")
    }

    func testMarkdownAndJSONStayVerbatim() async throws {
        for (text, type) in [("# A\n<b>x</b>", "text/markdown"), (#"{"a":1}"#, "application/json")] {
            let (source, _) = try await RemoteSourceLoader.load(
                "https://x.test/a",
                session: session(body: Data(text.utf8), contentType: type)
            )
            XCTAssertEqual(source.content, text)
        }
    }

    func testHashFollowsBody() async throws {
        func hash(_ text: String) async throws -> String {
            try await RemoteSourceLoader.load(
                "https://x.test/a",
                session: session(body: Data(text.utf8), contentType: "text/plain")
            ).1
        }
        let first = try await hash("one")
        let same = try await hash("one")
        let other = try await hash("two")
        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, other)
    }

    func testRejectsNonWebURLs() async {
        for url in ["file:///etc/passwd", "ftp://x.test/a", "not a url", "https://"] {
            await assertFails(url, contains: "http or https")
        }
    }

    func testRejectsHTTPErrors() async {
        await assertFails(status: 404, contains: "HTTP 404")
    }

    func testRejectsBinaryContentTypes() async {
        await assertFails(contentType: "application/pdf", contains: "application/pdf")
    }

    func testRejectsOversizeBody() async {
        await assertFails(body: Data(count: RemoteSourceLoader.maxBytes + 1), contains: "exceeds 10 MB")
    }

    func testRejectsInvalidUTF8() async {
        await assertFails(body: Data([0xFF, 0xFE, 0xFF]), contains: "UTF-8")
    }

    func testRejectsPageWithNoText() async {
        await assertFails(body: Data("<script>x()</script>".utf8), contentType: "text/html", contains: "no text")
    }
}

private final class RemoteSourceStubProtocol: URLProtocol {
    nonisolated(unsafe) static var response: (body: Data, status: Int, contentType: String) = (Data(), 200, "")

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (body, status, contentType) = Self.response
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": contentType]
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
